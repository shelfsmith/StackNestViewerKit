import Foundation

/// 1 冊を読む間のセッション。manifest・ページ・表紙・書き戻しの要求は、すべてここの 1 本の道（`perform`）を通る:
/// つなぐ宛先の制限・期限の確認・ヘッダの付与・同じ要求の 1 件へのまとめ・リダイレクトの拒否・本文の上限。
///
/// `@unchecked Sendable` の根拠: 変わる状態（取得中の表・札・キャッシュ・既知のページ数・閉じたか）はすべて
/// `lock` の中でだけ読み書きし、ロックを持ったまま呼び出し側の閉包・継続・delegate を呼ばない。`URLSession` は
/// このセッションが持ち、`deinit` で `invalidateAndCancel()` する。delegate は別の小さな物でセッションを参照しない。
///
/// A session for reading one book. Every request — manifest, pages, cover and progress — goes through one
/// path that enforces the host policy, checks expiry, adds the headers, merges identical requests, refuses
/// redirects and caps response bodies. It is `@unchecked Sendable` because all mutable state is touched only
/// under one lock, and no caller closure, continuation or delegate is called while holding it.
///
/// 恒久的な失敗（`StackNestViewerError.isPermanent`。認証の失敗・ライブラリのロック・本が無いなど）を一度受けたら、
/// 以後のページ・manifest・表紙（同期の顔も）は要求を出さずに同じ失敗で戻り、先読みの指示は無視する。書き戻しは
/// これまでどおり要求を出す。
///
/// After a permanent failure (`StackNestViewerError.isPermanent`, such as unauthorized, library locked or book
/// not found), later page, manifest and cover calls (blocking ones too) fail with that same error without a
/// request, and prefetch instructions are ignored. Progress write-backs still make their request.
public final class StackNestBookSession: @unchecked Sendable {
    /// セッションの設定。 / Session settings.
    public struct Configuration: Sendable {
        /// 1 回の要求の無通信の時間切れ（`URLRequest.timeoutInterval`）。 / Per-request idle timeout.
        public var requestTimeout: Duration = .seconds(20)
        /// 待つ側の上限。async の顔も同期の顔も、1 件の要求ごとに、呼んでからこの時間で必ず戻る（`.cannotConnect`）。
        /// 少しずつ流れ続ける応答や、要求が出るまでの待ちも含めて数える。呼び出し全体の上限ではない（ページの読み出しは
        /// 最大 3 件の要求を出すことがある）。
        ///
        /// The waiting side's limit: each request, whether through the async or the blocking face, returns within
        /// this time of being issued (with `.cannotConnect`), counting slow trickling responses and any queueing.
        /// It bounds each request, not the whole call (a page read can make up to three requests).
        public var waitLimit: Duration = .seconds(25)
        /// 1 応答の本文の上限（超えたら `.responseTooLarge`）。2xx でない応答は状態コードで振り分け、本文は受け取らない。
        /// 2xx の応答で `Content-Length` の申告があれば、その大きさ（この上限まで）を受け取る前に確保する。
        /// 受け取れても、`pageCacheBytes` の半分を超えるページは持っておかない。
        ///
        /// The body size limit of one response (`.responseTooLarge` beyond it). Non-2xx responses are classified by
        /// their status code and their bodies are never read. When a 2xx response announces `Content-Length`, that
        /// much (up to this limit) is allocated before the body arrives. A page that fits this limit but is larger
        /// than half of `pageCacheBytes` is still not kept.
        public var maxResponseBytes = 64 << 20
        /// 持っておくページの枚数。 / How many pages to keep in memory.
        public var pageCacheCount = 8
        /// 持っておくページの合計の大きさ。1 枚がこの半分を超えるページは持たず、読むたびに取り直す（1 枚でほかの
        /// ページを全部追い出さないため）。既定の組み合わせ（これと `maxResponseBytes` がどちらも 64 MiB）では、
        /// 32 MiB を超え 64 MiB までのページは受け取れるが持っておかれない。そういうページのある本を読むなら上げる。
        ///
        /// The memory budget for kept pages. A page larger than half of it isn't kept and is fetched again on every
        /// read (so one page can't push out all the others). With the defaults (this and `maxResponseBytes` both
        /// 64 MiB), pages over 32 MiB and up to 64 MiB are accepted but never kept; raise this for books with such pages.
        public var pageCacheBytes = 64 << 20
        /// 先読みの同時の数。 / How many prefetches run at once.
        public var maxConcurrentPrefetches = 2
        /// 同時に出す要求の上限（1 未満は 1）。超えた分はセッションの中の列で待ち、枠が空くと書き戻し → 表示の要求が
        /// 乗っている件 → 先読みだけの件の順に出す（同じ組の中は件を作った順。先読みの件に表示の要求が乗れば、その場で前へ
        /// 出る）。待つ人が誰もいなくなった件は、要求を出さずに列から外す。`URLSession` の宛先ごとの接続の数
        /// （`httpMaximumConnectionsPerHost`。`makeURLSessionConfiguration` が何を返しても）もこの値にするので、
        /// 出した要求が `URLSession` の中で待たされることはない。列で待つ間も `waitLimit` は進む。
        /// `maxConcurrentPrefetches` より大きく保つ（差の分が表示の要求に残る）。走っている先読みは追い越せないので、
        /// 同じか小さいと、表示の要求が先読みの終わりを待つことがある。
        ///
        /// The most requests in flight at once (values below 1 count as 1). The rest wait in the session's own
        /// queue and start, as slots free up, in this order: progress write-backs, then fetches a display request
        /// is waiting for, then prefetch-only fetches (within each group, in the order the fetches were created; a prefetch that a
        /// display request joins moves ahead at once). A queued fetch whose waiters all leave is dropped without a
        /// request. `httpMaximumConnectionsPerHost` is set to the same value (whatever `makeURLSessionConfiguration`
        /// returns), so no request waits inside `URLSession`. `waitLimit` keeps running while a request is queued.
        /// Keep it larger than `maxConcurrentPrefetches`: the difference is what stays free for display requests.
        /// A running prefetch can't be overtaken, so with an equal or smaller value a display request may wait for
        /// prefetches to finish.
        public var maxConcurrentRequests = 6
        /// つないでよいホスト（既定は loopback だけ）。 / Hosts the session may connect to (loopback only by default).
        public var allowedHosts: StackNestHostPolicy = .loopbackOnly
        /// `book` のパスの形を問わないか。既定（false）では、StackNest が書く形（`/api/v1/libraries/<library>/books/<id>`
        /// と `/api/v1/relay/<relayID>`。区切りは英数字と `-._~` だけ・末尾のスラッシュは 1 つまで）のときだけ要求を出し、
        /// ほかは要求なしで `.invalidReference`（書き換えた参照ファイルで、鍵の付いた要求を 127.0.0.1 の別のサービスへ
        /// 送らせないため）。ほかの形の基点へホストが承知でつなぐときだけ true にする（`allowedHosts` の制限は残る）。
        ///
        /// Whether any `book` path is accepted. By default (false) the session makes requests only when the path has
        /// one of the shapes StackNest writes (`/api/v1/libraries/<library>/books/<id>` and `/api/v1/relay/<relayID>`,
        /// with segments of letters, digits and `-._~` only and at most one trailing slash) and fails with
        /// `.invalidReference` without a request otherwise, so a tampered reference file can't send token-carrying
        /// requests to another service on 127.0.0.1. Set it to true only when the app knowingly connects to a base
        /// of another shape (`allowedHosts` still applies).
        public var allowsAnyBookPath = false
        /// 名乗り（nil なら `Bundle.main` から。`format=` は常に参照ファイルの版）。
        ///
        /// The identification (nil means `Bundle.main`; `format=` is always the reference file's version).
        public var identification: StackNestViewerIdentification? = nil
        /// `URLSession` の設定を作る口（試験の見立てを差し込む）。キャッシュ・クッキー・資格情報の保管は、ここで
        /// 何を返しても外す。宛先ごとの接続の数（`httpMaximumConnectionsPerHost`）も、何を返しても
        /// `maxConcurrentRequests` に合わせる。
        ///
        /// Makes the `URLSessionConfiguration` (tests inject stubs here). Caches, cookies and credential
        /// storage are always removed from whatever it returns, and `httpMaximumConnectionsPerHost` is always set
        /// to `maxConcurrentRequests`.
        public var makeURLSessionConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
        /// 期限の確認に使う時計。 / The clock used for expiry checks.
        public var now: @Sendable () -> Date = { Date() }

        public init() {}
    }

    /// 開いている参照ファイルの中身。 / The reference this session reads.
    public let reference: StackNestBookReference
    let configuration: Configuration
    let viewerHeader: String
    let urlSession: URLSession
    let delegate: SessionDelegate
    /// 待つ人の時間切れの時計を回す直列のキュー（協調スレッドにも GCD のグローバルなキューにも頼らない）。
    let timerQueue = DispatchQueue(label: "StackNestBookSession.timeouts")
    /// 変わる状態を守るロック。
    let lock = NSLock()
    /// `lock` の中でだけ読み書きする。
    var state: EngineState

    /// 参照ファイルの中身から作る。つなぐ宛先の制限は要求のたびに見る。
    ///
    /// Creates a session for a reference. The host policy is checked on every request.
    public init(reference: StackNestBookReference, configuration: Configuration = .init()) {
        self.reference = reference
        self.configuration = configuration
        let base = configuration.identification ?? .forMainBundle(format: reference.version)
        viewerHeader = StackNestViewerIdentification(
            bundleIdentifier: base.bundleIdentifier, version: base.version, format: reference.version,
            kitVersion: base.kitVersion
        ).headerValue
        let delegate = SessionDelegate()
        self.delegate = delegate
        urlSession = URLSession(
            configuration: Self.hardened(configuration.makeURLSessionConfiguration(), waitLimit: configuration.waitLimit,
                                         maxConcurrentRequests: configuration.maxConcurrentRequests),
            delegate: delegate, delegateQueue: nil)
        state = EngineState(
            cache: PageCache(capacity: configuration.pageCacheCount, byteBudget: configuration.pageCacheBytes),
            knownPageCount: reference.pageCount)
    }

    /// 参照ファイルを**呼び出したスレッドで同期に**読んで作る（数百バイト・上限 1 MiB）。応答しないボリュームの上に
    /// あるかもしれないなら、ブロックしてよいスレッドで作る。`allowedHosts` に入らない `book` は `.hostNotAllowed`、
    /// パスが StackNest の書く形でない `book` は（`allowsAnyBookPath` でなければ）`.invalidReference`。
    ///
    /// Reads the reference file **synchronously on the calling thread** (a few hundred bytes, at most 1 MiB).
    /// Create it on a thread that may block if the file could be on an unresponsive volume. Throws
    /// `.hostNotAllowed` when `book` isn't an allowed host, and `.invalidReference` when its path isn't one of the
    /// shapes StackNest writes (unless `allowsAnyBookPath` is set).
    public convenience init(contentsOf referenceFile: URL, configuration: Configuration = .init()) throws {
        let reference = try StackNestBookReference.load(contentsOf: referenceFile)
        guard configuration.allowedHosts.allows(reference.bookURL) else {
            throw StackNestViewerError(.hostNotAllowed)
        }
        guard configuration.allowsAnyBookPath || StackNestBookPath.isStackNestShape(reference.bookURL) else {
            throw StackNestViewerError(.invalidReference)
        }
        self.init(reference: reference, configuration: configuration)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    /// manifest。開いたら最初に呼ぶ（StackNest が「読み込まれた」と早く気づける）。`refresh` が false なら、
    /// 読んだことのある manifest を返す（まだ無ければ、飛んでいる manifest の要求に乗る）。`refresh` が true なら、
    /// 呼んだ後に出した要求の答えを返す（その前から飛んでいる要求には乗らない）。閉じた後は `CancellationError`。
    ///
    /// The manifest. Call it first after opening, so StackNest notices the open early. Without `refresh`,
    /// a manifest already read is returned (or a manifest request already in flight is joined). With `refresh`,
    /// the answer comes from a request made after the call, never from one already in flight. Throws
    /// `CancellationError` after `close()`.
    public func manifest(refresh: Bool = false) async throws -> StackNestBookManifest {
        if !refresh, let cached = cachedManifest { return cached }
        return try recordManifest(try await fetchManifest(fresh: refresh))
    }

    /// ページ（`index` は StackNest のページ番号・0 始まり）。`maxWidth` は `?maxw=`（0 以下は付けない）。
    /// 範囲外（負の番号を含む）は要求なしで `.pageOutOfRange`。既知のページ数以上の番号では、manifest を
    /// まだ読んでいなければ 1 度だけ読み直して確かめる。
    ///
    /// A page (`index` is the 0-based StackNest page number). `maxWidth` becomes `?maxw=` (ignored when 0 or
    /// less). Out-of-range numbers, including negative ones, fail with `.pageOutOfRange` without a request.
    ///
    /// 1 回の呼び出しで最大 3 件の要求（範囲の確かめ直し・ページ・404 の後の読み直し）を出すことがあり、`waitLimit` は
    /// 要求ごとに数えるので、最悪の場合は `waitLimit` の最大 3 倍まで待つ。閉じた後は（番号に関わらず）
    /// `CancellationError`。
    ///
    /// One call can make up to three requests (the range re-check, the page, and the re-read after a 404), and
    /// `waitLimit` is counted per request, so in the worst case it can take up to three times `waitLimit`.
    /// After `close()` it throws `CancellationError` whatever the index.
    public func page(_ index: Int, maxWidth: Int? = nil,
                     priority: StackNestRequestPriority = .display) async throws -> StackNestPage
    {
        if lock.withLock({ state.isClosed }) { throw CancellationError() }
        try await ensureInRange(index)
        do {
            let response = try await fetch(.page(index: index, maxWidth: Self.normalizedWidth(maxWidth)),
                                           priority: priority)
            return StackNestPage(data: response.data, contentType: response.contentType)
        } catch is PageNotFound {
            throw await classifyMissingPage(index)
        }
    }

    /// 表紙。 / The cover.
    public func cover(maxWidth: Int? = nil) async throws -> StackNestPage {
        let response = try await fetch(.cover(maxWidth: Self.normalizedWidth(maxWidth)), priority: .display)
        return StackNestPage(data: response.data, contentType: response.contentType)
    }

    /// 読書位置の書き戻し（`page` は StackNest のページ番号。ビューアの今の並びの位置ではない）。負の値は要求を
    /// 出さずに `.pageOutOfRange`。閉じた後も受け付ける。ふつうは `StackNestProgressReporter` から呼ばれる。
    ///
    /// Writes back the reading position (`page` is the StackNest page number, not a position in the viewer's
    /// own list). Negative values fail with `.pageOutOfRange` without a request. Works after `close()`.
    public func postProgress(page: Int) async throws {
        guard page >= 0 else {
            throw StackNestViewerError(.pageOutOfRange, pageCount: lock.withLock { state.knownPageCount })
        }
        let serial = lock.withLock { () -> UInt64 in
            state.nextSerial += 1
            return state.nextSerial
        }
        _ = try await fetch(.progress(serial: serial, page: page), priority: .display)
    }

    /// 先読みの指示。前の指示を置き換え、外れた取得中の先読みは（表示の要求が乗っていなければ）取り消す。
    /// 負の番号・重複・既知のページ数以上は捨て、キャッシュの枚数までに切り詰め、渡した順に出す（読む向きの近い順に
    /// 渡す）。閉じた後と、恒久的な失敗の後は何もしない。
    ///
    /// Prefetch instructions. Replaces the previous ones and cancels fetches no longer wanted (unless a
    /// display request joined them). Negative, duplicate and out-of-range numbers are dropped; the list is cut
    /// to the cache size and issued in the given order (nearest pages in reading direction first).
    public func prefetch(_ indices: [Int], maxWidth: Int? = nil) {
        let width = Self.normalizedWidth(maxWidth)
        let now = configuration.now()
        var effects = Effects()
        lock.withLock {
            guard !state.isClosed, state.permanentFailure == nil else { return }
            var seen = Set<Int>()
            let wanted = indices
                .filter { $0 >= 0 && $0 < state.knownPageCount && seen.insert($0).inserted }
                .prefix(max(configuration.pageCacheCount, 0))
                .map { RequestKey.page(index: $0, maxWidth: width) }
            let wantedSet = Set(wanted)
            for (key, ticket) in state.prefetchTickets where !wantedSet.contains(key) {
                _ = removeWaiterLocked(ticket, effects: &effects)
            }
            // もう持っている希望のページを、遠い順に新しい側へ回す（近いページほど新しくなる）。回さないと、希望の枚数と
            // 表示中のページでキャッシュの枚数を超えたとき、新しく届いた先読みが、次に読む（いちばん古い）希望のページを
            // 追い出し、そのページを開くと取り直しになった（ページを送るたびに同じことが続く）。回した後に追い出されるのは、
            // 希望の外（表示し終えたページ）→ 遠い希望の順。
            for key in wanted.reversed() { state.cache.touch(key) }
            state.prefetchQueue = wanted.filter {
                state.prefetchTickets[$0] == nil && state.flights[$0] == nil && !state.cache.contains($0)
            }
            advanceLocked(now: now, effects: &effects)
        }
        apply(effects)
    }

    /// 読むのをやめる: ページ・表紙・manifest・先読みを止め（待っている人は `CancellationError`）、キャッシュと覚えた
    /// manifest を捨てる。以後は書き戻しのほかはすべて `CancellationError`（覚えた manifest も返さない）。書き戻しだけは
    /// 閉じた後も受け付ける。`URLSession` はここでは畳まず、最後の参照が消えたときに `deinit` で畳む。
    ///
    /// Stops reading: pages, cover, manifest and prefetches stop (their waiters get `CancellationError`) and the
    /// cache and the remembered manifest are dropped. Afterwards everything but progress throws `CancellationError`.
    /// The `URLSession` is invalidated in `deinit`.
    public func close() {
        var effects = Effects()
        lock.withLock {
            guard !state.isClosed else { return }
            state.isClosed = true
            state.cache.removeAll()
            state.manifest = nil
            state.prefetchQueue.removeAll()
            state.prefetchTickets.removeAll()
            // 並んでいる書き戻しは残す（閉じた後も送る）。出している件の枠は、取り消した要求が終わったときに返る。
            state.queuedFlights.removeAll { !$0.key.isProgress }
            for (key, flight) in state.flights where !key.isProgress {
                state.flights[key] = nil
                flight.isAbandoned = true
                for (ticket, entry) in flight.waiters {
                    state.tickets[ticket] = nil
                    effects.resumes.append((entry.waiter, .failure(CancellationError())))
                }
                if let task = flight.task { effects.cancels.append(task) }
            }
        }
        apply(effects)
    }

    /// いまページのキャッシュに持っているバイト数の合計（`pageCacheBytes` を超えない。閉じた後は 0）。ホストの
    /// リソースの監視が、このセッションのメモリを数えるためのもの。返したページ（`StackNestPage.data`）は
    /// キャッシュと同じバッファを指していることがあるので、ホストが自分で持つページと足すと二重に数えることがある。
    ///
    /// The bytes currently held in the page cache (never more than `pageCacheBytes`; 0 after `close()`), for host
    /// resource monitors that account for this session's memory. A returned page (`StackNestPage.data`) may share
    /// its buffer with the cache, so adding it to pages the host keeps itself can count the same bytes twice.
    public var cachedPageBytes: Int { lock.withLock { state.cache.totalBytes } }

    /// いま受け取っている途中の応答の本文のバイト数の合計（届き終わった応答は含まない。ページはその後キャッシュと
    /// `cachedPageBytes` に移る）。
    ///
    /// The body bytes received so far by responses still arriving (finished responses aren't included; pages then
    /// move to the cache and `cachedPageBytes`).
    public var bufferedResponseBytes: Int { delegate.bufferedBytes }

    // MARK: - async の顔

    /// async の待つ人として加わる。取り消されたら待つ人から抜け、待つ人が誰もいなくなったときだけ要求を取り消す。
    /// 呼んでから `waitLimit` が過ぎたら、時計（`timerQueue`）が待つ人を抜けさせて `.cannotConnect` で再開する
    /// （要求の時間切れは無通信の時間しか数えないので、少しずつ流れる応答でも必ず戻るように）。
    func fetch(_ key: RequestKey, priority: StackNestRequestPriority) async throws -> FetchedResponse {
        let ticket = lock.withLock { allocateTicketLocked() }
        let timeout = DispatchWorkItem { [weak self] in
            self?.withdraw(ticket, because: StackNestViewerError(.cannotConnect))?
                .resume(with: .failure(StackNestViewerError(.cannotConnect)))
        }
        timerQueue.asyncAfter(deadline: .now() + configuration.waitLimit.timeInterval, execute: timeout)
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FetchedResponse, any Error>) in
                self.perform(key, priority: priority, ticket: ticket, waiter: .async(continuation))
            }
        } onCancel: {
            self.withdraw(ticket)?.resume(with: .failure(CancellationError()))
        }
    }

    /// manifest の要求（async）。`fresh` は呼んだ後に始めた件の答えだけを使う。
    func fetchManifest(fresh: Bool) async throws -> FetchedResponse {
        try await fetch(manifestKey(fresh: fresh), priority: .display)
    }

    /// 範囲の確認（async）。確かめるのは参照ファイルを書いた時点のページ数との差なので、飛んでいる manifest の
    /// 要求（どれもセッションを作った後に出している）に乗ってよい。
    private func ensureInRange(_ index: Int) async throws {
        let (known, confirmed) = lock.withLock { (state.knownPageCount, state.hasConfirmedPageCount) }
        guard index >= 0 else { throw StackNestViewerError(.pageOutOfRange, pageCount: known) }
        if index < known { return }
        if !confirmed { _ = try recordManifest(try await fetchManifest(fresh: false)) }
        let current = lock.withLock { state.knownPageCount }
        guard index < current else { throw StackNestViewerError(.pageOutOfRange, pageCount: current) }
    }

    /// `pages/{n}` の 404 を、manifest を 1 度読み直して振り分ける（async）。読み直しは 404 を受けた後に出した要求
    /// （`refresh: true`）で行う。前から飛んでいる要求の答えは、ページ数が減る前のものでありうる。
    private func classifyMissingPage(_ index: Int) async -> any Error {
        do {
            return Self.missingPageError(index: index, manifest: .success(try await manifest(refresh: true)))
        } catch {
            return Self.missingPageError(index: index, manifest: .failure(error))
        }
    }

    // MARK: - 顔に共通の部分

    /// 読んだ manifest を記録する。より前に出した件の応答は、呼んだ人には返すが状態には反映しない（出した順の
    /// 番号で判定）。ページ数が減っていたら、範囲の外になったページをキャッシュ・先読みの列から捨て、
    /// 先読みだけが待っている範囲の外の件は取り消す（以後、範囲の外へは要求を出さない）。
    func recordManifest(_ response: FetchedResponse) throws -> StackNestBookManifest {
        let manifest = try StackNestBookManifest.parse(response.data)
        let now = configuration.now()
        var effects = Effects()
        lock.withLock {
            // A response from a flight launched before the one already applied is returned to its caller
            // but never overwrites the newer state (launch numbers increase with every launched flight; the
            // creation serial would not do, since queued flights can launch out of creation order).
            guard response.launchNumber > state.manifestLaunchNumber else { return }
            state.manifestLaunchNumber = response.launchNumber
            if !state.isClosed { state.manifest = manifest }
            state.knownPageCount = manifest.pageCount
            state.hasConfirmedPageCount = true
            state.cache.removePages(atOrAbove: manifest.pageCount)
            let beyond: (RequestKey) -> Bool = { key in
                if case .page(let index, _) = key { return index >= manifest.pageCount }
                return false
            }
            state.prefetchQueue.removeAll(where: beyond)
            for (key, ticket) in state.prefetchTickets where beyond(key) {
                _ = removeWaiterLocked(ticket, effects: &effects)
            }
            advanceLocked(now: now, effects: &effects)
        }
        apply(effects)
        return manifest
    }

    /// 覚えた manifest（閉じた後は nil）。
    var cachedManifest: StackNestBookManifest? { lock.withLock { state.isClosed ? nil : state.manifest } }

    /// 404 の振り分け: manifest を読み直せず失敗したら、その失敗をそのまま返す（manifest も 404 なら
    /// `.bookNotFound`・StackNest が止まっていれば `.cannotConnect` など）。読み直せてページ数が減っていたら
    /// `.pageOutOfRange`、まだそのページがあるなら `.httpStatus(404)`。
    static func missingPageError(index: Int, manifest: Result<StackNestBookManifest, any Error>) -> any Error {
        switch manifest {
        case .success(let manifest) where index >= manifest.pageCount:
            return StackNestViewerError(.pageOutOfRange, pageCount: manifest.pageCount)
        case .success:
            return StackNestViewerError(.httpStatus, statusCode: 404)
        case .failure(let error):
            return error
        }
    }

    /// 同期の顔が取り消しの旗を見る間隔（試験 `cancellationPollIntervalIsPinned` で固定する）。
    static let cancellationPollInterval: Duration = .milliseconds(100)

    /// 要求の資源の時間切れの、`waitLimit` への上乗せ。待つ人の時計が先に効き、これは待つ人のいない先読みの件の
    /// 歯止めになる。
    static let resourceTimeoutMargin: Duration = .seconds(5)

    /// `?maxw=` の値（0 以下は付けない）。
    static func normalizedWidth(_ width: Int?) -> Int? {
        guard let width, width > 0 else { return nil }
        return width
    }

    /// キャッシュ・クッキー・資格情報の保管を持たない設定にする（鍵の付いた要求の結果をディスクへ残さない）。
    /// 1 回の要求の全体の時間（`timeoutIntervalForResource`）を `waitLimit`＋上乗せで絞る。宛先ごとの接続の数は
    /// セッションの同時の数の上限に合わせる（それより多くは出さないので、`URLSession` の中の列を使わない）。
    static func hardened(_ host: URLSessionConfiguration, waitLimit: Duration,
                         maxConcurrentRequests: Int) -> URLSessionConfiguration
    {
        // Work on a copy: the host's object (possibly shared) stays untouched.
        let configuration = (host.copy() as? URLSessionConfiguration) ?? host
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // つながらないときは待たずに失敗させる（「StackNest から開き直してください」を早く出す）。
        configuration.waitsForConnectivity = false
        // Never use a proxy: an empty dictionary disables system and PAC proxies, so the token goes only to the book origin.
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = (waitLimit + resourceTimeoutMargin).timeInterval
        configuration.httpMaximumConnectionsPerHost = max(maxConcurrentRequests, 1)
        return configuration
    }
}
