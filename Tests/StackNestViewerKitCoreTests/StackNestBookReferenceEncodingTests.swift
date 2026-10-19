import Foundation
import Testing

@testable import StackNestViewerKitCore

/// 作る側（StackNest が参照ファイルを書く）。作った参照ファイルが必ず読めること、バイト列が golden と一致すること、
/// 部品を使わない古い読み手でも読めることを固定する。
@Suite("参照ファイルを作る")
struct StackNestBookReferenceEncodingTests {
    static let goldenBook = URL(string: "http://127.0.0.1:51234/api/v1/libraries/00000000-0000-4000-8000-000000000001/books/42")!

    static func goldenReference() throws -> StackNestBookReference {
        try StackNestBookReference(
            version: 1, title: "Example Book", bookURL: goldenBook, token: "example-token-not-a-secret",
            expiresAt: try Date("2099-12-31T00:00:00Z", strategy: .iso8601), pageCount: 180,
            direction: .rightToLeft, startPage: 41)
    }

    @Test("golden: 固定の入力の encodedJSON() が Documentation/Samples/reference-v1.stacknestbook とバイト単位で一致する")
    func encodedJSONMatchesGolden() throws {
        let golden = try DocumentationSamples.data("reference-v1.stacknestbook")
        #expect(try Self.goldenReference().encodedJSON() == golden)
        #expect(golden.count == 334)
    }

    @Test("golden: 組（handoff）の付いた encodedJSON() が Documentation/Samples/reference-v1-handoff.stacknestbook と一致し、古い読み手も読める")
    func handoffEncodingMatchesGolden() throws {
        let base = try Self.goldenReference()
        let reference = try StackNestBookReference(
            version: 1, title: base.title, bookURL: base.bookURL, token: base.token, expiresAt: base.expiresAt,
            pageCount: base.pageCount, direction: .rightToLeft, startPage: base.startPage,
            handoff: try StackNestHandoffGroup(id: "ZXhhbXBsZS1oYW5kb2Zm", index: 1, count: 3))
        let golden = try DocumentationSamples.data("reference-v1-handoff.stacknestbook")
        #expect(try reference.encodedJSON() == golden)
        #expect(try StackNestBookReference.parse(golden) == reference)
        // 部品より前の読み手は知らない項目として読み飛ばす（組を知らないビューアも 1 冊として開ける）。
        #expect(try LegacyReferenceReader.parse(golden).startPage == 41)
    }

    @Test("golden: 部品より前の読み手（凍結した写し）が golden を読める")
    func legacyReaderReadsGolden() throws {
        let legacy = try LegacyReferenceReader.parse(try DocumentationSamples.data("reference-v1.stacknestbook"))
        #expect(legacy == LegacyReferenceReader.Reference(
            version: 1, title: "Example Book", bookURL: Self.goldenBook, token: "example-token-not-a-secret",
            expiresAt: try Date("2099-12-31T00:00:00Z", strategy: .iso8601), pageCount: 180, direction: "rtl",
            startPage: 41))
    }

    @Test("作る → 読むの往復（IPv6 の区域 ID・日本語の題名・スラッシュ）")
    func roundTrips() throws {
        let reference = try StackNestBookReference(
            version: 1, title: "日本語の題名 / \"引用\"", bookURL: URL(string: "http://[fe80::1%25en0]:51234/api/v1/relay/abc")!,
            token: "q8Zk3nJ0r4bW-_sYt1uVw2xYz3aBcDeFgHiJkLmNoPq", expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            pageCount: 0, direction: .leftToRight, startPage: 0)
        let data = try reference.encodedJSON()
        #expect(try StackNestBookReference.parse(data) == reference)
        #expect(String(decoding: data, as: UTF8.self).contains(#"\/"#) == false, "スラッシュをエスケープしない")
        #expect(try LegacyReferenceReader.parse(data).bookURL == reference.bookURL)
    }

    @Test("小数秒は書かない（読み直すと秒に切り捨てた時刻になる）")
    func dropsFractionalSeconds() throws {
        let reference = try StackNestBookReference(
            version: 1, title: "t", bookURL: Self.goldenBook, token: "t", expiresAt: Date(timeIntervalSince1970: 1_800_000_000.75),
            pageCount: 1, direction: .rightToLeft, startPage: 0)
        let text = String(decoding: try reference.encodedJSON(), as: UTF8.self)
        #expect(text.contains(#""expiresAt" : "2027-01-15T08:00:00Z""#))
    }

    @Test("作る側は、読む側が断る値を受け付けない（天井の startPage・負の年の期限）。相対 URL も往復で == になる")
    func producerRejectsWhatReaderRefuses() throws {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference(
                version: 1, title: "t", bookURL: Self.goldenBook, token: "t", expiresAt: expires,
                pageCount: 1, direction: .rightToLeft, startPage: 1_000_000_000_000_000)
        }
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference(
                version: 1, title: "t", bookURL: Self.goldenBook, token: "t",
                expiresAt: Date(timeIntervalSinceReferenceDate: -7e10),
                pageCount: 1, direction: .rightToLeft, startPage: 0)
        }
        let edge = try StackNestBookReference(
            version: 1, title: "t", bookURL: Self.goldenBook, token: "t", expiresAt: expires,
            pageCount: 1, direction: .rightToLeft, startPage: 999_999_999_999_999)
        #expect(try StackNestBookReference.parse(edge.encodedJSON()) == edge)
        let relative = try StackNestBookReference(
            version: 1, title: "t", bookURL: URL(string: "books/42", relativeTo: URL(string: "http://127.0.0.1:51234/api/v1/")!)!,
            token: "t", expiresAt: expires, pageCount: 1, direction: .rightToLeft, startPage: 0)
        #expect(try StackNestBookReference.parse(relative.encodedJSON()) == relative)
    }

    @Test("部品の読み手が、部品自身の golden を期待どおりに読む")
    func kitReaderReadsGolden() throws {
        let parsed = try StackNestBookReference.parse(try DocumentationSamples.data("reference-v1.stacknestbook"))
        #expect(parsed == (try Self.goldenReference()))
        #expect(parsed.title == "Example Book")
        #expect(parsed.direction == .rightToLeft)
        #expect(parsed.pageCount == 180)
        #expect(parsed.startPage == 41)
    }

    @Test("読んだ参照ファイルに direction が無ければ、書き直しても direction を書かない")
    func omitsMissingDirection() throws {
        let parsed = try StackNestBookReference.parse(StackNestBookReferenceTests.json(removing: ["direction"]))
        let object = try JSONSerialization.jsonObject(with: try parsed.encodedJSON()) as? [String: Any]
        #expect(object?["direction"] == nil)
        #expect(object?["format"] as? String == "stacknest-book-reference")
    }
}

/// `Documentation/Samples` のサンプルの参照ファイル（形式の文書が示すもの）を全件読み、期待どおりの結果になること。
@Suite("文書のサンプル")
struct DocumentationSampleTests {
    @Test("置いてあるサンプルはこの一覧と一致する（文書と試験がずれない）")
    func samplesAreAllCovered() throws {
        #expect(try DocumentationSamples.fileNames() == [
            "reference-credentials.stacknestbook", "reference-expired.stacknestbook",
            "reference-ipv6-zone.stacknestbook", "reference-lan-host.stacknestbook",
            "reference-malformed.stacknestbook", "reference-v1-handoff.stacknestbook",
            "reference-v1-unknown-keys.stacknestbook",
            "reference-v1.stacknestbook", "reference-v2.stacknestbook",
        ])
    }

    @Test("読めるサンプル")
    func readableSamples() throws {
        let unknown = try StackNestBookReference.parse(try DocumentationSamples.data("reference-v1-unknown-keys.stacknestbook"))
        #expect(unknown.direction == .leftToRight)
        #expect(unknown.pageCount == 24)
        let expired = try StackNestBookReference.parse(try DocumentationSamples.data("reference-expired.stacknestbook"))
        #expect(expired.isExpired())
        let zone = try StackNestBookReference.parse(try DocumentationSamples.data("reference-ipv6-zone.stacknestbook"))
        #expect(zone.bookURL.host(percentEncoded: false) == "fe80::1%en0")
        let lan = try StackNestBookReference.parse(try DocumentationSamples.data("reference-lan-host.stacknestbook"))
        #expect(lan.bookURL.host(percentEncoded: false) == "192.0.2.1", "形式はホストを絞らない（絞るのはセッション）")
        let grouped = try StackNestBookReference.parse(try DocumentationSamples.data("reference-v1-handoff.stacknestbook"))
        #expect(grouped.handoff?.index == 1)
        #expect(grouped.handoff?.count == 3)
    }

    @Test("読めないサンプル")
    func unreadableSamples() throws {
        #expect(throws: StackNestViewerError(.unsupportedVersion, formatVersion: 2)) {
            try StackNestBookReference.parse(try DocumentationSamples.data("reference-v2.stacknestbook"))
        }
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference.parse(try DocumentationSamples.data("reference-malformed.stacknestbook"))
        }
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference.parse(try DocumentationSamples.data("reference-credentials.stacknestbook"))
        }
    }
}
