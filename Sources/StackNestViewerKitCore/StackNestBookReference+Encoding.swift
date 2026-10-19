import Foundation

extension StackNestBookReference {
    /// 参照ファイルの JSON を書く（UTF-8・日時は ISO 8601 の UTC の `Z`・小数秒なし・キーの順・字下げ・
    /// スラッシュをエスケープしない）。同じ値からは常に同じバイト列になる（`Documentation/Samples` の golden）。
    ///
    /// Writes reference file JSON (UTF-8, ISO 8601 UTC dates without fractional seconds, sorted keys, pretty
    /// printed, unescaped slashes). The same value always gives the same bytes.
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(self))
    }

    /// 書き出しの形（このファイルの中だけで使う。鍵を JSON にする経路はここだけ）。
    private struct Wire: Encodable {
        let format: String
        let version: Int
        let title: String
        let book: String
        let token: String
        let expiresAt: Date
        let pageCount: Int
        let direction: String?
        let startPage: Int
        /// nil なら項目ごと書かない（1 冊だけの参照ファイルのバイト列は前と同じ）。
        let handoff: HandoffWire?

        struct HandoffWire: Encodable {
            let id: String
            let index: Int
            let count: Int
        }

        init(_ reference: StackNestBookReference) {
            format = StackNestFormat.formatName
            version = reference.version
            title = reference.title
            book = reference.bookURL.absoluteString
            token = reference.token
            expiresAt = reference.expiresAt
            pageCount = reference.pageCount
            direction = reference.direction?.rawValue
            startPage = reference.startPage
            handoff = reference.handoff.map { HandoffWire(id: $0.id, index: $0.index, count: $0.count) }
        }
    }
}
