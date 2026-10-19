import Foundation
import Testing

@testable import StackNestViewerKitCore

@Suite("もう一度渡す頼み（stacknest://viewer/reopen）")
struct StackNestReopenRequestTests {
    static let uuid = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
    static let identity = "sn1-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcd"

    @Test("URL を作って読み戻せる（UUID は小文字にそろえる）")
    func roundTrips() throws {
        let request = try StackNestReopenRequest(libraryUUID: Self.uuid, bookID: 42, bookIdentity: Self.identity)
        #expect(request.libraryUUID == Self.uuid.lowercased())
        #expect(request.url.absoluteString
                == "stacknest://viewer/reopen?library=\(Self.uuid.lowercased())&book=42&identity=\(Self.identity)")
        #expect(StackNestReopenRequest(url: request.url) == request)
        #expect(request.description == request.url.absoluteString)
    }

    @Test("参照ファイルの book から作れるのはローカルのライブラリの本だけ")
    func fromReference() throws {
        func reference(_ book: String) throws -> StackNestBookReference {
            try StackNestBookReference(version: 1, title: "T", bookURL: URL(string: book)!, token: "abcdefghijklmnop",
                                       expiresAt: Date(timeIntervalSince1970: 2_000_000_000), pageCount: 1,
                                       direction: .rightToLeft, startPage: 0)
        }
        let local = try reference("http://127.0.0.1:4321/api/v1/libraries/\(Self.uuid)/books/7")
        let made = try #require(StackNestReopenRequest(reference: local, bookIdentity: Self.identity))
        #expect(made.bookID == 7)
        #expect(made.libraryUUID == Self.uuid.lowercased())
        #expect(StackNestReopenRequest(reference: try reference("http://127.0.0.1:4321/api/v1/relay/abcdef"),
                                       bookIdentity: Self.identity) == nil)
        #expect(StackNestReopenRequest(reference: try reference("http://127.0.0.1:4321/api/v1/libraries/not-a-uuid/books/7"),
                                       bookIdentity: Self.identity) == nil)
        #expect(StackNestReopenRequest(reference: local, bookIdentity: "bad identity") == nil)
        // 手元の StackNest(loopback)の本だけ。ほかの Mac の StackNest へ直接つないだ本は頼めない。
        #expect(StackNestReopenRequest(reference: try reference("http://[::1]:4321/api/v1/libraries/\(Self.uuid)/books/7"),
                                       bookIdentity: Self.identity) != nil)
        #expect(StackNestReopenRequest(reference: try reference("http://localhost:4321/api/v1/libraries/\(Self.uuid)/books/7"),
                                       bookIdentity: Self.identity) != nil)
        #expect(StackNestReopenRequest(reference: try reference("http://192.168.1.2:4321/api/v1/libraries/\(Self.uuid)/books/7"),
                                       bookIdentity: Self.identity) == nil)
    }

    @Test(
        "形の外れた URL は読まない",
        arguments: [
            "https://viewer/reopen?library=\(uuid)&book=1&identity=\(identity)",       // スキーム
            "stacknest://other/reopen?library=\(uuid)&book=1&identity=\(identity)",    // ホスト
            "stacknest://viewer/open?library=\(uuid)&book=1&identity=\(identity)",     // パス
            "stacknest://viewer/reopen?book=1&identity=\(identity)",                   // 無い
            "stacknest://viewer/reopen?library=\(uuid)&book=1&book=2&identity=\(identity)", // 2 回
            "stacknest://viewer/reopen?library=\(uuid)&book=0&identity=\(identity)",   // 0
            "stacknest://viewer/reopen?library=\(uuid)&book=01&identity=\(identity)",  // 先頭の 0
            "stacknest://viewer/reopen?library=\(uuid)&book=-1&identity=\(identity)",  // 符号
            "stacknest://viewer/reopen?library=\(uuid)&book=1&identity=a%2Fb",         // 同一性の文字
            "stacknest://viewer/reopen?library=xyz&book=1&identity=\(identity)",       // UUID
            "stacknest://user@viewer/reopen?library=\(uuid)&book=1&identity=\(identity)", // 資格情報
            "stacknest://viewer:/reopen?library=\(uuid)&book=1&identity=\(identity)",    // 空のポート
            "stacknest://viewer:80/reopen?library=\(uuid)&book=1&identity=\(identity)",  // ポート
            "stacknest://viewer/reopen?library=\(uuid)&book=1&identity=\(identity)#x",   // フラグメント
            "stacknest://viewer/%72eopen?library=\(uuid)&book=1&identity=\(identity)",   // パスのエンコード
            "stacknest://vi%65wer/reopen?library=\(uuid)&book=1&identity=\(identity)",   // ホストのエンコード
        ])
    func rejectsMalformedURLs(_ text: String) throws {
        #expect(StackNestReopenRequest(url: try #require(URL(string: text))) == nil)
    }

    @Test("知らない問い合わせの項目は読み飛ばす（後の版が足せる）。スキームとホストの大文字小文字は問わない")
    func ignoresUnknownItems() throws {
        let url = try #require(URL(string: "STACKNEST://Viewer/reopen?x=1&library=\(Self.uuid)&book=3&identity=\(Self.identity)"))
        #expect(StackNestReopenRequest(url: url)?.bookID == 3)
    }

    @Test("値はパーセントエンコードを解いてから確かめる(解いた形が正しければ読む)")
    func decodesQueryValues() throws {
        let url = try #require(URL(string: "stacknest://viewer/reopen?library=\(Self.uuid)&book=%31&identity=sn1%3Aabc"))
        let request = try #require(StackNestReopenRequest(url: url))
        #expect(request.bookID == 1)
        #expect(request.bookIdentity == "sn1:abc")
    }

    @Test("値から作るときも検査する")
    func validatesValues() {
        #expect(throws: StackNestViewerError.self) {
            try StackNestReopenRequest(libraryUUID: "x", bookID: 1, bookIdentity: Self.identity)
        }
        #expect(throws: StackNestViewerError.self) {
            try StackNestReopenRequest(libraryUUID: Self.uuid, bookID: 0, bookIdentity: Self.identity)
        }
        #expect(throws: StackNestViewerError.self) {
            try StackNestReopenRequest(libraryUUID: Self.uuid, bookID: 1, bookIdentity: "")
        }
    }
}
