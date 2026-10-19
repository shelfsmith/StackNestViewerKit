import Foundation

/// manifest のうち、ビューアが使うもの（ほかの項目は読み飛ばす）。`etag` を optional にするのは、部品を使う
/// 将来のサーバや手元の偽のサーバが付けないことに備えるため（StackNest は manifest に必ず付ける）。部品は ETag を使わない。
///
/// The parts of a manifest a viewer uses (other keys are ignored). `etag` is optional for servers that
/// omit it; the kit doesn't use ETags.
public struct StackNestBookManifest: Sendable, Equatable {
    /// ページ数（正）。 / The page count (authoritative).
    public let pageCount: Int
    /// 読む向き。 / The reading direction.
    public let direction: StackNestReadingDirection?
    /// 本の形式（参考）。 / The book's format (informational).
    public let format: String?
    /// manifest の ETag。 / The manifest's ETag.
    public let etag: String?
    /// ページの名前（StackNest のページ番号の順。`pageNames[n]` が `pages/{n}` の名前）。書庫の本は書庫の中のパス
    /// （`フォルダ/001.jpg`。区切りは `/`）、フォルダの本はファイル名。頼んだとき（`Configuration.requestsPageNames`）
    /// だけ StackNest が付ける。PDF・画像の EPUB・古い StackNest では付かず nil。名前は本の中から来た信頼できない
    /// 文字列で、表示と見分けのためのもの: ファイルのパスとして使わない（`..` や先頭の `/` を含むことがある）。
    ///
    /// The page names in StackNest page order (`pageNames[n]` names `pages/{n}`): the path inside the archive for
    /// archive books (`folder/001.jpg`, separated by `/`), the file name for folder books. StackNest sends them only
    /// when asked (`Configuration.requestsPageNames`); PDFs, image EPUBs and older StackNest versions give nil. The
    /// names come from inside the book and aren't trusted: use them for display and to tell pages apart, never as
    /// file system paths (they can contain `..` or start with `/`).
    public let pageNames: [String]?

    /// 値から作る。 / Creates a manifest from values.
    public init(pageCount: Int, direction: StackNestReadingDirection?, format: String?, etag: String?) {
        self.init(pageCount: pageCount, direction: direction, format: format, etag: etag, pageNames: nil)
    }

    /// 値から作る（`pageNames` つき）。前の版の `init(pageCount:direction:format:etag:)` を残すため、既定値ではなく別の init にする
    /// （既定値の引数を足すと、前の版の init が公開の面から消える）。
    ///
    /// Creates a manifest from values, with `pageNames`. A separate initializer rather than a defaulted argument keeps
    /// the previous `init(pageCount:direction:format:etag:)` in the public interface.
    public init(pageCount: Int, direction: StackNestReadingDirection?, format: String?, etag: String?,
                pageNames: [String]?)
    {
        self.pageCount = pageCount
        self.direction = direction
        self.format = format
        self.etag = etag
        self.pageNames = pageNames
    }

    /// manifest の JSON を読む。読めない・ページ数が整数でない・上限を超えるなら `.invalidResponse`。
    /// `pageNames` は形が外れていれば（数がページ数と違う・空・重複・表示を崩す文字・長すぎる名前を含む）、manifest を
    /// 断らずに nil にする。
    ///
    /// Parses manifest JSON. Throws `.invalidResponse` when it can't be read or the page count is invalid.
    /// `pageNames` that are malformed (count differs from the page count, or an empty, repeated, overlong name or one
    /// with characters that break the display) become nil instead of failing the manifest.
    public static func parse(_ data: Data) throws -> StackNestBookManifest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pageCount = JSONValues.integer(root["pageCount"]),
              (0...StackNestFormat.maxPageCount).contains(pageCount)
        else { throw StackNestViewerError(.invalidResponse) }
        return StackNestBookManifest(
            pageCount: pageCount,
            direction: (root["direction"] as? String).map(StackNestReadingDirection.init(rawValue:)),
            format: root["format"] as? String, etag: root["etag"] as? String,
            pageNames: acceptablePageNames(root["pageNames"], pageCount: pageCount))
    }

    /// 1 つのページの名前の長さの上限（UTF-8 のバイト数）。 / The longest accepted page name, in UTF-8 bytes.
    public static let maxPageNameBytes = 1024

    /// ページの名前の一覧の検査。文字列の配列で、数がページ数と同じ、どの名前も空でなく `maxPageNameBytes` 以下で
    /// 表示を崩す文字（制御文字 = 改行・NUL など、行・段落の区切り U+2028・U+2029、双方向の書式指定 U+202A〜U+202E・
    /// U+2066〜U+2069）を含まず、重複しないときだけ返す。重複は Swift の文字列の等しさ（正準等価: NFC と NFD は同じ名前）
    /// で見る。1 つでも外れたら一覧ごと捨てる（番号と名前の対応が崩れた一覧を部分的に使わない）。
    ///
    /// Checks a page name list: an array of strings with one name per page, each non-empty, at most
    /// `maxPageNameBytes`, free of characters that break the display (control characters such as newlines and NUL,
    /// the separators U+2028 and U+2029, and the bidirectional formatting characters U+202A–U+202E and
    /// U+2066–U+2069) and unique. Uniqueness uses Swift string equality (canonical equivalence: NFC and NFD forms are
    /// the same name). One bad entry drops the whole list, so a list whose numbering may be off is never used in part.
    static func acceptablePageNames(_ value: Any?, pageCount: Int) -> [String]? {
        guard let names = value as? [Any], names.count == pageCount else { return nil }
        var result: [String] = []
        result.reserveCapacity(names.count)
        var seen = Set<String>(minimumCapacity: names.count)
        for case var name as String in names {
            // JSONSerialization の文字列は NSString のままで、1 文字ずつ読むと橋渡しが重い（10 万ページで 0.5 秒）。
            // 一度だけ Swift の UTF-8 の文字列にしてからバイトで見る（判定も Set の hash もこの上で速い）。
            name.makeContiguousUTF8()
            guard !name.isEmpty, name.utf8.count <= maxPageNameBytes, !containsDisallowedCharacters(name),
                  seen.insert(name).inserted
            else { return nil }
            result.append(name)
        }
        return result.count == pageCount ? result : nil
    }

    /// 名前に許さない文字を UTF-8 のバイト列で探す。制御文字（Cc）は U+0000〜U+001F・U+007F（1 バイト）と
    /// U+0080〜U+009F（C2 80〜C2 9F）、U+2028〜U+202E は E2 80 A8〜AE、U+2066〜U+2069 は E2 81 A6〜A9。
    ///
    /// Looks for disallowed characters in the UTF-8 bytes: Cc is U+0000–U+001F and U+007F (one byte) plus
    /// U+0080–U+009F (C2 80–9F); U+2028–U+202E are E2 80 A8–AE and U+2066–U+2069 are E2 81 A6–A9.
    private static func containsDisallowedCharacters(_ name: String) -> Bool {
        var previous2: UInt8 = 0
        var previous: UInt8 = 0
        for byte in name.utf8 {
            if byte < 0x20 || byte == 0x7F { return true }
            if previous == 0xC2, (0x80...0x9F).contains(byte) { return true }
            if previous2 == 0xE2, previous == 0x80, (0xA8...0xAE).contains(byte) { return true }
            if previous2 == 0xE2, previous == 0x81, (0xA6...0xA9).contains(byte) { return true }
            previous2 = previous
            previous = byte
        }
        return false
    }
}
