import Foundation
import StackNestViewerKit

/// StackNest の本の API の見立て（`URLProtocol`）。試験 1 つにつき 1 つ作る。実際には接続しない。
///
/// Swift Testing は試験を並行に走らせるので、応答と記録は見立てごとに持つ: 本の URL の `libraries/<UUID>` に
/// 自分の ID を入れ、届いた要求をその ID で振り分ける。宛先は 127.0.0.1（部品の既定の制限のままで試せる）。
/// 記録は鍵そのものを持たず、「期待の鍵と一致したか」だけを持つ（試験の失敗の表示に鍵が出ないように）。
///
/// A `URLProtocol` stand-in for StackNest's book API — one per test. Requests are routed by the
/// `libraries/<UUID>` part of the book URL, so parallel tests don't mix. Records never hold the token itself,
/// only whether it matched.
///
/// 見立てを指すセッション（`configuration()` の設定で作ったもの）は、見立てを強く持つ。セッションが生きている間は
/// 見立てもあるので、見立てを作って得たセッションだけを返す補助関数でも通信は成功する。
///
/// A session built from `configuration()` keeps the stub alive, so a helper that builds a stub and returns only
/// the session still works.
public final class StackNestStubServer: @unchecked Sendable {
    /// 要求の行き先。 / Where a request went.
    public enum Route: Hashable, Sendable {
        /// manifest。 / The manifest.
        case manifest
        /// 番号のページ。 / The page with this number.
        case page(Int)
        /// 表紙。 / The cover.
        case cover
        /// 読書位置の書き戻し。 / The progress write-back.
        case progress
        /// 基点の後ろのほかの道（基点の外なら `<outside>`）。 / Any other path under the base.
        case other(String)
    }

    /// 見立ての応答。 / A stubbed response.
    public enum Response: Sendable {
        /// 状態コード・ヘッダ・本文。 / A status code, headers and body.
        case status(Int, headers: [String: String] = [:], body: Data = Data())
        /// 通信の失敗。 / A transport failure.
        case failure(URLError.Code)
        /// 302 で `to` へ（付いて行くかはセッションが決める）。 / A 302 to `to`.
        case redirect(to: URL)
    }

    /// 届いた要求の記録（鍵は持たない）。 / A recorded request (never the token).
    public struct RecordedRequest: Sendable, Hashable {
        /// HTTP のメソッド。 / The HTTP method.
        public let method: String
        /// 行き先。 / Where the request went.
        public let route: Route
        /// 要求の URL。 / The request URL.
        public let url: URL
        /// `?maxw=` の値。 / The `?maxw=` value.
        public let maxWidth: Int?
        /// `Authorization` が付いていたか。 / Whether `Authorization` was present.
        public let hasAuthorization: Bool
        /// `Authorization` が `Bearer <期待の鍵>` と一致したか。 / Whether it matched the expected token.
        public let carriesExpectedToken: Bool
        /// `X-StackNest-Viewer` の値。 / The identification header.
        public let viewerHeader: String?
        /// 書き戻しの本文の `page`。 / The `page` of a progress body.
        public let progressPage: Int?
    }

    let id = UUID().uuidString
    private let lock = NSLock()
    private var pageCount: Int
    private var direction: String
    private var pageNames: [String]?
    private var expectedToken = "fixture-token"
    private var responses: [Route: Response] = [:]
    private var gates: [Route: StubGate] = [:]
    private var log: [RecordedRequest] = []
    private var stopped = 0

    /// 見立てを作る。作った時点で登録され、解放されると外れる。
    ///
    /// Creates a stub; it is registered on creation and unregistered when released.
    ///
    /// - Parameters:
    ///   - pageCount: manifest が答えるページ数。 / The page count the manifest reports.
    ///   - direction: manifest が答える読む向き。 / The direction the manifest reports.
    public init(pageCount: Int = 3, direction: String = "rtl") {
        self.pageCount = pageCount
        self.direction = direction
        Self.register(self)
    }

    deinit { Self.unregister(id) }

    /// 本の API の基点。 / The base of the book's API.
    public var bookURL: URL {
        URL(string: "http://127.0.0.1:51234/api/v1/libraries/\(id)/books/1")!
    }

    /// この見立てを指す参照ファイルの中身（`token` が期待の鍵になる。読む向きは見立ての `direction`：
    /// `"rtl"`・`"ltr"` のほかはそのまま知らない値として渡る）。
    ///
    /// A reference pointing at this stub (`token` becomes the expected token; the reading direction follows the
    /// stub's `direction`, and values other than `"rtl"`/`"ltr"` pass through as unknown).
    public func reference(token: String = "fixture-token", expiresAt: Date = .distantFuture,
                          startPage: Int = 0) throws -> StackNestBookReference
    {
        let (count, directionName) = lock.withLock { () -> (Int, String) in
            expectedToken = token
            return (pageCount, direction)
        }
        return try StackNestBookReference(
            version: 1, title: "Fixture", bookURL: bookURL, token: token, expiresAt: expiresAt,
            pageCount: count, direction: StackNestReadingDirection(rawValue: directionName), startPage: startPage)
    }

    /// 見立てを差し込んだセッションの設定。この設定で作ったセッションは見立てを強く持つ（セッションが生きている
    /// 間は見立ても生きる）。
    ///
    /// A session configuration routed to this stub. A session built from it keeps the stub alive for as long as
    /// the session lives.
    public func configuration() -> StackNestBookSession.Configuration {
        var configuration = StackNestBookSession.Configuration()
        configuration.makeURLSessionConfiguration = { [self] in
            // Capturing `self` keeps the stub (registered weakly) alive with the session's configuration.
            let session = withExtendedLifetime(self) { URLSessionConfiguration.ephemeral }
            session.protocolClasses = [StackNestStubProtocol.self]
            return session
        }
        return configuration
    }

    /// `route` への応答を差し替える。 / Replaces the response for `route`.
    public func respond(_ route: Route, with response: Response) {
        lock.withLock { responses[route] = response }
    }

    /// manifest が答えるページ数を変える。 / Changes the page count the manifest reports.
    public func setPageCount(_ count: Int) { lock.withLock { pageCount = count } }

    /// manifest が `?pageNames=1` の要求に答えるページの名前（`pageNames`）を変える。nil なら付けない（既定）。
    /// 問い合わせの無い manifest の要求には、StackNest と同じく付けない。数はページ数と合わせなくてよい（食い違いの試験）。
    ///
    /// Changes the `pageNames` the manifest reports for `?pageNames=1` requests; nil (the default) leaves them out.
    /// Like StackNest, requests without the query never get them. The count needn't match the page count (to test
    /// mismatches).
    public func setPageNames(_ names: [String]?) { lock.withLock { pageNames = names } }

    /// 以後の `route` への応答を、返した門が開くまで止める。開け忘れても 60 秒で自動で流れる。同じ道に
    /// 続けて呼ぶと門は置き換わり、古い門で止まった応答は、その門が開くか 60 秒たつまで止まったままになる。
    ///
    /// Holds responses for `route` until the returned gate opens. A gate never opened still releases its held
    /// responses automatically after 60 seconds. Calling it again for the same route replaces the gate; responses
    /// held by the old gate stay held until that gate opens or 60 seconds pass.
    public func gate(_ route: Route) -> StubGate {
        let gate = StubGate()
        lock.withLock { gates[route] = gate }
        return gate
    }

    /// 届いた要求（届いた順）。 / Requests received, in order.
    public var requests: [RecordedRequest] { lock.withLock { log } }

    /// 応答を流す前に読み込みを止められた（取り消された）要求の数。応答を流し終えた後の止め（`URLSession` が
    /// 片付けで呼ぶもの）は数えない。 / How many requests were stopped before their response was delivered (cancelled).
    public var stoppedRequestCount: Int { lock.withLock { stopped } }

    /// 行き先ごとの要求の数。 / The number of requests to `route`.
    public func requestCount(_ route: Route) -> Int { requests.filter { $0.route == route }.count }

    // MARK: - URLProtocol から

    func handle(_ request: URLRequest, body: Data) -> (Response, StubGate?) {
        let url = request.url!
        // 宛先のホストは見ない（宛先の制限を広げた試験でも、同じ見立てへ届く）。基点のパスの後ろを道とする。
        let basePath = bookURL.path + "/"
        let suffix = url.path.hasPrefix(basePath) ? String(url.path.dropFirst(basePath.count)) : nil
        let maxWidth = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "maxw" }?.value.flatMap(Int.init)
        let route = Self.route(for: suffix)
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        return lock.withLock {
            log.append(RecordedRequest(
                method: request.httpMethod ?? "GET", route: route, url: url, maxWidth: maxWidth,
                hasAuthorization: authorization != nil,
                carriesExpectedToken: authorization == "Bearer \(expectedToken)",
                viewerHeader: request.value(forHTTPHeaderField: StackNestViewerIdentification.headerName),
                progressPage: route == .progress ? Self.progressPage(body) : nil))
            let wantsNames = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "pageNames" && $0.value == "1" } ?? false
            return (responses[route] ?? defaultResponse(route, includesPageNames: wantsNames), gates[route])
        }
    }

    func noteStopped() { lock.withLock { stopped += 1 } }

    private func defaultResponse(_ route: Route, includesPageNames: Bool) -> Response {
        switch route {
        case .manifest:
            var body: [String: Any] = ["pageCount": pageCount, "direction": direction, "format": "archive",
                                       "etag": "stub"]
            if includesPageNames, let pageNames { body["pageNames"] = pageNames }
            return .status(200, headers: ["Content-Type": "application/json"],
                           body: try! JSONSerialization.data(withJSONObject: body))
        case .page(let index) where index < pageCount:
            return .status(200, headers: ["Content-Type": "image/png"], body: StackNestFixtures.pngPage(marker: index))
        case .cover:
            return .status(200, headers: ["Content-Type": "image/png"], body: StackNestFixtures.pngPage(marker: 255))
        case .progress:
            return .status(200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        default:
            return .status(404)
        }
    }

    private static func route(for suffix: String?) -> Route {
        guard let suffix else { return .other("<outside>") }
        switch suffix {
        case "manifest": return .manifest
        case "cover": return .cover
        case "progress": return .progress
        default:
            if suffix.hasPrefix("pages/"), let index = Int(suffix.dropFirst("pages/".count)) { return .page(index) }
            return .other(suffix)
        }
    }

    private static func progressPage(_ body: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["page"] as? Int
    }

    // MARK: - 登録簿（ID → 見立て）

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: WeakServer] = [:]

    private struct WeakServer { weak var server: StackNestStubServer? }

    private static func register(_ server: StackNestStubServer) {
        registryLock.withLock { registry[server.id] = WeakServer(server: server) }
    }

    private static func unregister(_ id: String) {
        registryLock.withLock { registry[id] = nil }
    }

    static func server(for url: URL?) -> StackNestStubServer? {
        guard let components = url?.pathComponents, let index = components.firstIndex(of: "libraries"),
              index + 1 < components.count
        else { return nil }
        let id = components[index + 1]
        return registryLock.withLock { registry[id]?.server }
    }
}

/// 応答を止めておく門。止めた要求が届いたことも知らせる。`open()` を呼び忘れても、止めた応答は 60 秒で自動で
/// 流れる（試験のスレッドが残り続けないように）。
///
/// A gate that holds responses and reports arrivals. If `open()` is never called, held responses are released
/// automatically after 60 seconds so test threads don't linger.
public final class StubGate: @unchecked Sendable {
    private let released = DispatchGroup()
    private let arrivals = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isOpen = false

    init() { released.enter() }

    /// 止めた要求が 1 つ届くまで待つ（呼んだスレッドをブロックする）。 / Blocks until one held request arrives.
    public func waitForArrival(timeout: TimeInterval = 5) -> Bool {
        arrivals.wait(timeout: .now() + timeout) == .success
    }

    /// 止めた要求が 1 つ届くまで待つ（async。待つのは別のスレッド）。 / Waits for one arrival without blocking the caller.
    public func arrival(timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: self.waitForArrival(timeout: timeout)) }.start()
        }
    }

    /// 止めている応答をすべて流す。何度呼んでもよい。 / Releases all held responses; safe to call repeatedly.
    public func open() {
        lock.withLock {
            guard !isOpen else { return }
            isOpen = true
            released.leave()
        }
    }

    /// 開くまで止める。開け忘れた試験のスレッドが残り続けないよう、60 秒で諦めて流す。
    func hold() {
        arrivals.signal()
        _ = released.wait(timeout: .now() + 60)
    }
}

/// 見立てへ要求を渡す `URLProtocol`。
final class StackNestStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopLock = NSLock()
    private var isStopped = false
    private var isDelivered = false

    override func startLoading() {
        let request = self.request
        guard let server = StackNestStubServer.server(for: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (response, gate) = server.handle(request, body: Self.body(of: request))
        // 応答は要求ごとの専用のスレッドから流す（止める応答で URL の読み込みのスレッドを塞がない。GCD の
        // グローバルなキューは、協調スレッドがふさがった試験で一緒に止まりうるので使わない）。
        let thread = Thread { [self] in
            gate?.hold()
            // 取り消された後は流さない（閉じた後の client に触れない）。流すと決めたら、その印を先に付ける。
            let shouldDeliver = stopLock.withLock { () -> Bool in
                guard !isStopped else { return false }
                isDelivered = true
                return true
            }
            guard shouldDeliver else { return }
            deliver(response, for: request)
        }
        thread.start()
    }

    override func stopLoading() {
        // 応答を流した後の止めは片付けなので数えない。流す前の止めだけが取り消し。
        let cancelled = stopLock.withLock { () -> Bool in
            isStopped = true
            return !isDelivered
        }
        if cancelled { StackNestStubServer.server(for: request.url)?.noteStopped() }
    }

    private func deliver(_ response: StackNestStubServer.Response, for request: URLRequest) {
        let url = request.url!
        switch response {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let target):
            let redirect = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            // 付いて行くかはセッションの delegate が決める。断られたら、この 302 がそのまま応答になる。
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let code, let headers, let body):
            let http = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// POST の本文（`URLSession` は `httpBody` をストリームに移して渡してくる）。
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
