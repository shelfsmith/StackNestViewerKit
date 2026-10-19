import Foundation

/// 参照ファイルの中身。作る側（StackNest）と読む側（ビューア）が共有する唯一の定義。
///
/// 鍵（`token`）はメモリの中だけで使う秘密。`Codable` にしないのは、鍵の入った値を JSON へ書き出す経路を
/// 明示の `encodedJSON()` だけにするため。`description`・`debugDescription`・`dump` は鍵を `<redacted>` にする。
///
/// The contents of a reference file — the single definition shared by the producer (StackNest) and readers
/// (viewers). The token is a secret kept in memory only. The type isn't `Codable`, so the only way to write the
/// token as JSON is the explicit `encodedJSON()`. `description`, `debugDescription` and `dump` redact the token.
public struct StackNestBookReference: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// 形式の版。 / The format version.
    public let version: Int
    /// 本の題名。 / The book's title.
    public let title: String
    /// 本の API の基点（`{book}`）。 / The base of the book's API (`{book}`).
    public let bookURL: URL
    /// その本専用の読み取りの鍵。 / The per-book read token.
    public let token: String
    /// 鍵の期限。 / When the token expires.
    public let expiresAt: Date
    /// 開いた時点のページ数（正は manifest）。 / The page count when opened (the manifest is authoritative).
    public let pageCount: Int
    /// 読む向き。読む側は無くても開く。作る側の `init` は必ず渡す（形式の文書では必須）。この非対称は意図したもの:
    /// 作る側は約束どおりに書き、読む側は約束から外れた古い・他の実装にも寛容にする。
    ///
    /// The reading direction. Readers open files without it; the producer's `init` always takes one (the
    /// format requires it). The asymmetry is deliberate: write strictly, read leniently.
    public let direction: StackNestReadingDirection?
    /// 開くページ（0 始まり・StackNest のページ番号）。 / The page to open (0-based StackNest page number).
    public let startPage: Int
    /// いっしょに渡した本の組（`handoff`）。1 冊だけ渡したとき・古い StackNest・形の外れた値では nil。
    ///
    /// The group of books handed over together (`handoff`); nil for a single book, older StackNest versions and
    /// malformed values.
    public let handoff: StackNestHandoffGroup?

    /// 作る側。読む側と同じ検査に通らない値は投げる（作った参照ファイルが必ず読めることを型で保証する）。
    ///
    /// For the producer. Throws for values a reader would refuse, so every file it writes can be read back.
    public init(version: Int, title: String, bookURL: URL, token: String, expiresAt: Date,
                pageCount: Int, direction: StackNestReadingDirection, startPage: Int) throws
    {
        try self.init(version: version, title: title, bookURL: bookURL, token: token, expiresAt: expiresAt,
                      pageCount: pageCount, direction: direction, startPage: startPage, handoff: nil)
    }

    /// 作る側（組つき）。前の版の `init(version:title:bookURL:token:expiresAt:pageCount:direction:startPage:)` を残すため、
    /// 既定値ではなく別の init にする（既定値の引数を足すと、前の版の init が公開の面から消える）。
    ///
    /// For the producer, with a group. A separate initializer rather than a defaulted argument keeps the previous
    /// initializer in the public interface.
    public init(version: Int, title: String, bookURL: URL, token: String, expiresAt: Date,
                pageCount: Int, direction: StackNestReadingDirection, startPage: Int,
                handoff: StackNestHandoffGroup?) throws
    {
        guard version >= 1 else { throw StackNestViewerError(.invalidReference) }
        guard StackNestFormat.supportedVersions.contains(version) else {
            throw StackNestViewerError(.unsupportedVersion, formatVersion: version)
        }
        guard Self.isAcceptableBookURL(bookURL), Self.isAcceptableToken(token),
              (0...StackNestFormat.maxPageCount).contains(pageCount),
              startPage >= 0, Double(startPage) < JSONValues.integerCeiling,
              Self.isReadableDate(expiresAt)
        else { throw StackNestViewerError(.invalidReference) }
        // 絶対形で持つ（相対 URL でも、書いて読み直した値と == になる）。
        self.init(uncheckedVersion: version, title: title, bookURL: bookURL.absoluteURL, token: token, expiresAt: expiresAt,
                  pageCount: pageCount, direction: direction, startPage: startPage, handoff: handoff)
    }

    /// 検査を済ませた値から作る（`parse` と `init` の後段。試験は伏せ字の多重の守りを確かめるのに使う）。
    init(uncheckedVersion version: Int, title: String, bookURL: URL, token: String, expiresAt: Date,
         pageCount: Int, direction: StackNestReadingDirection?, startPage: Int, handoff: StackNestHandoffGroup? = nil)
    {
        self.version = version
        self.title = title
        self.bookURL = bookURL
        self.token = token
        self.expiresAt = expiresAt
        self.pageCount = pageCount
        self.direction = direction
        self.startPage = startPage
        self.handoff = handoff
    }

    /// 参照ファイルの JSON を読む。形式が違う・必須の項目が無い・値の形が違うものは `.invalidReference`、
    /// 読めない版は `.unsupportedVersion`。知らない項目は読み飛ばす（後の版が項目を足しても開ける）。
    /// ホスト（`book` の宛先）はここでは絞らない（形式は LAN の宛先も許す。絞るのはセッション）。
    ///
    /// Parses reference file JSON. Throws `.invalidReference` for a wrong format, a missing key or a
    /// malformed value, and `.unsupportedVersion` for an unreadable version. Unknown keys are ignored. The
    /// host of `book` isn't restricted here; the session restricts it.
    public static func parse(_ data: Data) throws -> StackNestBookReference {
        let invalid = StackNestViewerError(.invalidReference)
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw invalid
        }
        guard root["format"] as? String == StackNestFormat.formatName else { throw invalid }
        // 版は形式の確認の後で見る（別の形式のファイルを「新しい版」と言わない）。
        guard let version = JSONValues.integer(root["version"]) else {
            throw StackNestViewerError(.unsupportedVersion)
        }
        // 1 未満は「新しい版」ではなく壊れたファイル（「アプリを更新して」と案内しない）。
        guard version >= 1 else { throw invalid }
        guard StackNestFormat.supportedVersions.contains(version) else {
            throw StackNestViewerError(.unsupportedVersion, formatVersion: version)
        }
        guard let bookString = root["book"] as? String, let bookURL = URL(string: bookString),
              isAcceptableBookURL(bookURL),
              let token = root["token"] as? String, isAcceptableToken(token),
              let expiresString = root["expiresAt"] as? String, let expiresAt = JSONValues.date(expiresString),
              let pageCount = JSONValues.integer(root["pageCount"]),
              (0...StackNestFormat.maxPageCount).contains(pageCount),
              let startPage = JSONValues.integer(root["startPage"]), startPage >= 0
        else { throw invalid }
        return StackNestBookReference(
            uncheckedVersion: version, title: root["title"] as? String ?? "", bookURL: bookURL, token: token,
            expiresAt: expiresAt, pageCount: pageCount,
            direction: (root["direction"] as? String).map(StackNestReadingDirection.init(rawValue:)),
            startPage: startPage, handoff: StackNestHandoffGroup.parse(root["handoff"]))
    }

    /// ファイルから読む。上限（`StackNestFormat.maxFileBytes`）＋1 バイトまでしか読まない（大きさを先に調べると、
    /// 調べてから読むまでの間に差し替えられうる）。読めない理由は区別しない（どれも StackNest から開き直すしかない）。
    /// 呼び出したスレッドで同期に読む。
    ///
    /// Reads a file, at most the limit plus one byte. Reasons it can't be read aren't distinguished. Reads
    /// synchronously on the calling thread.
    public static func load(contentsOf url: URL) throws -> StackNestBookReference {
        let invalid = StackNestViewerError(.invalidReference)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw invalid }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: StackNestFormat.maxFileBytes + 1),
              data.count <= StackNestFormat.maxFileBytes
        else { throw invalid }
        return try parse(data)
    }

    /// 組（`handoff`）だけを差し替えた写し（作る側が、組の冊数が決まってから書き込むため。ほかの値は検査済みのまま）。
    ///
    /// A copy with only `handoff` replaced (for producers that learn the group's size after building the
    /// references; the other values are already checked).
    public func with(handoff: StackNestHandoffGroup?) -> StackNestBookReference {
        StackNestBookReference(uncheckedVersion: version, title: title, bookURL: bookURL, token: token,
                               expiresAt: expiresAt, pageCount: pageCount, direction: direction,
                               startPage: startPage, handoff: handoff)
    }

    /// 期限を過ぎているか。期限の時刻ちょうどから切れている。 / Whether the token has expired (from `expiresAt` on).
    public func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }

    /// 拡張子が `stacknestbook` か（大文字小文字を区別しない）。 / Whether the extension is `stacknestbook` (any case).
    public static func isReferenceFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == StackNestFormat.fileExtension
    }

    /// 開くページを `0…pageCount-1` に収める（0 ページの本は 0）。 / Clamps the start page into the book.
    public static func clampedStartPage(_ page: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(0, page), pageCount - 1)
    }

    /// 書き出す形（`encodedJSON()` と同じ ISO 8601）にして読み直せる日時か。負の年などは読めない。
    private static func isReadableDate(_ date: Date) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode([date]),
              let strings = (try? JSONSerialization.jsonObject(with: data)) as? [String], let string = strings.first
        else { return false }
        return JSONValues.date(string) != nil
    }

    /// 基点の検査: http(s)・空でないホスト・問い合わせと断片と資格情報を持たない。問い合わせ・断片があると、
    /// 後ろへ足す `manifest` などが飲まれて別の宛先の要求になる。資格情報は宛先の取り違えの種になるので断る。
    static func isAcceptableBookURL(_ url: URL) -> Bool {
        let string = url.absoluteString
        guard !string.contains("?"), !string.contains("#"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false),
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil
        else { return false }
        return true
    }

    /// 鍵の検査: RFC 6750 の b64token（英数字と `-._~+/`、末尾にだけ `=`）。改行などの制御文字・空白が
    /// `Authorization` の値に入ると、要求の分割（ヘッダの注入）になる。StackNest の鍵（base64url）は必ず通る。
    static func isAcceptableToken(_ token: String) -> Bool {
        var body = Substring(token)
        while body.hasSuffix("=") { body = body.dropLast() }
        guard !body.isEmpty else { return false }
        return body.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~", "+", "/": return true
            default: return false
            }
        }
    }

    /// 鍵と基点の資格情報を伏せた説明。 / A description with the token and any base credentials redacted.
    public var description: String {
        "StackNestBookReference(version: \(version), title: \(title), book: \(redactedBookURL.absoluteString), "
            + "token: <redacted>, expiresAt: \(expiresAt), pageCount: \(pageCount), "
            + "direction: \(direction?.rawValue ?? "nil"), startPage: \(startPage)"
            + (handoff.map { ", handoff: \($0.id) \($0.index + 1)/\($0.count)" } ?? "") + ")"
    }

    /// `description` と同じ（伏せ字つき）。 / Same as `description` (redacted).
    public var debugDescription: String { description }

    /// `dump` などの反映。鍵は `<redacted>`。 / The mirror used by `dump` and friends; the token is `<redacted>`.
    public var customMirror: Mirror {
        // 組は有るときだけ出す（組の無い参照ファイルの dump は前の版と同じ）。
        var children: [Mirror.Child] = [
            ("version", version), ("title", title), ("bookURL", redactedBookURL), ("token", "<redacted>"),
            ("expiresAt", expiresAt), ("pageCount", pageCount), ("direction", direction as Any),
            ("startPage", startPage),
        ]
        if let handoff { children.append(("handoff", handoff)) }
        return Mirror(self, children: children, displayStyle: .struct)
    }

    /// 説明に出す基点。資格情報（`user:pw@`）は読み込みで断るが、値が別の経路で作られても文字列に残さない。
    private var redactedBookURL: URL {
        // 相対 URL は基点を解決してから見る（基点に資格情報があっても漏らさない）。
        let absolute = bookURL.absoluteURL
        guard var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false),
              components.user != nil || components.password != nil
        else { return absolute }
        components.user = nil
        components.password = nil
        return components.url ?? absolute
    }
}
