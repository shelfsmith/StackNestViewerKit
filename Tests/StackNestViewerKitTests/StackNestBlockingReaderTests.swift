import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// 呼ばれた誤りの知らせを数える箱。
final class MisuseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) { lock.withLock { messages.append(message) } }
    var all: [String] { lock.withLock { messages } }
}

/// 取り消しの旗（ホストの `Cancellation` の代わり）。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// 同期の橋渡し。専用のスレッドから呼ぶ（試験の本体も協調スレッドの上なので、`onThread` で外へ出す）。
@Suite("同期の橋渡し")
struct StackNestBlockingReaderTests {
    private func reader(_ session: StackNestBookSession, flag: CancelFlag = CancelFlag(),
                        misuse: MisuseLog = MisuseLog()) -> StackNestBlockingReader
    {
        StackNestBlockingReader(session: session, isCancelled: { flag.isRaised }, onMisuse: { misuse.add($0) })
    }

    @Test("同期の顔でも、ページの 404 は manifest を読み直して振り分ける（同じ数なら 404、減っていれば範囲外）")
    func blockingPageNotFoundIsClassified() async throws {
        let odd = StackNestStubServer(pageCount: 3)
        odd.respond(.page(1), with: .status(404))
        let oddReader = reader(try makeSession(odd))
        let oddResult = await onThread { Result { try oddReader.page(1) } }
        #expect(throws: StackNestViewerError(.httpStatus, statusCode: 404)) { try oddResult.get() }

        let shrunk = StackNestStubServer(pageCount: 3)
        let session = try makeSession(shrunk)
        let shrunkReader = reader(session)
        shrunk.respond(.page(2), with: .status(404))
        shrunk.setPageCount(2)
        let shrunkResult = await onThread { Result { try shrunkReader.page(2) } }
        #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 2)) { try shrunkResult.get() }
    }

    @Test("同期の顔でも requestsPageNames の manifest は名前を持つ（要求は ?pageNames=1）")
    func blockingManifestCarriesPageNames() async throws {
        let stub = StackNestStubServer(pageCount: 2)
        stub.setPageNames(["a/1.jpg", "a/2.jpg"])
        let blocking = reader(try makeSession(stub) { $0.requestsPageNames = true })
        let result = await onThread { Result { try blocking.manifest() } }
        #expect(try result.get().pageNames == ["a/1.jpg", "a/2.jpg"])
        #expect(stub.requests.map(\.url.query) == ["pageNames=1"])
    }

    @Test("同期の顔の読み直しと 404 の後の確かめも、前から飛んでいる manifest の要求に乗らない")
    func blockingRefreshDoesNotJoinAnOlderFlight() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.manifest)
        defer { gate.open() }
        let session = try makeSession(stub)
        let blocking = reader(session)
        let older = Task { try await session.manifest() }
        #expect(await gate.arrival(), "先の要求は 3 ページの時点で StackNest に届いた")
        stub.setPageCount(2)
        async let refreshed = onThread { Result { try blocking.manifest(refresh: true) } }
        async let missing = onThread { Result { try blocking.page(2) } }
        #expect(await gate.arrival())
        #expect(await gate.arrival(), "読み直しと 404 の後の確かめが、それぞれ自分の要求を出す")
        gate.open()
        let (refreshResult, missingResult) = await (refreshed, missing)
        #expect(try refreshResult.get().pageCount == 2)
        #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 2)) { try missingResult.get() }
        #expect(try await older.value.pageCount == 3)
        #expect(stub.requestCount(.manifest) == 3)
    }

    @Test("manifest とページを同期で読む（専用のスレッドからなら誤りの知らせは出ない）")
    func readsManifestAndPages() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let misuse = MisuseLog()
        let reader = reader(try makeSession(stub), misuse: misuse)
        let result = await onThread { Result { (try reader.manifest(), try reader.page(2, maxWidth: 120)) } }
        let (manifest, page) = try result.get()
        #expect(manifest.pageCount == 4)
        #expect(StackNestFixtures.marker(of: page.data) == 2)
        #expect(stub.requests.map(\.maxWidth) == [nil, 120])
        #expect(misuse.all.isEmpty)
    }

    @Test("async の側が取り中のページに乗る（要求は 1 件）")
    func blockingJoinsAsyncRequest() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub)
        let viaAsync = Task { try await session.page(0) }
        #expect(await gate.arrival())
        let reader = reader(session)
        async let viaBlocking = onThread { Result { try reader.page(0) } }
        #expect(await waitUntil { session.waiterCountForTesting(.page(index: 0, maxWidth: nil)) == 2 })
        gate.open()
        #expect(try await viaBlocking.get() == (try await viaAsync.value))
        #expect(stub.requestCount(.page(0)) == 1)
    }

    @Test("要求を出す前に旗が立っていれば、要求を出さずに CancellationError")
    func cancelledBeforeIssueMakesNoRequest() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let flag = CancelFlag()
        flag.raise()
        let reader = reader(try makeSession(stub), flag: flag)
        let manifest = await onThread { Result { try reader.manifest() } }
        let page = await onThread { Result { try reader.page(0) } }
        #expect(throws: CancellationError.self) { try manifest.get() }
        #expect(throws: CancellationError.self) { try page.get() }
        #expect(stub.requests.isEmpty)
    }

    @Test("待っている間に旗が立てば、すぐに CancellationError で戻り、最後の待つ人なら要求も取り消す")
    func cancellationFlagStopsTheWait() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(1))
        defer { gate.open() }
        let flag = CancelFlag()
        let reader = reader(try makeSession(stub), flag: flag)
        async let outcome = onThread { () -> (Result<StackNestPage, any Error>, TimeInterval) in
            let result = Result { try reader.page(1) }
            return (result, Date().timeIntervalSince1970)
        }
        #expect(await gate.arrival())
        let raisedAt = Date().timeIntervalSince1970
        flag.raise()
        let (result, returnedAt) = await outcome
        #expect(throws: CancellationError.self) { try result.get() }
        // 0.1 秒ごとに旗を見る。CI の遅い機でも余裕を持たせて 1 秒。
        #expect(returnedAt - raisedAt < 1.0)
        #expect(await waitUntil { stub.stoppedRequestCount == 1 })
    }

    @Test("取り消しの旗を見る間隔は 0.1 秒（試験の上限 1 秒は CI の遅い機への余裕）")
    func cancellationPollIntervalIsPinned() {
        #expect(StackNestBookSession.cancellationPollInterval == .milliseconds(100))
    }

    @Test("閉じた後は、覚えた manifest も含めて、要求なしで CancellationError")
    func everythingButProgressFailsAfterClose() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        let reader = reader(session)
        let first = await onThread { Result { try reader.manifest() } }
        #expect(try first.get().pageCount == 3)
        session.close()
        let manifest = await onThread { Result { try reader.manifest() } }
        let page = await onThread { Result { try reader.page(0) } }
        #expect(throws: CancellationError.self) { try manifest.get() }
        #expect(throws: CancellationError.self) { try page.get() }
        // 閉じた後の確認は、範囲の確認より先に効く（番号が範囲外でも CancellationError）。
        let negative = await onThread { Result { try reader.page(-1) } }
        let beyond = await onThread { Result { try reader.page(9) } }
        #expect(throws: CancellationError.self) { try negative.get() }
        #expect(throws: CancellationError.self) { try beyond.get() }
        #expect(stub.requests.map(\.route) == [.manifest])
    }

    @Test("waitLimit を超えたら .cannotConnect で戻る（決して永遠に返らない、を防ぐ）")
    func waitLimitIsEnforced() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let reader = reader(try makeSession(stub) { $0.waitLimit = .milliseconds(300) })
        let start = Date()
        let result = await onThread { Result { try reader.page(0) } }
        #expect(throws: StackNestViewerError(.cannotConnect)) { try result.get() }
        #expect(Date().timeIntervalSince(start) < 3.0)
    }

    @Test("waitLimit で戻った同期の待つ人は、待つ人の表からも取り込み中の表からも外れている")
    func timedOutBlockingReaderIsWithdrawn() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.waitLimit = .milliseconds(300) }
        let reader = reader(session)
        let result = await onThread { Result { try reader.page(0) } }
        #expect(throws: StackNestViewerError(.cannotConnect)) { try result.get() }
        #expect(session.ticketCountForTesting == 0)
        #expect(session.waiterCountForTesting(.page(index: 0, maxWidth: nil)) == 0)
        #expect(session.inFlightKeysForTesting.isEmpty)
    }

    @Test("範囲外は要求なしで .pageOutOfRange")
    func outOfRangeMakesNoRequest() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let reader = reader(try makeSession(stub))
        let negative = await onThread { Result { try reader.page(-1) } }
        #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 3)) { try negative.get() }
        #expect(stub.requests.isEmpty)
        let beyond = await onThread { Result { try reader.page(7) } }
        #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 3)) { try beyond.get() }
        #expect(stub.requests.map(\.route) == [.manifest])
    }

    @Test("閉じると、止まっていた同期の待つ人もすぐ戻る（25 秒待たない）")
    func closeReleasesParkedBlockingReader() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub)
        let reader = reader(session)
        async let outcome = onThread { Result { try reader.page(0) } }
        #expect(await gate.arrival())
        let start = Date()
        session.close()
        let result = await outcome
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test("Task の中・メインスレッドから呼ぶと誤りを知らせる")
    func misuseIsReported() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let flag = CancelFlag()
        flag.raise()  // 知らせを見るだけなので、要求は出さない。
        let misuse = MisuseLog()
        let reader = reader(try makeSession(stub), flag: flag, misuse: misuse)
        _ = try? reader.manifest()  // 試験の本体（Task の中）から
        await MainActor.run { _ = try? reader.page(0) }
        #expect(misuse.all.count == 2)
        #expect(misuse.all.first?.contains("inside a Task") == true)
        #expect(misuse.all.last?.contains("main thread") == true)
        #expect(stub.requests.isEmpty)
    }
}
