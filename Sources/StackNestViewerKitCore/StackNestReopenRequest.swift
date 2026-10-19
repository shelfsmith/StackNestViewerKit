import Foundation

/// ビューアから StackNest への「この本をもう一度渡して」の頼み（`stacknest://viewer/reopen?…`）。
///
/// 参照ファイルの鍵には期限があり、ポートや中継の id は渡すたびに変わるので、ビューアは参照ファイルを残しておいて後から
/// 開き直すことができない（StackNest が動いているとも限らない）。そこで、ビューアの履歴や保存データから本を開き直すときは、
/// この URL を `NSWorkspace.open` で開き、StackNest に今までどおりの受け渡し（新しい鍵の参照ファイル）をしてもらう。
/// StackNest が動いていなければ macOS が起動する。ビューアへは何も返らない: 結果は、ふつうの受け渡しか、StackNest の
/// 画面の知らせ（ライブラリが見つからない・施錠の解錠を待つ・本が無いなど）。
///
/// 頼めるのはローカルのライブラリの本だけ（リモートの本の中継の `book` からは作れない）。鍵は含めない。StackNest は、
/// 本の同一性（manifest の `bookIdentity`）が今のその本と同じときだけ渡す（番号が使い回された別の本を開かない）。
/// ビューアは、manifest の `bookIdentity` を受け取った本についてだけ頼みを作れる（古い StackNest は同一性を付けない）。
///
/// A viewer's request to StackNest to hand a book over again (`stacknest://viewer/reopen?…`). Reference-file
/// tokens expire, and ports and relay ids change with every hand-off, so a viewer can't keep a reference file and
/// open it later (StackNest may not even be running). To reopen a book from its history or saved data, a viewer
/// opens this URL with `NSWorkspace.open`, and StackNest does a normal hand-off with a fresh reference file;
/// macOS launches StackNest if needed. Nothing comes back to the viewer: the result is a normal hand-off or a
/// notice in StackNest. Only books of local libraries can be requested (a relayed `book` can't make one), and the
/// request carries no token. StackNest hands the book over only when its identity (the manifest's
/// `bookIdentity`) still matches, so a reused book number never opens another book.
public struct StackNestReopenRequest: Sendable, Hashable, CustomStringConvertible {
    /// URL のスキーム。 / The URL scheme.
    public static let scheme = "stacknest"
    /// URL のホストとパス（`stacknest://viewer/reopen`）。 / The URL's host and path.
    static let host = "viewer"
    static let path = "/reopen"
    /// 本の番号の上限（JSON の整数と同じ 2^53 未満）。 / The largest accepted book number.
    static let maxBookID = (1 << 53) - 1

    /// ライブラリの UUID（小文字にそろえて持つ）。 / The library UUID (kept lowercased).
    public let libraryUUID: String
    /// ライブラリの中の本の番号。 / The book number in the library.
    public let bookID: Int
    /// 本の同一性（manifest の `bookIdentity`）。 / The book identity (the manifest's `bookIdentity`).
    public let bookIdentity: String

    /// 値から作る。形が外れていれば `.invalidReference`。
    ///
    /// Creates a request from values. Throws `.invalidReference` when a value is malformed.
    public init(libraryUUID: String, bookID: Int, bookIdentity: String) throws {
        guard Self.isAcceptable(libraryUUID: libraryUUID, bookID: bookID, bookIdentity: bookIdentity) else {
            throw StackNestViewerError(.invalidReference)
        }
        self.init(checkedLibraryUUID: libraryUUID, bookID: bookID, bookIdentity: bookIdentity)
    }

    private init(checkedLibraryUUID libraryUUID: String, bookID: Int, bookIdentity: String) {
        self.libraryUUID = libraryUUID.lowercased()
        self.bookID = bookID
        self.bookIdentity = bookIdentity
    }

    private static func isAcceptable(libraryUUID: String, bookID: Int, bookIdentity: String) -> Bool {
        UUID(uuidString: libraryUUID) != nil && (1...maxBookID).contains(bookID)
            && StackNestBookManifest.isAcceptableBookIdentity(bookIdentity)
    }

    /// 参照ファイルの `book` と manifest の同一性から作る。手元の StackNest（ホストが loopback ―― `127.0.0.1`・`::1`・`localhost`）の
    /// ローカルのライブラリの本（`/api/v1/libraries/<UUID>/books/<番号>`）でなければ（中継の本・ほかの Mac の StackNest へ直接
    /// つないだ本・ほかの形）nil。頼みを受けるのは手元の StackNest なので、ほかの Mac のライブラリは頼めない。
    ///
    /// Makes a request from a reference's `book` and the manifest's identity. nil unless `book` is a local library
    /// book of the StackNest on this Mac (a loopback host — `127.0.0.1`, `::1` or `localhost` — and the path
    /// `/api/v1/libraries/<UUID>/books/<number>`), e.g. for relayed books or books of another Mac's StackNest: the
    /// request goes to the StackNest on this Mac.
    public init?(reference: StackNestBookReference, bookIdentity: String) {
        guard let host = reference.bookURL.absoluteURL.host(percentEncoded: false)?.lowercased(),
              ["127.0.0.1", "::1", "localhost"].contains(host)
        else { return nil }
        let segments = reference.bookURL.absoluteURL.path(percentEncoded: true)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 6, segments[0] == "api", segments[1] == "v1", segments[2] == "libraries",
              segments[4] == "books", let bookID = Self.decimal(segments[5]),
              Self.isAcceptable(libraryUUID: String(segments[3]), bookID: bookID, bookIdentity: bookIdentity)
        else { return nil }
        self.init(checkedLibraryUUID: String(segments[3]), bookID: bookID, bookIdentity: bookIdentity)
    }

    /// 頼みの URL を読む。スキーム・ホスト・パスが違う（ホストとパスはパーセントエンコードしない形だけ）、ポート（空のものも）・
    /// 資格情報・フラグメントが付く、3 つの値のどれかが無い・2 回ある・形が外れているなら nil。値は URL の問い合わせとして読む
    /// （パーセントエンコードは解いてから確かめる）。知らない問い合わせの項目は読み飛ばす（後の版が項目を足せるように）。
    ///
    /// Reads a request URL. nil when the scheme, host or path differ, or a value is missing, repeated or malformed.
    /// Unknown query items are ignored, so later versions can add items.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.percentEncodedHost?.lowercased() == Self.host,
              components.percentEncodedPath == Self.path,
              components.user == nil, components.password == nil, components.rangeOfPort == nil,
              components.fragment == nil, Self.authority(of: url.absoluteString)?.lowercased() == Self.host
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where ["library", "book", "identity"].contains(item.name) {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }
        guard let library = values["library"], let book = values["book"].flatMap({ Self.decimal(Substring($0)) }),
              let identity = values["identity"],
              Self.isAcceptable(libraryUUID: library, bookID: book, bookIdentity: identity)
        else { return nil }
        self.init(checkedLibraryUUID: library, bookID: book, bookIdentity: identity)
    }

    /// 頼みの URL（`stacknest://viewer/reopen?library=<UUID>&book=<番号>&identity=<同一性>`）。
    ///
    /// The request URL.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = Self.path
        components.queryItems = [
            URLQueryItem(name: "library", value: libraryUUID),
            URLQueryItem(name: "book", value: String(bookID)),
            URLQueryItem(name: "identity", value: bookIdentity),
        ]
        // 値はどれも URL の予約されていない文字（と `:`）なので、組み立ては失敗しない。
        return components.url!
    }

    /// `url` と同じ。 / Same as `url`.
    public var description: String { url.absoluteString }

    /// `scheme://` の後ろから最初の `/`・`?`・`#` までの部分（空のポート `viewer:` は URLComponents ではポートとして見えないので、
    /// 文字で見る）。`//` が無ければ nil。
    private static func authority(of text: String) -> Substring? {
        guard let start = text.range(of: "://") else { return nil }
        let rest = text[start.upperBound...]
        return rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    }

    /// 10 進の数字だけからなる正の番号（先頭の 0・符号・空白は通さない）。
    private static func decimal(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 16, text.first != "0", text.allSatisfy({ ("0"..."9").contains($0) })
        else { return nil }
        return Int(text)
    }
}
