import CoreGraphics
import Foundation
import ImageIO
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

/// `@testable` を使わず、ビューアが書くのと同じ公開 API だけで統合の形を書く（公開の面の退行を見張る）。
@MainActor
@Suite("公開 API だけで書く統合の形", .serialized)
struct PublicAPITests {
    private func referenceFile(_ stub: StackNestStubServer, pageCount: Int, startPage: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kit-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try StackNestFixtures.writeReference(
            StackNestFixtures.referenceJSON(bookURL: stub.bookURL, pageCount: pageCount, startPage: startPage),
            in: folder)
    }

    @Test("README の統合例: 開く → ページ → 書き戻し → 閉じる")
    func integrationExampleRuns() async throws {
        let stub = StackNestStubServer(pageCount: 5)
        let file = try referenceFile(stub, pageCount: 5, startPage: 2)
        #expect(StackNestBookReference.isReferenceFile(file))
        var notices: [String] = []
        let book = try await openStackNestBook(at: file, configuration: stub.configuration()) { notices.append($0) }
        #expect(book.pageCount == 5 && book.startPage == 2)
        let page = try await showPage(3, of: book)
        #expect(page.contentType == "image/png")
        let image = CGImageSourceCreateWithData(page.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(image?.width == 4 && image?.height == 6, "見立ての PNG は画像として読める")
        closeStackNestBook(book)
        await book.reporter.waitUntilIdle()
        #expect(stub.requests.first?.route == .manifest)
        #expect(stub.requests.last?.progressPage == 3)
        #expect(notices.isEmpty)
    }

    @Test("エラーはコードで分岐し、残りは既定の文言に任せる")
    func errorsAreHandledByCode() async throws {
        let stub = StackNestStubServer(pageCount: 2)
        stub.respond(.manifest, with: .status(403, headers: ["X-Library-Locked": "1"]))
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        do {
            _ = try await session.manifest()
            Issue.record("失敗しなかった")
        } catch let error as StackNestViewerError {
            let handledHere: Bool
            switch error.code {
            case .libraryLocked, .expired, .unauthorized: handledHere = true
            default: handledHere = false
            }
            #expect(handledHere)
            #expect(error.isPermanent)
            #expect(error.message(language: StackNestLanguage(locale: Locale(identifier: "ja")), appName: "Example Viewer")
                    == "StackNest でライブラリを解錠し、StackNest から開き直してください。")
        }
    }

    @Test("同期の橋渡し（ブロックしてよいスレッドから）")
    func blockingReaderFromAThread() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        let reader = StackNestBlockingReader(session: session)
        let names = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            Thread {
                let count = (try? reader.manifest().pageCount) ?? 0
                _ = try? reader.page(0)
                continuation.resume(returning: StackNestPageNaming.entryNames(pageCount: count))
            }.start()
        }
        #expect(names == ["000000.jpg", "000001.jpg", "000002.jpg"])
        #expect(stub.requests.map(\.route) == [.manifest, .page(0)])
    }

    @Test("本の同一性を公開の面だけで読める(見立て・manifest・形の検査)")
    func bookIdentityThroughThePublicSurface() async throws {
        let stub = StackNestStubServer(pageCount: 1)
        stub.setBookIdentity("sn1-publicAPIidentity")
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        #expect(try await session.manifest().bookIdentity == "sn1-publicAPIidentity")
        #expect(StackNestBookManifest.isAcceptableBookIdentity("sn1-publicAPIidentity"))
        #expect(!StackNestBookManifest.isAcceptableBookIdentity("has space"))
        let made = StackNestBookManifest(pageCount: 1, direction: nil, format: nil, etag: nil, bookIdentity: "sn1-x")
        #expect(made.bookIdentity == "sn1-x")
        session.close()
    }

    @Test("もう一度渡す頼みを参照ファイルと同一性から作り、URL を読み戻せる（公開の面だけで）")
    func reopenRequestThroughThePublicSurface() throws {
        let stub = StackNestStubServer(pageCount: 1)
        let identity = "sn1-publicAPIreopen"
        let request = try #require(StackNestReopenRequest(reference: try stub.reference(), bookIdentity: identity))
        #expect(request.url.scheme == StackNestReopenRequest.scheme)
        #expect(StackNestReopenRequest(url: request.url) == request)
        #expect(request.bookIdentity == identity)
        let made = try StackNestReopenRequest(libraryUUID: request.libraryUUID, bookID: request.bookID, bookIdentity: identity)
        #expect(made == request)
    }

    @Test("ビューアの試験に置く自己点検（Info.plist の宣言）")
    func selfCheckOfTheDeclaration() {
        let info: [String: Any] = [StackNestViewerSupport.infoPlistKey: [StackNestViewerSupport.versionsKey: [1]]]
        #expect(StackNestViewerSupport.verify(infoDictionary: info).isEmpty)
    }

    @Test("ホストの試験は自分の登録簿を作って役を載せられる（共有の登録簿を使わない）")
    func reporterWithAnOwnRegistry() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        let registry = StackNestProgressRegistry()
        let reporter = StackNestProgressReporter(session: session, startPage: 0, registry: registry) { _ in }
        // 登録簿は報告役を弱く持つので、最適化ビルドで早く解放されないよう検証が終わるまで握っておく。
        defer { withExtendedLifetime(reporter) {} }
        reporter.note(page: 2)
        #expect(registry.hasUnsentWork)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.flushAll(timeout: .seconds(5)) { continuation.resume() }
        }
        #expect(stub.requests.last?.progressPage == 2)
    }

    @Test("終了時の送り切り（共有の登録簿）")
    func quitFlushThroughTheSharedRegistry() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        let reporter = StackNestProgressReporter(session: session, startPage: 0) { _ in }
        // 登録簿は報告役を弱く持つので、最適化ビルドで早く解放されないよう検証が終わるまで握っておく。
        // （withExtendedLifetime のクロージャは async を受け付けないため、defer で関数の終わりまで延ばす。）
        defer { withExtendedLifetime(reporter) {} }
        reporter.note(page: 2)
        let registry = StackNestProgressRegistry.shared
        #expect(registry.hasUnsentWork)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !registry.flushAll(timeout: .seconds(5), completion: { continuation.resume() }) { continuation.resume() }
        }
        #expect(stub.requests.contains { $0.progressPage == 2 })
    }

    @Test("セッションのメモリの量を公開の面だけで読める")
    func memoryUseIsReadable() async throws {
        let stub = StackNestStubServer(pageCount: 2)
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        let page = try await session.page(1)
        #expect(session.cachedPageBytes == page.data.count)
        #expect(session.bufferedResponseBytes == 0)
        session.close()
        #expect(session.cachedPageBytes == 0)
    }

    @Test("終了時の送り切り（共有の登録簿・メインスレッドで待つ形）")
    func blockingQuitFlushThroughTheSharedRegistry() throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        let reporter = StackNestProgressReporter(session: session, startPage: 0) { _ in }
        // 登録簿は報告役を弱く持つので、検証が終わるまで握っておく。
        defer { withExtendedLifetime(reporter) {} }
        reporter.note(page: 2)
        let registry = StackNestProgressRegistry.shared
        #expect(registry.hasUnsentWork)
        #expect(registry.flushAllBlocking(timeout: .seconds(5)) >= 1)
        #expect(!registry.hasUnsentWork)
        #expect(stub.requests.contains { $0.progressPage == 2 })
    }

    @Test("画素データが 65,535 バイトを超える PNG も画像として読め、目印が読み戻せる")
    func largePngPageDecodes() throws {
        // stored ブロックは 1 つ 65,535 バイトまでなので、それを超える大きさでブロックの分割が正しいかを見る。
        let png = StackNestFixtures.pngPage(width: 300, height: 300, marker: 77)
        // IDAT の本文は zlib: 見出し 2 バイト・stored ブロック・Adler-32 の 4 バイト。
        let start = try #require(png.range(of: Data("IDAT".utf8))?.upperBound)
        let length = png[(start - 8)..<(start - 4)].reduce(0) { $0 << 8 | Int($1) }
        let deflate = Data(png[(start + 2)..<(start + length - 4)])
        // ImageIO は壊れた zlib も読んでしまうので、まず生の DEFLATE を自分で展開して枠組みを確かめる（ブロックが 2 つ以上）。
        #expect(deflate.count > 65_535 + 10)
        let raw = try (deflate as NSData).decompressed(using: .zlib) as Data
        #expect(raw.count == 300 * 301)
        #expect(raw.enumerated().allSatisfy { $0.offset % 301 == 0 ? $0.element == 0 : $0.element == 77 })
        // NLEN や Adler-32 の誤りは展開では見えないので、画素まで復号して全画素が目印と一致することも確かめる。
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 300 && image.height == 300)
        let pixels = try #require(image.dataProvider?.data as Data?)
        #expect((0..<300).allSatisfy { y in (0..<300).allSatisfy { pixels[pixels.startIndex + y * image.bytesPerRow + $0] == 77 } })
        #expect(StackNestFixtures.marker(of: png) == 77)
    }
}
