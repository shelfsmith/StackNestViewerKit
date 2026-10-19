import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// `book` のパスの形: StackNest の書く 2 つの形だけに要求を出す（書き換えた参照ファイルで、127.0.0.1 の別のサービスへ
/// 鍵の付いた要求を送らせない）。
@Suite("book のパスの形")
struct StackNestBookPathTests {
    static let accepted = [
        "http://127.0.0.1:51234/api/v1/libraries/00000000-0000-4000-8000-000000000001/books/42",
        "http://127.0.0.1:51234/api/v1/libraries/00000000-0000-4000-8000-000000000001/books/42/",
        "http://127.0.0.1:51234/api/v1/libraries/L/books/7",
        "http://127.0.0.1:51234/api/v1/relay/abc",
        "http://127.0.0.1:51234/api/v1/relay/AbC-_~.9/",
        "http://[::1]:51234/api/v1/relay/abc",
        "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7",
        "https://192.0.2.1/api/v1/relay/r1",
    ]

    static let refused = [
        "http://127.0.0.1:51234",
        "http://127.0.0.1:51234/",
        "http://127.0.0.1:51234/admin",
        "http://127.0.0.1:51234/api/v1/libraries/L/books",
        "http://127.0.0.1:51234/api/v1/libraries/L/books/7/extra",
        "http://127.0.0.1:51234/api/v1/libraries/L/books/7//",
        "http://127.0.0.1:51234/api/v1/libraries//books/7",
        "http://127.0.0.1:51234//api/v1/relay/abc",
        "http://127.0.0.1:51234/api/v1/libraries/../books/7",
        "http://127.0.0.1:51234/api/v1/libraries/L/books/..",
        "http://127.0.0.1:51234/api/v1/libraries/L/books/.",
        "http://127.0.0.1:51234/api/v1/relay/..",
        "http://127.0.0.1:51234/api/v1/relay/%2E%2E",
        "http://127.0.0.1:51234/api/v1/relay/a%2Fb",
        "http://127.0.0.1:51234/api/v1/relay/a%20b",
        "http://127.0.0.1:51234/api/v1/libraries/L/books/7;x",
        "http://127.0.0.1:51234/api/v1/relay/a/b",
        "http://127.0.0.1:51234/api/v1/relay",
        "http://127.0.0.1:51234/api/v1/relay/",
        "http://127.0.0.1:51234/API/v1/relay/abc",
        "http://127.0.0.1:51234/api/v2/relay/abc",
        "http://127.0.0.1:51234/api/v1/viewer-tokens/abc",
        "http://127.0.0.1:51234/api/v1/libraries/L/book/7",
        "http://127.0.0.1:51234/prefix/api/v1/relay/abc",
        "http://127.0.0.1:51234/api/v1/libraries/%E6%9C%AC/books/7",
    ]

    @Test("StackNest の書く形だけを通す", arguments: accepted)
    func acceptsStackNestShapes(_ string: String) throws {
        #expect(StackNestBookPath.isStackNestShape(try #require(URL(string: string))))
    }

    @Test("ほかの形・空の区切り・. と ..・パーセントエンコード・予約された文字は通さない", arguments: refused)
    func refusesOtherShapes(_ string: String) throws {
        #expect(!StackNestBookPath.isStackNestShape(try #require(URL(string: string))))
    }

    @Test("相対 URL は解決したパスで見る")
    func relativeURLIsCheckedResolved() throws {
        let base = try #require(URL(string: "http://127.0.0.1:51234/api/v1/libraries/L/"))
        #expect(StackNestBookPath.isStackNestShape(try #require(URL(string: "books/7", relativeTo: base))))
        #expect(!StackNestBookPath.isStackNestShape(try #require(URL(string: "../../../../admin", relativeTo: base))))
    }

    @Test("形の外れた book には、どの要求も出さずに .invalidReference（先読みも出さない）")
    func otherPathMakesNoRequest() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = StackNestBookSession(reference: try reference(stub, path: "/admin/libraries/\(stub.bookURL.pathComponents[4])/x"),
                                           configuration: stub.configuration())
        let invalid = StackNestViewerError(.invalidReference)
        await #expect(throws: invalid) { try await session.manifest() }
        await #expect(throws: invalid) { try await session.page(0) }
        await #expect(throws: invalid) { try await session.cover() }
        await #expect(throws: invalid) { try await session.postProgress(page: 1) }
        let blocking = StackNestBlockingReader(session: session)
        let result = await onThread { Result { try blocking.page(1) } }
        #expect(throws: invalid) { try result.get() }
        session.prefetch([0, 1])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.isEmpty)
    }

    @Test("allowsAnyBookPath を立てると、形を問わずにつなぐ（宛先の制限は残る）")
    func allowsAnyBookPathConnects() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        var configuration = stub.configuration()
        configuration.allowsAnyBookPath = true
        let session = StackNestBookSession(reference: try reference(stub, path: "/prefix/libraries/\(stub.bookURL.pathComponents[4])/x"),
                                           configuration: configuration)
        await #expect(throws: StackNestViewerError(.bookNotFound)) { try await session.manifest() }
        #expect(stub.requests.map(\.url.path) == ["/prefix/libraries/\(stub.bookURL.pathComponents[4])/x/manifest"])
        let lan = StackNestBookSession(
            reference: try StackNestBookReference(
                version: 1, title: "t", bookURL: try #require(URL(string: "http://192.0.2.1:51234/anything")),
                token: "t", expiresAt: .distantFuture, pageCount: 1, direction: .rightToLeft, startPage: 0),
            configuration: configuration)
        await #expect(throws: StackNestViewerError(.hostNotAllowed)) { try await lan.manifest() }
        #expect(stub.requests.count == 1)
    }

    @Test("init(contentsOf:) は形の外れた book を開く時点で .invalidReference で断る")
    func contentsOfRefusesOtherPath() throws {
        let stub = StackNestStubServer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let other = try StackNestFixtures.writeReference(
            StackNestFixtures.referenceJSON(bookURL: try #require(URL(string: "http://127.0.0.1:51234/admin"))),
            in: folder, title: "Other")
        #expect(throws: StackNestViewerError(.invalidReference)) {
            _ = try StackNestBookSession(contentsOf: other, configuration: stub.configuration())
        }
        var any = stub.configuration()
        any.allowsAnyBookPath = true
        _ = try StackNestBookSession(contentsOf: other, configuration: any)
        #expect(stub.requests.isEmpty)
    }

    @Test("文書のサンプルのうち形式として読めるものは、どれも StackNest の書く形")
    func documentationSamplesHaveStackNestShapes() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // StackNestViewerKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリの根
            .appendingPathComponent("Documentation/Samples", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        var readable: [String] = []
        for name in names {
            guard let reference = try? StackNestBookReference.load(contentsOf: directory.appendingPathComponent(name)) else {
                continue
            }
            readable.append(name)
            #expect(StackNestBookPath.isStackNestShape(reference.bookURL), "\(name)")
        }
        #expect(readable == ["reference-expired.stacknestbook", "reference-ipv6-zone.stacknestbook",
                             "reference-lan-host.stacknestbook", "reference-v1-handoff.stacknestbook",
                             "reference-v1-unknown-keys.stacknestbook",
                             "reference-v1.stacknestbook"])
        // 既定の設定で、読めるサンプルが開ける（期限切れ・LAN・IPv6 の区域は、最初の要求か開く時点で別の理由で断る）。
        let session = try StackNestBookSession(contentsOf: directory.appendingPathComponent("reference-v1.stacknestbook"))
        #expect(session.reference.pageCount == 180)
    }

    /// 見立てへ届く、パスだけを替えた参照ファイル。
    private func reference(_ stub: StackNestStubServer, path: String) throws -> StackNestBookReference {
        let url = try #require(URL(string: "http://127.0.0.1:51234\(path)"))
        return try StackNestBookReference(version: 1, title: "Fixture", bookURL: url, token: "fixture-token",
                                          expiresAt: .distantFuture, pageCount: 3, direction: .rightToLeft, startPage: 0)
    }
}
