import Foundation
import Testing

@testable import StackNestViewerKitCore

/// 参照ファイル（版 1）の読み取り。読めないもの・読めない版を開かないこと、鍵が文字列に出ないことを固定する。
@Suite("参照ファイルの読み取り")
struct StackNestBookReferenceTests {
    static func json(_ overrides: [String: Any] = [:], removing removed: [String] = []) -> Data {
        var object: [String: Any] = [
            "format": "stacknest-book-reference",
            "version": 1,
            "title": "Example Book",
            "book": "http://192.0.2.10:51234/api/v1/libraries/L/books/7",
            "token": "secret-token-value",
            "expiresAt": "2027-01-15T08:00:00Z",
            "pageCount": 180,
            "direction": "rtl",
            "startPage": 41,
        ]
        for (key, value) in overrides { object[key] = value }
        for key in removed { object[key] = nil }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func expectInvalid(_ data: Data, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: StackNestViewerError(.invalidReference), comment, sourceLocation: sourceLocation) {
            try StackNestBookReference.parse(data)
        }
    }

    @Test("版 1 の参照ファイルを読む")
    func parsesVersionOne() throws {
        let reference = try StackNestBookReference.parse(Self.json())
        #expect(reference.version == 1)
        #expect(reference.title == "Example Book")
        #expect(reference.bookURL.absoluteString == "http://192.0.2.10:51234/api/v1/libraries/L/books/7")
        #expect(reference.token == "secret-token-value")
        #expect(reference.expiresAt == (try Date("2027-01-15T08:00:00Z", strategy: .iso8601)))
        #expect(reference.pageCount == 180)
        #expect(reference.direction == .rightToLeft)
        #expect(reference.startPage == 41)
    }

    @Test("知らない項目は読み飛ばす・title と direction は無くても開く")
    func toleratesUnknownAndOptionalKeys() throws {
        let extra = try StackNestBookReference.parse(Self.json(["coverURL": "http://192.0.2.10/c", "extra": ["a": 1]]))
        #expect(extra.startPage == 41)
        let bare = try StackNestBookReference.parse(Self.json(removing: ["title", "direction"]))
        #expect(bare.title == "")
        #expect(bare.direction == nil)
        let odd = try StackNestBookReference.parse(Self.json(["direction": "ttb"]))
        #expect(odd.direction == .unknown("ttb"))
    }

    @Test("期限: 小数秒つき・時差つきも読み、時差の無い形は読まない")
    func parsesExpiryForms() throws {
        let fractional = try StackNestBookReference.parse(Self.json(["expiresAt": "2027-01-15T08:00:00.250Z"]))
        let whole = try Date("2027-01-15T08:00:00Z", strategy: .iso8601)
        #expect(fractional.expiresAt.timeIntervalSince(whole) == 0.25)
        let offset = try StackNestBookReference.parse(Self.json(["expiresAt": "2027-01-15T17:00:00+09:00"]))
        #expect(offset.expiresAt == whole)
        expectInvalid(Self.json(["expiresAt": "2027-01-15T08:00:00"]))
    }

    @Test("基点が IPv6（角括弧・区域 ID 付き）でも読む")
    func parsesBracketedIPv6WithZone() throws {
        let reference = try StackNestBookReference.parse(
            Self.json(["book": "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7"]))
        #expect(reference.bookURL.host(percentEncoded: false) == "fe80::1%en0")
        #expect(reference.bookURL.port == 51234)
    }

    /// 形式が違う・壊れた JSON・必須の項目が無い・値の形が違うものは開かない。
    static let invalidVariants: [String] = [
        "format", "broken", "notObject", "noBook", "ftpBook", "noHost", "noToken", "emptyToken", "noExpiry",
        "badExpiry", "noPageCount", "negativePageCount", "noStartPage", "negativeStart", "fractionalStart",
        "bookWithQuery", "bookWithEmptyQuery", "bookWithFragment", "blankHost", "emptyHost", "tooManyPages",
        "zeroVersion", "negativeVersion", "otherFormatNewerVersion", "userInfo", "userOnly", "passwordOnly",
    ]

    @Test("読めないファイルは .invalidReference", arguments: invalidVariants)
    func rejectsUnreadableFiles(variant: String) {
        let data: Data
        switch variant {
        case "format": data = Self.json(["format": "something-else"])
        case "broken": data = Data("{\"format\": \"stacknest-book-reference\",".utf8)
        case "notObject": data = Data("[1, 2, 3]".utf8)
        case "noBook": data = Self.json(removing: ["book"])
        case "ftpBook": data = Self.json(["book": "ftp://192.0.2.10/books/7"])
        case "noHost": data = Self.json(["book": "http:///api/v1/books/7"])
        case "bookWithQuery": data = Self.json(["book": "http://192.0.2.10:51234/api/v1/libraries/L/books/7?x=1"])
        case "bookWithEmptyQuery": data = Self.json(["book": "http://192.0.2.10:51234/api/v1/libraries/L/books/7?"])
        case "bookWithFragment": data = Self.json(["book": "http://192.0.2.10:51234/api/v1/libraries/L/books/7#top"])
        case "blankHost": data = Self.json(["book": "http://%20/api/v1/books/7"])
        case "emptyHost": data = Self.json(["book": "http://:51234/api/v1/books/7"])
        case "tooManyPages": data = Self.json(["pageCount": StackNestFormat.maxPageCount + 1])
        case "zeroVersion": data = Self.json(["version": 0])
        case "negativeVersion": data = Self.json(["version": -3])
        case "otherFormatNewerVersion": data = Self.json(["format": "something-else", "version": 2])
        case "noToken": data = Self.json(removing: ["token"])
        case "emptyToken": data = Self.json(["token": ""])
        case "noExpiry": data = Self.json(removing: ["expiresAt"])
        case "badExpiry": data = Self.json(["expiresAt": "tomorrow"])
        case "noPageCount": data = Self.json(removing: ["pageCount"])
        case "negativePageCount": data = Self.json(["pageCount": -1])
        case "noStartPage": data = Self.json(removing: ["startPage"])
        case "negativeStart": data = Self.json(["startPage": -1])
        case "userInfo": data = Self.json(["book": "http://user:pass@192.0.2.10:51234/api/v1/libraries/L/books/7"])
        case "userOnly": data = Self.json(["book": "http://user@192.0.2.10:51234/api/v1/libraries/L/books/7"])
        case "passwordOnly": data = Self.json(["book": "https://:pass@books.example.com/api/v1/libraries/L/books/7"])
        default: data = Self.json(["startPage": 1.5])
        }
        expectInvalid(data, "\(variant)")
    }

    @Test("読めない版は .unsupportedVersion（版 2 は版を持ち、文字列・小数・真偽値・無しは nil）")
    func rejectsUnsupportedVersions() {
        #expect(throws: StackNestViewerError(.unsupportedVersion, formatVersion: 2)) {
            try StackNestBookReference.parse(Self.json(["version": 2]))
        }
        for value in ["1", 1.5, true] as [Any] {
            #expect(throws: StackNestViewerError(.unsupportedVersion)) {
                try StackNestBookReference.parse(Self.json(["version": value]))
            }
        }
        #expect(throws: StackNestViewerError(.unsupportedVersion)) {
            try StackNestBookReference.parse(Self.json(removing: ["version"]))
        }
    }

    @Test("鍵に改行・空白・制御文字・b64token の外の文字があれば開かない（ヘッダの注入を防ぐ）")
    func tokenWithControlCharactersIsRejected() throws {
        for token in ["abc\r\nX-Evil: 1", "abc def", "abc\tdef", "abc\u{0}", "トークン", "abc=def", "==", "a\"b"] {
            expectInvalid(Self.json(["token": token]), "\(token.debugDescription)")
        }
        for token in ["Ab0-._~+/", "abc==", "x", "q8Zk3nJ0r4bW-_sYt1uVw2xYz3aBcDeFgHiJkLmNoPq"] {
            #expect(try StackNestBookReference.parse(Self.json(["token": token])).token == token)
        }
    }

    @Test("https の基点も読む。ページ数の上限ちょうどは読める")
    func acceptsHTTPSAndMaximumPageCount() throws {
        let reference = try StackNestBookReference.parse(
            Self.json(["book": "https://books.example.com:8443/api/v1/libraries/L/books/7",
                       "pageCount": StackNestFormat.maxPageCount]))
        #expect(reference.bookURL.scheme == "https")
        #expect(reference.pageCount == 100_000)
    }

    @Test("大きさの上限: 1 MiB ちょうどは読め、1 バイト超えたら読まない。無いファイルも読めない")
    func fileSizeCap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kit-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Self.json()
        func padded(to count: Int) -> Data { base + Data(repeating: 0x20, count: count - base.count) }
        let ok = folder.appendingPathComponent("Ok.stacknestbook")
        try padded(to: StackNestFormat.maxFileBytes).write(to: ok)
        #expect(try StackNestBookReference.load(contentsOf: ok).startPage == 41)
        let big = folder.appendingPathComponent("Big.stacknestbook")
        try padded(to: StackNestFormat.maxFileBytes + 1).write(to: big)
        #expect(throws: StackNestViewerError(.invalidReference)) { try StackNestBookReference.load(contentsOf: big) }
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference.load(contentsOf: folder.appendingPathComponent("missing.stacknestbook"))
        }
    }

    @Test("鍵は文字列にしても（description・debugDescription・dump・Optional）出てこない")
    func tokenIsRedacted() throws {
        let reference = try StackNestBookReference.parse(Self.json())
        var dumped = ""
        dump(reference, to: &dumped)
        let wrapped: StackNestBookReference? = reference
        for text in [String(describing: reference), String(reflecting: reference), "\(reference)", dumped,
                     String(describing: wrapped as Any)] {
            #expect(!text.contains("secret-token-value"))
            #expect(text.contains("<redacted>"))
        }
    }

    @Test("基点の資格情報は、万一値に入っていても説明にも dump にも出さない（多重の守り）")
    func userInfoIsRedactedFromDescriptions() {
        let reference = StackNestBookReference(
            uncheckedVersion: 1, title: "t",
            bookURL: URL(string: "http://alice:hunter2@192.0.2.10:51234/api/v1/libraries/L/books/7")!,
            token: "secret-token-value", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), pageCount: 3,
            direction: nil, startPage: 0)
        var dumped = ""
        dump(reference, to: &dumped)
        for text in [String(describing: reference), String(reflecting: reference), dumped] {
            #expect(!text.contains("hunter2"))
            #expect(!text.contains("alice"))
            #expect(text.contains("192.0.2.10:51234/api/v1/libraries/L/books/7"))
        }
    }

    /// 基点に資格情報がある相対 URL（絶対化すると `alice:hunter2@` が現れる）。
    private static var credentialedRelativeURL: URL {
        let base = URL(string: "http://alice:hunter2@127.0.0.1:51234/api/v1/libraries/L/")!
        return URL(string: "books/7", relativeTo: base)!
    }

    @Test("作る側の init は、基点に資格情報がある相対 URL も読む側と同じく断る")
    func producerRejectsRelativeURLWithCredentialedBase() {
        let relative = Self.credentialedRelativeURL
        #expect(relative.absoluteString.contains("hunter2"))
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference(
                version: 1, title: "t", bookURL: relative, token: "t", expiresAt: .distantFuture,
                pageCount: 1, direction: .rightToLeft, startPage: 0)
        }
        expectInvalid(Self.json(["book": relative.absoluteString]))
    }

    @Test("相対 URL の基点の資格情報も、description・debugDescription・dump に出さない")
    func relativeURLCredentialsAreRedacted() {
        let reference = StackNestBookReference(
            uncheckedVersion: 1, title: "t", bookURL: Self.credentialedRelativeURL, token: "secret-token-value",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000), pageCount: 3, direction: nil, startPage: 0)
        var dumped = ""
        dump(reference, to: &dumped)
        for text in [reference.description, reference.debugDescription, String(reflecting: reference), dumped] {
            #expect(!text.contains("hunter2"))
            #expect(!text.contains("alice"))
            #expect(text.contains("127.0.0.1:51234/api/v1/libraries/L/books/7"))
        }
    }

    @Test("参照ファイルは Encodable にしない（鍵を JSON へ書き出す経路を型で塞ぐ）")
    func isNotEncodable() {
        #expect(!(StackNestBookReference.self is any Encodable.Type))
    }

    @Test("期限: 期限の時刻ちょうどから先は切れている")
    func expiryBoundary() throws {
        let reference = try StackNestBookReference.parse(Self.json())
        #expect(!reference.isExpired(at: reference.expiresAt.addingTimeInterval(-1)))
        #expect(reference.isExpired(at: reference.expiresAt))
        #expect(reference.isExpired(at: reference.expiresAt.addingTimeInterval(1)))
    }

    @Test("拡張子の判定は大文字小文字を区別しない")
    func recognisesTheExtension() {
        #expect(StackNestBookReference.isReferenceFile(URL(fileURLWithPath: "/a/Book.stacknestbook")))
        #expect(StackNestBookReference.isReferenceFile(URL(fileURLWithPath: "/a/b/Book.STACKNESTBOOK")))
        #expect(!StackNestBookReference.isReferenceFile(URL(fileURLWithPath: "/a/Book.json")))
        #expect(!StackNestBookReference.isReferenceFile(URL(fileURLWithPath: "/a/stacknestbook")))
    }

    @Test("開くページを本の中に収める")
    func clampsStartPage() {
        #expect(StackNestBookReference.clampedStartPage(41, pageCount: 180) == 41)
        #expect(StackNestBookReference.clampedStartPage(500, pageCount: 180) == 179)
        #expect(StackNestBookReference.clampedStartPage(-3, pageCount: 180) == 0)
        #expect(StackNestBookReference.clampedStartPage(5, pageCount: 0) == 0)
    }

    @Test("作る側の init は、読む側と同じ検査に通らない値で投げる")
    func producerInitValidates() {
        func make(version: Int = 1, book: String = "http://127.0.0.1:1/api/v1/libraries/L/books/1",
                  token: String = "t", pageCount: Int = 1, startPage: Int = 0) throws {
            _ = try StackNestBookReference(
                version: version, title: "t", bookURL: URL(string: book)!, token: token, expiresAt: .distantFuture,
                pageCount: pageCount, direction: .rightToLeft, startPage: startPage)
        }
        #expect(throws: StackNestViewerError(.unsupportedVersion, formatVersion: 2)) { try make(version: 2) }
        #expect(throws: StackNestViewerError(.invalidReference)) { try make(version: 0) }
        for book in ["ftp://127.0.0.1/x", "http://127.0.0.1/x?y=1", "http://127.0.0.1/x#y", "http://u:p@127.0.0.1/x"] {
            #expect(throws: StackNestViewerError(.invalidReference), "\(book)") { try make(book: book) }
        }
        #expect(throws: StackNestViewerError(.invalidReference)) { try make(token: "a b") }
        #expect(throws: StackNestViewerError(.invalidReference)) { try make(token: "") }
        #expect(throws: StackNestViewerError(.invalidReference)) { try make(pageCount: StackNestFormat.maxPageCount + 1) }
        #expect(throws: StackNestViewerError(.invalidReference)) { try make(startPage: -1) }
    }

    @Test("読む向き: rtl・ltr と知らない値の往復")
    func readingDirectionRoundTrips() {
        for raw in ["rtl", "ltr", "ttb", "RTL"] {
            #expect(StackNestReadingDirection(rawValue: raw).rawValue == raw)
        }
        #expect(StackNestReadingDirection(rawValue: "RTL") == .unknown("RTL"))
    }
}

@Suite("manifest の読み取り")
struct StackNestBookManifestTests {
    @Test("StackNest の manifest（pageOverrides など知らない項目付き）を読む")
    func parsesServerManifest() throws {
        let data = Data(#"{"pageCount":12,"direction":"ltr","format":"archive","etag":"abc","pageOverrides":{"3":1}}"#.utf8)
        #expect(try StackNestBookManifest.parse(data)
                == StackNestBookManifest(pageCount: 12, direction: .leftToRight, format: "archive", etag: "abc"))
    }

    @Test("etag・direction・format が無くても読む")
    func toleratesMissingOptionalKeys() throws {
        let manifest = try StackNestBookManifest.parse(Data(#"{"pageCount":3}"#.utf8))
        #expect(manifest == StackNestBookManifest(pageCount: 3, direction: nil, format: nil, etag: nil))
    }

    @Test("ページ数が無い・整数でない・上限を超える・壊れた JSON は .invalidResponse")
    func rejectsBrokenManifests() {
        for body in [#"{}"#, #"{"pageCount":"3"}"#, #"{"pageCount":true}"#, #"{"pageCount":1.5}"#,
                     #"{"pageCount":100001}"#, #"{"pageCount":-1}"#, "not json"] {
            #expect(throws: StackNestViewerError(.invalidResponse), "\(body)") {
                try StackNestBookManifest.parse(Data(body.utf8))
            }
        }
    }
}

@Suite("いっしょに渡した本の組（handoff）")
struct StackNestHandoffGroupTests {
    static func json(handoff: String?) -> Data {
        var text = String(decoding: StackNestBookReferenceTests.json(removing: []), as: UTF8.self)
        if let handoff {
            text = String(text.dropLast()) + ",\"handoff\":\(handoff)}"
        }
        return Data(text.utf8)
    }

    @Test("組を読む。無ければ nil")
    func parsesHandoff() throws {
        let reference = try StackNestBookReference.parse(Self.json(handoff: #"{"id":"abcdEFGH-_12","index":2,"count":5}"#))
        #expect(reference.handoff == (try StackNestHandoffGroup(id: "abcdEFGH-_12", index: 2, count: 5)))
        #expect(try StackNestBookReference.parse(Self.json(handoff: nil)).handoff == nil)
        #expect(try StackNestBookReference.parse(Self.json(handoff: #"{"id":"abcdEFGH","index":0,"count":1}"#)).handoff?.count == 1)
    }

    @Test("dump は組が有るときだけ handoff を出す（組の無い参照ファイルの dump は前と同じ）")
    func dumpShowsTheGroupOnlyWhenPresent() throws {
        var plain = ""
        dump(try StackNestBookReference.parse(Self.json(handoff: nil)), to: &plain)
        #expect(!plain.contains("handoff"))
        var grouped = ""
        dump(try StackNestBookReference.parse(Self.json(handoff: #"{"id":"abcdEFGH","index":0,"count":2}"#)), to: &grouped)
        #expect(grouped.contains("handoff"))
        #expect(grouped.contains("abcdEFGH"))
    }

    @Test("形の外れた組は参照ファイルを断らずに nil にする")
    func ignoresMalformedHandoff() throws {
        for value in [#""abc""#, #"[]"#, #"{"index":0,"count":2}"#, #"{"id":"abcdEFGH","count":2}"#,
                      #"{"id":"abcdEFGH","index":0}"#, #"{"id":"short","index":0,"count":2}"#,
                      #"{"id":"abcd EFGH","index":0,"count":2}"#, #"{"id":"abcd/EFGH","index":0,"count":2}"#,
                      #"{"id":"abcdEFGH","index":2,"count":2}"#, #"{"id":"abcdEFGH","index":-1,"count":2}"#,
                      #"{"id":"abcdEFGH","index":0,"count":0}"#, #"{"id":"abcdEFGH","index":0,"count":10001}"#,
                      #"{"id":"abcdEFGH","index":true,"count":2}"#, #"{"id":"abcdEFGH","index":0.5,"count":2}"#,
                      "{\"id\":\"\(String(repeating: "a", count: 65))\",\"index\":0,\"count\":2}"] {
            let reference = try StackNestBookReference.parse(Self.json(handoff: value))
            #expect(reference.handoff == nil, "\(value)")
            #expect(reference.pageCount > 0)
        }
    }

    @Test("作る側は読む側が捨てる組を作れない")
    func producerRejectsInvalidGroups() throws {
        for (id, index, count) in [("short", 0, 2), ("abcdEFGH", 2, 2), ("abcdEFGH", -1, 2), ("abcdEFGH", 0, 0),
                                   ("abcdEFGH", 0, StackNestHandoffGroup.maxCount + 1), ("abcd=EFGH", 0, 2)] {
            #expect(throws: StackNestViewerError(.invalidReference), "\(id) \(index) \(count)") {
                try StackNestHandoffGroup(id: id, index: index, count: count)
            }
        }
        let edge = try StackNestHandoffGroup(id: String(repeating: "a", count: 64), index: 9_999,
                                             count: StackNestHandoffGroup.maxCount)
        #expect(edge.index == 9_999)
    }

    @Test("with(handoff:) は組だけを差し替え、書いて読み直しても同じ")
    func withHandoffReplacesOnlyTheGroup() throws {
        let reference = try StackNestBookReference.parse(Self.json(handoff: nil))
        let group = try StackNestHandoffGroup(id: "abcdEFGH", index: 0, count: 2)
        let grouped = reference.with(handoff: group)
        #expect(grouped.handoff == group)
        #expect(grouped.with(handoff: nil) == reference)
        #expect(try StackNestBookReference.parse(grouped.encodedJSON()) == grouped)
    }

    @Test("組は description と dump に出る（秘密ではない）。鍵は出ない")
    func descriptionShowsHandoff() throws {
        let reference = try StackNestBookReference.parse(Self.json(handoff: #"{"id":"abcdEFGH","index":1,"count":3}"#))
        #expect(reference.description.contains("handoff: abcdEFGH 2/3"))
        #expect(!reference.description.contains(reference.token))
    }
}
