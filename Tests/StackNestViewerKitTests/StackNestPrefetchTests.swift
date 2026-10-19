import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// 先読みの指示: 同時の数・表示を待たせない・表示が乗ったら昇格・置き換え・捨てる番号・恒久的な失敗。
@Suite("セッション: 先読み")
struct StackNestPrefetchTests {
    private func pageKey(_ index: Int) -> RequestKey { .page(index: index, maxWidth: nil) }

    @Test("先読みは同時に 2 件まで。開けば残りも取り、取ったページは表示に使う")
    func prefetchConcurrencyIsBounded() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gates = (0..<4).map { stub.gate(.page($0)) }
        defer { gates.forEach { $0.open() } }
        let session = try makeSession(stub)
        session.prefetch([0, 1, 2, 3])
        #expect(await waitUntil { stub.requests.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.map(\.route) == [.page(0), .page(1)])
        gates.forEach { $0.open() }
        #expect(await waitUntil { session.cachedKeysForTesting.count == 4 })
        let before = stub.requests.count
        _ = try await session.page(3)
        #expect(stub.requests.count == before, "先読みしたページは取り直さない")
        #expect(stub.requests.map(\.route).sorted { "\($0)" < "\($1)" }
                == [.page(0), .page(1), .page(2), .page(3)].sorted { "\($0)" < "\($1)" })
    }

    @Test("キャッシュの枚数いっぱいの先読みを続けても、次に読むページは追い出されない（ページを送るたびに取り直さない）")
    func prefetchKeepsTheNextPageCached() async throws {
        let stub = StackNestStubServer(pageCount: 12)
        let session = try makeSession(stub) { $0.pageCacheCount = 3 }
        // 0 を表示して 1〜3 を先読みし、1 へ進んで 2〜4 を先読みし、2 を開く。
        _ = try await session.page(0)
        session.prefetch([1, 2, 3])
        #expect(await waitUntil { stub.requestCount(.page(3)) == 1 && session.cachedKeysForTesting.contains(pageKey(3)) })
        _ = try await session.page(1)
        session.prefetch([2, 3, 4])
        #expect(await waitUntil { stub.requestCount(.page(4)) == 1 && session.cachedKeysForTesting.contains(pageKey(4)) })
        #expect(session.cachedKeysForTesting == [pageKey(3), pageKey(2), pageKey(4)], "表示し終えた 1 が先に出る")
        _ = try await session.page(2)
        #expect(stub.requestCount(.page(2)) == 1, "先読みした 2 を取り直さない")
    }

    @Test("表示の要求は先読みの列に並ばない")
    func displayDoesNotQueueBehindPrefetch() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gates = (0..<4).map { stub.gate(.page($0)) }
        defer { gates.forEach { $0.open() } }
        let session = try makeSession(stub)
        session.prefetch([0, 1, 2, 3])
        #expect(await waitUntil { stub.requests.count == 2 })
        let page = try await session.page(6)
        #expect(StackNestFixtures.marker(of: page.data) == 6)
    }

    @Test("先読みの取り中に表示の要求が乗ったら、優先度を上げて表示の件として数える（次の先読みが始まる）")
    func displayJoiningPrefetchIsPromoted() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gates = (0..<3).map { stub.gate(.page($0)) }
        defer { gates.forEach { $0.open() } }
        let session = try makeSession(stub)
        session.prefetch([0, 1, 2])
        #expect(await waitUntil { stub.requests.count == 2 })
        #expect(session.taskPriorityForTesting(pageKey(0)) == URLSessionTask.lowPriority)
        let shown = Task { try await session.page(0) }
        #expect(await waitUntil { session.waiterCountForTesting(pageKey(0)) == 2 })
        #expect(session.taskPriorityForTesting(pageKey(0)) == URLSessionTask.highPriority)
        #expect(await waitUntil { stub.requestCount(.page(2)) == 1 }, "0 番が表示の件になり、先読みの枠が 1 つ空いた")
        gates.forEach { $0.open() }
        #expect(StackNestFixtures.marker(of: try await shown.value.data) == 0)
        #expect(stub.requestCount(.page(0)) == 1)
    }

    @Test("指示を置き換えると、外れた取得中の先読みを取り消す（表示が乗っている件は続ける）")
    func prefetchReplacementCancelsStaleFetches() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gates = [0, 1, 5, 6].map { stub.gate(.page($0)) }
        defer { gates.forEach { $0.open() } }
        let session = try makeSession(stub)
        session.prefetch([0, 1])
        #expect(await waitUntil { stub.requests.count == 2 })
        let shown = Task { try await session.page(1) }
        #expect(await waitUntil { session.waiterCountForTesting(pageKey(1)) == 2 })
        session.prefetch([5, 6])
        #expect(await waitUntil { stub.stoppedRequestCount == 1 }, "0 番だけを取り消す")
        #expect(await waitUntil { stub.requestCount(.page(5)) == 1 && stub.requestCount(.page(6)) == 1 })
        gates.forEach { $0.open() }
        #expect(StackNestFixtures.marker(of: try await shown.value.data) == 1)
    }

    @Test("負の番号・重複・既知のページ数以上は、要求を出さずに捨てる")
    func prefetchDropsInvalidIndicesWithoutRequests() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        session.prefetch([-1, 3, 99, 1, 1, -5])
        #expect(await waitUntil { session.cachedKeysForTesting == [pageKey(1)] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.map(\.route) == [.page(1)])
    }

    @Test("指示はキャッシュの枚数までに切り詰め、渡した順に出す")
    func prefetchIsCutToCacheCountInOrder() async throws {
        let stub = StackNestStubServer(pageCount: 20)
        let session = try makeSession(stub) {
            $0.pageCacheCount = 3
            $0.maxConcurrentPrefetches = 1
        }
        session.prefetch([7, 3, 9, 1, 2])
        #expect(await waitUntil { session.cachedKeysForTesting.count == 3 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.map(\.route) == [.page(7), .page(3), .page(9)])
    }

    @Test("恒久的な失敗の後は、先読みの指示を無視する")
    func prefetchStopsAfterPermanentFailure() async throws {
        let stub = StackNestStubServer(pageCount: 5)
        stub.respond(.manifest, with: .status(401))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.unauthorized)) { try await session.manifest() }
        session.prefetch([0, 1])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.map(\.route) == [.manifest])
    }

    @Test("manifest でページ数が減ったら、範囲の外の先読みを列から捨て、取り中の先読みだけの件は取り消す")
    func shrunkManifestDropsPrefetches() async throws {
        let stub = StackNestStubServer(pageCount: 6)
        let gate = stub.gate(.page(4))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.maxConcurrentPrefetches = 1 }
        session.prefetch([4, 5])
        #expect(await gate.arrival())
        stub.setPageCount(2)
        _ = try await session.manifest(refresh: true)
        #expect(await waitUntil { stub.stoppedRequestCount == 1 }, "取り中の 4 番の先読みを取り消す")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requestCount(.page(5)) == 0, "列にあった 5 番は出さない")
        #expect(session.inFlightKeysForTesting.isEmpty)
    }

    @Test("閉じた後の先読みの指示は何もしない")
    func prefetchAfterCloseDoesNothing() async throws {
        let stub = StackNestStubServer(pageCount: 5)
        let session = try makeSession(stub)
        session.close()
        session.prefetch([0, 1])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.isEmpty)
    }
}
