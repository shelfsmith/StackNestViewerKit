import Foundation

/// 読み進めたページを StackNest へ書き戻す役（1 冊に 1 つ）。ページの合図は UI から来るので MainActor に置く
/// （呼び出しの順がそのまま送る順になる）。
///
/// - まとめる: `note(page:)` のたびに 3 秒の待ちをやり直す。ただし最初に止まってから 10 秒を超えては待たない。
/// - 飛ぶのは 1 件、待つのは最新の 1 件: 送信中に止まったページは「次に送るページ」を置き換えるだけで、送信が
///   成功したら続けて送る（古い位置が新しい位置の後に届いて巻き戻すことが無い）。
/// - すぐには送り直さない: 失敗したページは次の `note`・`flush`・`close` まで送らない。
/// - 恒久的な失敗（`isPermanent`）の後は、その本については送らない。
/// - 知らせは種類（`noticeKind`）ごとに 1 度。送れたら記憶を消す。
/// - 開いたページ（`startPage`）と、送った（送っている）ページは送らない。
/// - 書き戻すのは StackNest のページ番号で、ビューアー自身の一覧の位置ではない。
/// - `close()` の後の `note(page:)` は無視する。
///
/// Writes the reading position back to StackNest (one per open book). Main-actor isolated, so the order of
/// calls is the order of sends. Batches for 3 seconds (at most 10), keeps one send in flight and only the
/// newest waiting page, doesn't retry on its own, stops after a permanent failure and reports each kind of
/// failure once. **Pages are StackNest page numbers, not positions in the viewer's own list.**
@MainActor
public final class StackNestProgressReporter {
    /// まとめの時間。 / Batching times.
    public struct Timing: Sendable {
        /// 止まってから送るまで。 / Delay after the last page change.
        public var debounce: Duration = .seconds(3)
        /// 最初に止まってから、これを超えては待たない。 / The longest wait from the first pending change.
        public var maxWait: Duration = .seconds(10)
        /// 既定のまとめ（3 秒・最長 10 秒）。 / The defaults (3 seconds, at most 10).
        public init() {}
    }

    /// 1 ページ分の送り先（StackNest のページ番号を受け取る）。 / The sender for one page (takes a StackNest page number).
    public typealias Send = @Sendable (Int) async throws -> Void

    private let timing: Timing
    private let send: Send
    private let onFailure: @MainActor (StackNestViewerError) -> Void
    private var pendingPage: Int?
    private var lastSentPage: Int?
    private var debounceTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    /// 飛んでいる送信のページと、その終わりをメインスレッドを使わずに知らせる印（`inFlight` と一緒に立て、一緒に外す）。
    private var inFlightSend: (page: Int, outcome: SendOutcome)?
    private var lastNotice: StackNestViewerError.NoticeKind?
    private var firstPendingAt: ContinuousClock.Instant?
    private var closeDeferred = false
    private var retriedAfterClose = false
    /// 飛んでいる送信の最中に `flush()` を受けた（その送信が失敗しても、止まっていたページのまとめ待ちを張り直さない。
    /// `flush` の約束は「送信中なら、それが成功した後に送る」）。送信が終わるたびに下ろす。
    private var flushedDuringSend = false
    private var isClosed = false
    /// 送り残しを終了時の送り切り（`StackNestProgressRegistry.flushAllBlocking(timeout:)`）へ渡した後。以後は送らない。
    private var isHandedOff = false
    /// 恒久的な失敗の後（送らない）。 / True after a permanent failure (nothing more is sent).
    public private(set) var isStopped = false

    /// セッションへ書き戻す役を作り、`StackNestProgressRegistry.shared` に弱い参照で載せる（終了時の送り切りのため）。
    /// 役は（閉じた後も）手放されるまでセッションを強く持つので、本を閉じたら役も手放すこと。
    ///
    /// Creates a reporter that posts to `session` and registers it (weakly) with
    /// `StackNestProgressRegistry.shared` for the quit-time flush. It keeps the session alive for as long as the reporter itself
    /// is alive, even after `close()`; release the reporter when the book closes.
    public convenience init(session: StackNestBookSession, startPage: Int?, timing: Timing = .init(),
                            onFailure: @escaping @MainActor (StackNestViewerError) -> Void)
    {
        self.init(startPage: startPage, timing: timing, send: { page in try await session.postProgress(page: page) },
                  onFailure: onFailure)
    }

    /// 送り先を差し替える形（試験・独自の通信を持つホスト）。これも `StackNestProgressRegistry.shared` に載る。
    ///
    /// Takes a custom sender (tests, or hosts with their own transport). Also registers with the shared registry.
    public convenience init(startPage: Int?, timing: Timing = .init(), send: @escaping Send,
                            onFailure: @escaping @MainActor (StackNestViewerError) -> Void)
    {
        self.init(startPage: startPage, timing: timing, registry: .shared, send: send, onFailure: onFailure)
    }

    /// セッションへ書き戻す役を作り、`registry` に弱い参照で載せる（`StackNestProgressRegistry.shared` には載せない）。
    /// ホストの試験が、プロセスで 1 つの登録簿（と、それを送り切るアプリの終了の処理）に役を残さないためのもの。
    ///
    /// Creates a reporter that posts to `session` and registers it (weakly) with `registry` instead of
    /// `StackNestProgressRegistry.shared`, so a host's tests don't leave reporters in the process-wide registry
    /// (which the app's quit-time flush would wait for).
    public convenience init(session: StackNestBookSession, startPage: Int?, timing: Timing = .init(),
                            registry: StackNestProgressRegistry,
                            onFailure: @escaping @MainActor (StackNestViewerError) -> Void)
    {
        self.init(startPage: startPage, timing: timing, registry: registry,
                  send: { page in try await session.postProgress(page: page) }, onFailure: onFailure)
    }

    /// 送り先と登録簿を選べる形。役は `registry` に弱い参照で載り、`StackNestProgressRegistry.shared` には載らない。
    ///
    /// Takes a custom sender and registers the reporter (weakly) with `registry` instead of the shared registry.
    public init(startPage: Int?, timing: Timing = .init(), registry: StackNestProgressRegistry, send: @escaping Send,
                onFailure: @escaping @MainActor (StackNestViewerError) -> Void)
    {
        lastSentPage = startPage
        self.timing = timing
        self.send = send
        self.onFailure = onFailure
        registry.register(self)
    }

    /// 今いるページ（StackNest のページ番号）。まとめ待ちをやり直す。負の値は無視する。
    /// `close()` の後は無視する（閉じる間に先頭へ戻るビューアーが、保存した位置を上書きしないため）。
    ///
    /// The current page (a StackNest page number). Restarts the batching wait. Negative values are ignored.
    /// Ignored after `close()` (so a viewer resetting to page 0 while closing cannot overwrite the saved position).
    public func note(page: Int) {
        guard !isStopped, !isClosed, page >= 0 else { return }
        if page == lastSentPage, pendingPage == nil { return }
        pendingPage = page
        // 送信の最中に受けた `flush()` の約束(成功した後にだけ送る)は、そのとき止まっていたページの話。後から止まったページは、
        // 自分のまとめ待ちの約束を持つ(送信が失敗しても張り直す)。
        flushedDuringSend = false
        scheduleDebounce()
    }

    /// まとめ待ちを（やり直して）張る。待つ長さは、止まっているページが最初に止まった時刻から数えて `maxWait` を越えない。
    private func scheduleDebounce() {
        let now = ContinuousClock.now
        let start = firstPendingAt ?? now
        firstPendingAt = start
        let delay = min(timing.debounce, max(timing.maxWait - (now - start), .zero))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sendPending()
        }
    }

    /// まとめ待ちをやめて今すぐ送る（送信中なら、それが成功した後に送る）。
    ///
    /// Sends now instead of waiting (after the in-flight send succeeds, if there is one).
    public func flush() {
        guard !isStopped else { return }
        if inFlight != nil { flushedDuringSend = true }
        debounceTask?.cancel()
        debounceTask = nil
        sendPending()
    }

    /// 閉じるとき: 今すぐ送る。飛んでいる送信があれば、それが終わってから止まっていたページを送り、閉じる前から
    /// 飛んでいた送信が失敗したら、止まっていた新しいページを 1 度だけ試す（閉じた後は次の合図が来ないため）。
    /// 役は送り切るまで自分を保つ。閉じた後の `note(page:)` は無視する。
    ///
    /// On close: sends now. If a send was in flight, the waiting page goes after it; if that earlier send fails,
    /// the newer page is tried once. The reporter keeps itself alive until done. `note(page:)` is ignored afterwards.
    public func close() {
        guard !isStopped else { return }
        isClosed = true
        if inFlight != nil, pendingPage != nil { closeDeferred = true }
        flush()
    }

    /// 送っていない・送っている最中の位置があるか。 / Whether a position is waiting or being sent.
    /// 終了時の送り切り（`flushAllBlocking(timeout:)`）へ渡した後は、送り切れたかに関わらず false（以後この役は送らない）。
    ///
    /// After the work has been handed to the quit-time `flushAllBlocking(timeout:)`, this is false whether or not
    /// those sends completed (the reporter sends nothing more).
    public var hasUnsentWork: Bool {
        !isStopped && !isHandedOff && (pendingPage != nil || debounceTask != nil || inFlight != nil)
    }

    /// まとめ待ちと送信（続けて送る分も）が終わるまで待つ（試験・終了時）。
    ///
    /// Waits until the batching wait and all sends finish (for tests and quitting).
    public func waitUntilIdle() async {
        while true {
            if let debounceTask {
                await debounceTask.value
                if self.debounceTask == debounceTask { self.debounceTask = nil }
                continue
            }
            if let inFlight {
                await inFlight.value
                continue
            }
            return
        }
    }

    private func sendPending() {
        // まとめ待ちを残さない（取り消さずに外すと、手の届かないタスクが後で早く発火して、失敗で戻したページを送り直す）。
        debounceTask?.cancel()
        debounceTask = nil
        guard !isStopped, !isHandedOff, inFlight == nil, let page = pendingPage else { return }
        pendingPage = nil
        firstPendingAt = nil
        guard page != lastSentPage else { return }
        lastSentPage = page
        let send = send
        let outcome = SendOutcome()
        inFlightSend = (page, outcome)
        // 送信そのものはメインアクターの外ですぐ始める。メインアクターのタスクに始めさせると、同じ周で
        // `flushAllBlocking(timeout:)` がメインスレッドを止めたとき（`close()` の直後に呼ぶなど）、送信が始まらないまま
        // 上限まで待つことになる。後始末（失敗の扱い・続けて送るページ）は、これまでどおりメインアクターで行う。
        let sending = Task.detached(priority: Task.currentPriority) {
            try await Self.send(page, with: send, reportingTo: outcome)
        }
        // self を強く持つ: 閉じた後（ホストが手放した後）も、飛んでいる送信と続けて送るページを送り切る。
        inFlight = Task { [self] in
            var succeeded = false
            do {
                try await sending.value
                succeeded = true
                lastNotice = nil
            } catch {
                handle(error, page: page)
            }
            inFlight = nil
            inFlightSend = nil
            let flushedDuringThisSend = flushedDuringSend
            flushedDuringSend = false
            if succeeded {
                sendPending()
            } else if closeDeferred, !retriedAfterClose, let newer = pendingPage, newer != page {
                retriedAfterClose = true
                sendPending()
            } else if !isStopped, !isClosed, !flushedDuringThisSend, debounceTask == nil, let newer = pendingPage,
                      newer != page
            {
                // 送信の最中に新しいページが止まり、そのまとめ待ちが送信の終わりより先に発火して空振りしていた
                // （`sendPending` は飛んでいる送信があると何もしない）。張り直さないと、新しいページは次の合図まで
                // 送られない（時間切れの失敗はまとめ待ちより長いので、この順がふつう）。最初に止まった時刻から
                // 数えるので、`maxWait` を過ぎていればすぐ送る。失敗したページそのものしか残っていないときは張らない
                // （すぐには送り直さない ―― `handle` のコメント）。送信の最中に `flush()` を受けたときも張らない
                // （`flush` は成功した後にだけ送る約束。次の `note`・`flush`・`close` で送る）。
                scheduleDebounce()
            }
        }
    }

    /// 送り先を呼び、終わったことを `outcome` へ知らせる。メインスレッドが止まっていても（終了時の送り切りが
    /// メインスレッドで待っていても）知らせが届く。
    nonisolated private static func send(_ page: Int, with send: Send, reportingTo outcome: SendOutcome) async throws {
        do {
            try await send(page)
            outcome.finish(.succeeded)
        } catch {
            outcome.finish((error as? StackNestViewerError)?.isPermanent == true ? .stopped : .failed)
            throw error
        }
    }

    /// 終了時の送り切りのために、送り残しを取り出して役を閉じる（`note(page:)` は無視され、以後この役は送らない）。
    /// 送るものも待つ送信も無ければ nil。
    ///
    /// - 止まっているページ（まとめ待ちのものを含む）を送る。ただし StackNest が知っているページ（開いたページ・
    ///   送れたページ）なら送らない。
    /// - 送信が飛んでいれば、それを送り直さずに終わりを待ち、止まっているページはその後に送る（古い位置が新しい位置の
    ///   後に届いて巻き戻すことが無い）。止まっているのが飛んでいるページそのものなら送らない（成功すれば送り直しになり、
    ///   失敗した送信をここで送り直さないのは `close()` と同じ）。飛んでいた送信が恒久的な失敗なら、後のページも送らない。
    func takeWorkForBlockingFlush() -> BlockingFlushJob? {
        guard hasUnsentWork else { return nil }
        debounceTask?.cancel()
        debounceTask = nil
        isClosed = true
        isHandedOff = true
        let waiting = pendingPage
        pendingPage = nil
        firstPendingAt = nil
        let flying = inFlight == nil ? nil : inFlightSend
        let page: Int?
        if let flying {
            page = waiting == flying.page ? nil : waiting
        } else {
            page = waiting == lastSentPage ? nil : waiting
        }
        guard flying != nil || page != nil else { return nil }
        return BlockingFlushJob(awaiting: flying?.outcome, page: page, send: send)
    }

    private func handle(_ error: any Error, page: Int) {
        // 送れなかったページは次の機会に送る。その後で別のページが止まっていれば、そちらが新しいので戻さない。
        if lastSentPage == page {
            lastSentPage = nil
            if pendingPage == nil { pendingPage = page }
        }
        // 止まっているのが失敗したページそのもの（より新しいページが無い）なら、まとめ待ちを残さない。
        // 残すと、失敗の後に次の合図が無くても同じページを送り直してしまう。
        if pendingPage == page {
            debounceTask?.cancel()
            debounceTask = nil
        }
        guard let failure = error as? StackNestViewerError else { return }
        if failure.isPermanent { isStopped = true }
        guard failure.noticeKind != lastNotice else { return }
        lastNotice = failure.noticeKind
        onFailure(failure)
    }
}

/// 1 件の送信の終わり。ロックで守り、待つ人の再開はロックの外で行う。
final class SendOutcome: @unchecked Sendable {
    enum Result: Sendable {
        case succeeded
        case failed
        /// 恒久的な失敗（その本へはもう送らない）。
        case stopped
    }

    private let lock = NSLock()
    private var result: Result?
    private var waiters: [CheckedContinuation<Result, Never>] = []

    func finish(_ result: Result) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Result, Never>] in
            guard self.result == nil else { return [] }
            self.result = result
            let waiting = waiters
            waiters = []
            return waiting
        }
        for waiter in waiting { waiter.resume(returning: result) }
    }

    func value() async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let known = lock.withLock { () -> Result? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let known { continuation.resume(returning: known) }
        }
    }
}

/// 終了時の送り切りで 1 つの役が残した仕事: 飛んでいる送信の終わりを待ち、それから止まっていたページを送る。
/// メインスレッドを使わずに走る（`StackNestProgressRegistry.flushAllBlocking(timeout:)`）。
struct BlockingFlushJob: Sendable {
    let awaiting: SendOutcome?
    let page: Int?
    let send: StackNestProgressReporter.Send

    /// 失敗は知らせない（終了の途中で、知らせる先の UI がもう無い）。
    func run() async {
        if let awaiting, await awaiting.value() == .stopped { return }
        guard let page else { return }
        try? await send(page)
    }
}
