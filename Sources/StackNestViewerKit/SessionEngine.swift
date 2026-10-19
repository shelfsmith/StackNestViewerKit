import Foundation

/// セッションのエンジン（1 本の道）。ロックの中では帳簿だけを付け、待つ人の再開・取り消し・要求の組み立てはロックの外で
/// 行う（出す要求の `resume()` だけは、表へ載せるのと同じロックの中で行う。`launch` を参照）。
extension StackNestBookSession {
    // MARK: - 札

    func allocateTicketLocked() -> UInt64 {
        state.nextTicket += 1
        state.tickets[state.nextTicket] = .allocated
        return state.nextTicket
    }

    /// manifest の鍵。`fresh` なら世代を進める（呼んだ後に始めた件の答えだけを使う）。そうでなければ、いまの世代
    /// （飛んでいる件があれば乗る）。
    func manifestKey(fresh: Bool) -> RequestKey {
        lock.withLock {
            if fresh { state.manifestGeneration += 1 }
            return .manifest(generation: state.manifestGeneration)
        }
    }

    // MARK: - 1 本の道

    /// すべての要求が通る入口。札が加わる前に抜けていれば（取り消し・時間切れ）、要求を出さずにそのエラーで再開する。
    func perform(_ key: RequestKey, priority: StackNestRequestPriority, ticket: UInt64, waiter: Waiter) {
        let now = configuration.now()
        var effects = Effects()
        lock.withLock {
            if case .withdrawnEarly(let error)? = state.tickets[ticket] {
                state.tickets[ticket] = nil
                effects.resumes.append((waiter, .failure(error)))
                return
            }
            admitLocked(key, priority: priority, ticket: ticket, waiter: waiter, now: now, effects: &effects)
            // 表示の要求が先読みの件に乗ると、その件は先読みの枠を使わなくなる（次の先読みを始められる）。
            advanceLocked(now: now, effects: &effects)
        }
        apply(effects)
    }

    /// 帳簿付け（ロックの中）: 事前の検査 → キャッシュ → 取得中の件に乗る／新しい件を作る。
    func admitLocked(_ key: RequestKey, priority: StackNestRequestPriority, ticket: UInt64, waiter: Waiter,
                     now: Date, effects: inout Effects)
    {
        if let failure = preflightFailureLocked(for: key, now: now) {
            state.tickets[ticket] = nil
            effects.resumes.append((waiter, .failure(failure)))
            return
        }
        if let cached = state.cache.value(for: key) {
            state.tickets[ticket] = nil
            effects.resumes.append((waiter, .success(cached)))
            return
        }
        let flight: Flight
        if let existing = state.flights[key] {
            flight = existing
        } else {
            state.nextSerial += 1
            flight = Flight(key: key, serial: state.nextSerial)
            state.flights[key] = flight
            // すぐには出さず列に並べる（出すのは `startQueuedFlightsLocked`。枠が空いていれば同じ周で出る）。
            state.queuedFlights.append(flight)
        }
        flight.waiters[ticket] = WaiterEntry(waiter: waiter, priority: priority)
        state.tickets[ticket] = .registered(key)
        if waiter.isPrefetchInstruction { state.prefetchTickets[key] = ticket }
        // 表示の要求が乗ったら優先度を上げる（プロパティの書き込みだけで、こちらへは呼び戻さない）。
        flight.task?.priority = flight.desiredPriority
    }

    /// 要求を出す前の検査。閉じた後のページ・manifest・表紙は取り消し、つないでよいホストでなければ
    /// `.hostNotAllowed`、パスが StackNest の書く形でなければ `.invalidReference`（`allowsAnyBookPath` で外せる）、
    /// 期限を過ぎていれば `.expired`（読む途中にも切れるので毎回見る）。恒久的な失敗を
    /// 受けた後のページ・manifest・表紙は、要求を出さずにその失敗を返す（StackNest から開き直すまで同じ答えに
    /// なるので、問い直しても StackNest とビューアの手間が増えるだけ）。書き戻しは止めない: 書き戻しの役は自分の
    /// 送信の失敗で止まり（`StackNestProgressReporter`）、ホストが直に送る分はホストに任せる（閉じた後も受け付ける
    /// のと同じ扱い）。
    func preflightFailureLocked(for key: RequestKey, now: Date) -> (any Error)? {
        if state.isClosed, !key.isProgress { return CancellationError() }
        guard configuration.allowedHosts.allows(reference.bookURL) else {
            return StackNestViewerError(.hostNotAllowed)
        }
        guard configuration.allowsAnyBookPath || StackNestBookPath.isStackNestShape(reference.bookURL) else {
            return StackNestViewerError(.invalidReference)
        }
        guard !reference.isExpired(at: now) else { return StackNestViewerError(.expired) }
        if !key.isProgress, let failure = state.permanentFailure { return failure }
        return nil
    }

    // MARK: - 先読み

    /// 部品の先読みの枠を使っている件の数。
    func activePrefetchCountLocked() -> Int {
        state.flights.values.filter(\.countsAsPrefetch).count
    }

    /// 帳簿が変わった後に必ず呼ぶ: 先読みの枠が空いていれば先読みの件を作り、同時の数の枠が空いていれば
    /// 並んでいる件を出す。
    func advanceLocked(now: Date, effects: inout Effects) {
        startQueuedPrefetchesLocked(now: now, effects: &effects)
        startQueuedFlightsLocked(effects: &effects)
    }

    /// 枠が空いていれば、指示の順に先読みを始める。
    func startQueuedPrefetchesLocked(now: Date, effects: inout Effects) {
        let limit = max(configuration.maxConcurrentPrefetches, 0)
        while activePrefetchCountLocked() < limit, !state.prefetchQueue.isEmpty {
            guard !state.isClosed, state.permanentFailure == nil else {
                state.prefetchQueue.removeAll()
                return
            }
            let key = state.prefetchQueue.removeFirst()
            if state.flights[key] != nil || state.cache.contains(key) { continue }
            let ticket = allocateTicketLocked()
            admitLocked(key, priority: .prefetch, ticket: ticket, waiter: .prefetch, now: now, effects: &effects)
        }
    }

    // MARK: - 同時の数

    /// 同時に出す要求の上限（1 未満は 1）。
    var requestLimit: Int { max(configuration.maxConcurrentRequests, 1) }

    /// 同時の数の枠が空いている分だけ、並んでいる件を出す。出す順は `admissionRank`（書き戻し → 表示 → 先読み）、
    /// 同じ組の中は作った順。`URLSession` の宛先ごとの接続の数（`httpMaximumConnectionsPerHost`）も同じ値にして
    /// あるので、出した要求が `URLSession` の中で待たされることはない（そこで待つと、優先度は目安にしかならず、
    /// 表示の要求が先読みの後ろで時間切れになりうる。待つ人の時計も資源の時間切れも、その間に進む）。
    func startQueuedFlightsLocked(effects: inout Effects) {
        state.queuedFlights.removeAll(where: \.isAbandoned)
        while state.runningSerials.count < requestLimit, !state.queuedFlights.isEmpty {
            var best = 0
            for index in state.queuedFlights.indices.dropFirst()
            where state.queuedFlights[index].admissionRank < state.queuedFlights[best].admissionRank {
                best = index
            }
            let flight = state.queuedFlights.remove(at: best)
            state.runningSerials.insert(flight.serial)
            effects.launches.append(flight)
        }
    }

    // MARK: - 抜ける

    /// 待つ人を抜ける（取り消し・時間切れ）。再開の権利を取れたら、その待つ人を返す（呼び出し側が `error` で再開する）。
    /// まだ加わっていない札には「加わる前に抜けた」印と `error` を残す（加わる側が見て、要求を出さずにそれで再開する）。
    func withdraw(_ ticket: UInt64, because error: any Error = CancellationError()) -> Waiter? {
        let now = configuration.now()
        var effects = Effects()
        let waiter: Waiter? = lock.withLock {
            switch state.tickets[ticket] {
            case nil, .withdrawnEarly?:
                return nil
            case .allocated?:
                state.tickets[ticket] = .withdrawnEarly(error)
                return nil
            case .registered?:
                let removed = removeWaiterLocked(ticket, effects: &effects)
                advanceLocked(now: now, effects: &effects)
                return removed
            }
        }
        apply(effects)
        return waiter
    }

    /// 札の待つ人を件から外す。待つ人がいなくなった件は取り消す（先読みの取り中に表示が乗っていれば、
    /// 先読みが抜けても件は続く）。
    func removeWaiterLocked(_ ticket: UInt64, effects: inout Effects) -> Waiter? {
        guard case .registered(let key)? = state.tickets[ticket] else { return nil }
        state.tickets[ticket] = nil
        if state.prefetchTickets[key] == ticket { state.prefetchTickets[key] = nil }
        guard let flight = state.flights[key], let entry = flight.waiters.removeValue(forKey: ticket) else {
            return nil
        }
        if flight.waiters.isEmpty {
            flight.isAbandoned = true
            state.flights[key] = nil
            // まだ出していない件は、要求を出さずに列から外す。
            state.queuedFlights.removeAll { $0 === flight }
            if let task = flight.task { effects.cancels.append(task) }
        } else {
            flight.task?.priority = flight.desiredPriority
        }
        return entry.waiter
    }

    // MARK: - 要求を出す・受ける

    /// 新しい件の要求を組み立てて出す（同時の数の枠を取った件だけが来る）。出す前に待つ人がいなくなっていたら出さず、
    /// 枠を返す（その要求は delegate へ届かないので、完了で返る道が無い）。枠を取ってから出すまでの間に恒久的な失敗が
    /// 記録されていたら、書き戻しのほかは出さずにその失敗で戻して枠を返す（列から外れた後なので
    /// `failQueuedFlightsLocked` には見えない）。
    func launch(_ flight: Flight) {
        if failIfPermanentlyFailed(flight) {
            releaseSlot(of: flight.serial)
            return
        }
        guard let request = makeRequest(for: flight.key) else {
            finish(flight.key, serial: flight.serial, with: .failure(StackNestViewerError(.invalidReference)))
            return
        }
        let task = urlSession.dataTask(with: request)
        let key = flight.key
        let serial = flight.serial
        delegate.register(
            ResponseSink(limit: configuration.maxResponseBytes) { [weak self] outcome in
                self?.finish(key, serial: serial, with: Self.classify(outcome, for: key))
            }, for: task)
        var effects = Effects()
        let (started, hook): (Bool, LaunchHook?) = lock.withLock {
            guard !flight.isAbandoned else { return (false, nil) }
            // 上の確かめの後に記録された失敗もここで見る（ここで始めなければ要求は出ない）。
            if !flight.key.isProgress, let failure = state.permanentFailure {
                failFlightLocked(flight, with: failure, effects: &effects)
                return (false, nil)
            }
            flight.task = task
            task.priority = flight.desiredPriority
            // 表へ載せたのと同じロックの中で始める。載せた後は `removeWaiterLocked`・`close()` が取り消しうるので、
            // ロックの外で始めると、始める前の取り消しが割り込める。始める前に取り消した要求の完了を `URLSession` が
            // 知らせるかは文書に無く、枠は完了でだけ返るので、知らされなければ枠が永久に減る。`resume()` は要求を
            // `URLSession` 自身の列へ渡すだけで delegate を同期に呼ばない（優先度の書き込みと同じ扱い）ので、
            // 「ロックを持ったまま呼び戻さない」の約束は保てる。
            task.resume()
            state.lastLaunchNumber += 1
            flight.launchNumber = state.lastLaunchNumber
            return (true, state.launchHookForTesting)
        }
        if started {
            hook?(flight.key, task)
        } else {
            delegate.unregister(task)
            task.cancel()
            apply(effects)
            releaseSlot(of: flight.serial)
        }
    }

    /// 恒久的な失敗の後なら（書き戻しのほか）件をその失敗で戻して true。枠は呼び出し側が返す。
    func failIfPermanentlyFailed(_ flight: Flight) -> Bool {
        var effects = Effects()
        let failed: Bool = lock.withLock {
            guard !flight.key.isProgress, !flight.isAbandoned, let failure = state.permanentFailure else { return false }
            failFlightLocked(flight, with: failure, effects: &effects)
            return true
        }
        apply(effects)
        return failed
    }

    /// 出さなかった件の枠を返し、次の件を出す。
    func releaseSlot(of serial: UInt64) {
        let now = configuration.now()
        var effects = Effects()
        lock.withLock {
            state.runningSerials.remove(serial)
            advanceLocked(now: now, effects: &effects)
        }
        apply(effects)
    }

    /// 件の結果を待つ人すべてに渡す。ページはキャッシュへ、恒久的な失敗は記録して先読みと以後のページ・manifest・
    /// 表紙の要求を止める（`preflightFailureLocked`）。出した要求が終わったので枠を返す（取り消した件の完了も
    /// ここへ来る。その件はもう表に無いので、枠を返すだけ）。
    func finish(_ key: RequestKey, serial: UInt64, with result: Result<FetchedResponse, any Error>) {
        let now = configuration.now()
        var effects = Effects()
        lock.withLock {
            state.runningSerials.remove(serial)
            defer { advanceLocked(now: now, effects: &effects) }
            guard let flight = state.flights[key], flight.serial == serial else { return }
            state.flights[key] = nil
            // Tag the response with its flight's launch number so a late recorder can tell old from new.
            var result = result
            if case .success(var response) = result {
                response.launchNumber = flight.launchNumber
                result = .success(response)
            }
            for (ticket, entry) in flight.waiters {
                state.tickets[ticket] = nil
                if state.prefetchTickets[key] == ticket { state.prefetchTickets[key] = nil }
                effects.resumes.append((entry.waiter, result))
            }
            switch result {
            case .success(let response):
                if case .page = key, !state.isClosed { state.cache.store(response, for: key) }
            case .failure(let error):
                if let failure = error as? StackNestViewerError, failure.isPermanent {
                    state.permanentFailure = failure
                    state.prefetchQueue.removeAll()
                    failQueuedFlightsLocked(with: failure, effects: &effects)
                }
            }
        }
        apply(effects)
    }

    /// 恒久的な失敗を受けたとき: 列で待っている件は、書き戻しのほかは要求を出さずにその失敗で戻して列から外す。
    /// 入口（`preflightFailureLocked`）は失敗の後に来た件しか止めないので、失敗より前に並んだ件もここで止める
    /// （「恒久的な失敗の後は要求を出さない」の約束）。先読みの指示は結果を受け取らないので、外すだけになる。
    func failQueuedFlightsLocked(with failure: any Error, effects: inout Effects) {
        for queued in state.queuedFlights where !queued.key.isProgress {
            failFlightLocked(queued, with: failure, effects: &effects)
        }
        state.queuedFlights.removeAll { !$0.key.isProgress }
    }

    /// 出していない件を出さずに `failure` で戻す（待つ人すべてを再開し、表から外す）。
    func failFlightLocked(_ flight: Flight, with failure: any Error, effects: inout Effects) {
        flight.isAbandoned = true
        if state.flights[flight.key] === flight { state.flights[flight.key] = nil }
        for (ticket, entry) in flight.waiters {
            state.tickets[ticket] = nil
            if state.prefetchTickets[flight.key] == ticket { state.prefetchTickets[flight.key] = nil }
            effects.resumes.append((entry.waiter, .failure(failure)))
        }
        flight.waiters.removeAll()
    }

    /// ロックの外で行う: 取り消し → 再開 → 新しい件の開始。
    func apply(_ effects: Effects) {
        for task in effects.cancels { task.cancel() }
        for (waiter, result) in effects.resumes { waiter.resume(with: result) }
        for flight in effects.launches { launch(flight) }
    }

    /// 要求の組み立て（ここ 1 か所）。URL は `book` の後ろへ文字列で足す（IPv6 の区域 ID `%25en0` を組み直さない）。
    func makeRequest(for key: RequestKey) -> URLRequest? {
        let suffix: String
        switch key {
        case .manifest: suffix = configuration.requestsPageNames ? "manifest?pageNames=1" : "manifest"
        case .page(let index, let width): suffix = "pages/\(index)" + Self.widthQuery(width)
        case .cover(let width): suffix = "cover" + Self.widthQuery(width)
        case .progress: suffix = "progress"
        }
        var base = reference.bookURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + suffix) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.requestTimeout.timeInterval
        request.setValue("Bearer \(reference.token)", forHTTPHeaderField: "Authorization")
        request.setValue(viewerHeader, forHTTPHeaderField: StackNestViewerIdentification.headerName)
        if case .progress(_, let page) = key {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"page\":\(page)}".utf8)
        }
        return request
    }

    static func widthQuery(_ width: Int?) -> String {
        width.map { "?maxw=\($0)" } ?? ""
    }

    /// 応答の振り分け。401 → `.unauthorized`／403＋`X-Library-Locked: 1` → `.libraryLocked`／ほかの 403 →
    /// `.unauthorized`／ページの 404 → 顔で振り分け／表紙の 404 → `.httpStatus`（本はあるが表紙が無いことがある。恒久にしない）／ほかの 404 → `.bookNotFound`／502 → `.remoteUnavailable`／
    /// ほかの 3xx・4xx・5xx → `.httpStatus`。
    static func classify(_ outcome: ResponseSink.Outcome, for key: RequestKey) -> Result<FetchedResponse, any Error> {
        // 上限を超えて自分で打ち切ったときは、その取り消しの失敗ではなく「応答が大きすぎる」。
        if outcome.exceededLimit { return .failure(StackNestViewerError(.responseTooLarge)) }
        if let error = outcome.error { return .failure(transportError(error)) }
        guard let status = outcome.statusCode else { return .failure(StackNestViewerError(.invalidResponse)) }
        switch status {
        case 200..<300:
            return .success(FetchedResponse(data: outcome.data, contentType: outcome.contentType))
        case 401:
            return .failure(StackNestViewerError(.unauthorized))
        case 403:
            return .failure(StackNestViewerError(outcome.libraryLocked ? .libraryLocked : .unauthorized))
        case 404:
            if case .page = key { return .failure(PageNotFound()) }
            // A missing cover image also answers 404 while the book exists, so it is not a permanent failure.
            if case .cover = key { return .failure(StackNestViewerError(.httpStatus, statusCode: 404)) }
            return .failure(StackNestViewerError(.bookNotFound))
        case 502:
            return .failure(StackNestViewerError(.remoteUnavailable))
        default:
            return .failure(StackNestViewerError(.httpStatus, statusCode: status))
        }
    }

    /// 通信の失敗の振り分け。取り消し → `CancellationError`、ATS → `.insecureConnectionBlocked`、ほか → `.cannotConnect`。
    static func transportError(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return StackNestViewerError(.cannotConnect) }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .appTransportSecurityRequiresSecureConnection: return StackNestViewerError(.insecureConnectionBlocked)
        default: return StackNestViewerError(.cannotConnect)
        }
    }

    // MARK: - 試験のための読み取り

    var knownPageCountForTesting: Int { lock.withLock { state.knownPageCount } }
    var inFlightKeysForTesting: Set<RequestKey> { lock.withLock { Set(state.flights.keys) } }
    func waiterCountForTesting(_ key: RequestKey) -> Int { lock.withLock { state.flights[key]?.waiters.count ?? 0 } }
    func taskPriorityForTesting(_ key: RequestKey) -> Float? { lock.withLock { state.flights[key]?.task?.priority } }
    var cachedKeysForTesting: [RequestKey] { lock.withLock { state.cache.keys } }
    var ticketCountForTesting: Int { lock.withLock { state.tickets.count } }
    var queuedKeysForTesting: [RequestKey] { lock.withLock { state.queuedFlights.map(\.key) } }
    var runningCountForTesting: Int { lock.withLock { state.runningSerials.count } }
    var hasPermanentFailureForTesting: Bool { lock.withLock { state.permanentFailure != nil } }
    /// 要求を出した直後（ロックの外）に呼ぶ閉包を置く。出した直後に取り消す試験のため。
    func setLaunchHookForTesting(_ hook: LaunchHook?) { lock.withLock { state.launchHookForTesting = hook } }
    var urlSessionConfigurationForTesting: URLSessionConfiguration { urlSession.configuration }
    var delegateForTesting: AnyObject { delegate }
}
