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
    /// 本の同一性（同じライブラリの同じ本なら、題名を変えても・ファイルを動かしても・StackNest を起動し直しても・
    /// リモートの本の中継を通しても同じ値。消して取り込み直した本は別の値）。中身を読み取らず、等しいかだけを比べる。
    /// StackNest が付けない（古い版・リモートのサーバが古い）ときと、形が約束から外れるときは nil。
    ///
    /// The book's identity: the same value for the same book of the same library, across renames, moves,
    /// StackNest restarts and the relay for remote books (a book removed and imported again gets a new value).
    /// Compare it for equality only; don't read meaning into it. nil when StackNest doesn't send it (older
    /// versions, or an older remote server) or when its shape is outside the format.
    public let bookIdentity: String?

    /// 値から作る。 / Creates a manifest from values.
    public init(pageCount: Int, direction: StackNestReadingDirection?, format: String?, etag: String?) {
        self.init(pageCount: pageCount, direction: direction, format: format, etag: etag, bookIdentity: nil)
    }

    /// 値から作る（`bookIdentity` つき）。前の版の `init(pageCount:direction:format:etag:)` を残すため、既定値ではなく別の init にする
    /// （既定値の引数を足すと、前の版の init が公開の面から消える）。
    ///
    /// Creates a manifest from values, with `bookIdentity`. A separate initializer rather than a defaulted argument keeps
    /// the previous `init(pageCount:direction:format:etag:)` in the public interface.
    public init(pageCount: Int, direction: StackNestReadingDirection?, format: String?, etag: String?,
                bookIdentity: String?)
    {
        self.pageCount = pageCount
        self.direction = direction
        self.format = format
        self.etag = etag
        self.bookIdentity = bookIdentity
    }

    /// manifest の JSON を読む。読めない・ページ数が整数でない・上限を超えるなら `.invalidResponse`。
    /// `bookIdentity` は形が約束から外れていれば（文字列でない・使えない文字・長さ）、manifest を断らずに nil にする。
    ///
    /// Parses manifest JSON. Throws `.invalidResponse` when it can't be read or the page count is invalid.
    /// A `bookIdentity` outside the format (not a string, a disallowed character or length) becomes nil
    /// instead of failing the manifest.
    public static func parse(_ data: Data) throws -> StackNestBookManifest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pageCount = JSONValues.integer(root["pageCount"]),
              (0...StackNestFormat.maxPageCount).contains(pageCount)
        else { throw StackNestViewerError(.invalidResponse) }
        return StackNestBookManifest(
            pageCount: pageCount,
            direction: (root["direction"] as? String).map(StackNestReadingDirection.init(rawValue:)),
            format: root["format"] as? String, etag: root["etag"] as? String,
            bookIdentity: (root["bookIdentity"] as? String).flatMap { isAcceptableBookIdentity($0) ? $0 : nil })
    }

    /// 同一性の値の上限の長さ。 / The longest accepted `bookIdentity`.
    public static let maxBookIdentityLength = 128

    /// 同一性の値の検査: 1〜128 文字の ASCII の英数字と `-._~:` だけ。ビューアはこの値を保存データの鍵にするので、
    /// 制御文字・空白・区切りに使われがちな文字（`/` など）を入れない。
    ///
    /// Whether a `bookIdentity` has the accepted shape: 1 to 128 ASCII letters, digits and `-._~:`. Viewers use
    /// it as a key for saved data, so control characters, spaces and separators such as `/` are kept out.
    public static func isAcceptableBookIdentity(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxBookIdentityLength else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~", ":": return true
            default: return false
            }
        }
    }
}
