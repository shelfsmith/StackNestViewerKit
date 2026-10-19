import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// セッションの 1 本の道: 鍵と名乗り・失敗の振り分け・リダイレクトの拒否・本文の上限・宛先の制限・期限・寿命。
@Suite("セッション: 要求の道")
struct StackNestSessionRequestTests {
    @Test("manifest: 基点の後ろの manifest を、鍵と名乗り（kit= 付き）を付けて GET する")
    func manifestCarriesTokenAndViewerHeader() async throws {
        let stub = StackNestStubServer(pageCount: 9)
        let session = try makeSession(stub)
        let manifest = try await session.manifest()
        #expect(manifest == StackNestBookManifest(pageCount: 9, direction: .rightToLeft, format: "archive", etag: "stub"))
        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        #expect(request.route == .manifest)
        #expect(request.carriesExpectedToken)
        #expect(request.viewerHeader == expectedViewerHeader)
        #expect(request.viewerHeader?.hasSuffix("; format=1; kit=\(StackNestViewerKitInfo.version)") == true)
    }

    @Test("manifest の bookIdentity がセッションの manifest に出る（付かなければ nil）")
    func manifestCarriesBookIdentity() async throws {
        let stub = StackNestStubServer(pageCount: 2)
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        #expect(try await session.manifest().bookIdentity == nil)
        stub.setBookIdentity("sn1:fixture")
        #expect(try await session.manifest(refresh: true).bookIdentity == "sn1:fixture")
    }

    @Test("manifest は読んだものを使い回し、refresh: true で読み直す")
    func manifestIsReusedUntilRefreshed() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        _ = try await session.manifest()
        _ = try await session.manifest()
        #expect(stub.requestCount(.manifest) == 1)
        stub.setPageCount(5)
        #expect(try await session.manifest(refresh: true).pageCount == 5)
        #expect(stub.requestCount(.manifest) == 2)
    }

    @Test("progress: {\"page\": n} を JSON で POST し、鍵と名乗りを付ける")
    func progressPostsJSON() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        try await session.postProgress(page: 4)
        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.route == .progress)
        #expect(request.progressPage == 4)
        #expect(request.carriesExpectedToken)
        #expect(request.viewerHeader == expectedViewerHeader)
    }

    @Test("負のページの書き戻しは要求を出さずに .pageOutOfRange")
    func negativeProgressMakesNoRequest() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 3)) { try await session.postProgress(page: -1) }
        #expect(stub.requests.isEmpty)
    }

    static let failureCases: [(StackNestStubServer.Response, StackNestViewerError)] = [
        (.status(401), StackNestViewerError(.unauthorized)),
        (.status(403, headers: ["X-Library-Locked": "1"]), StackNestViewerError(.libraryLocked)),
        (.status(403), StackNestViewerError(.unauthorized)),
        (.status(404), StackNestViewerError(.bookNotFound)),
        (.status(500), StackNestViewerError(.httpStatus, statusCode: 500)),
        (.status(502), StackNestViewerError(.remoteUnavailable)),
        (.failure(.cannotConnectToHost), StackNestViewerError(.cannotConnect)),
        (.failure(.timedOut), StackNestViewerError(.cannotConnect)),
        (.failure(.appTransportSecurityRequiresSecureConnection), StackNestViewerError(.insecureConnectionBlocked)),
    ]

    @Test("応答と通信の失敗を、エラーのコードに振り分ける", arguments: failureCases)
    func failureMapping(response: StackNestStubServer.Response, expected: StackNestViewerError) async throws {
        let stub = StackNestStubServer()
        stub.respond(.manifest, with: response)
        let session = try makeSession(stub)
        await #expect(throws: expected) { try await session.manifest() }
    }

    static let routeFailureCases: [(StackNestStubServer.Route, Int, StackNestViewerError)] = [
        (.progress, 404, StackNestViewerError(.bookNotFound)),
        (.progress, 401, StackNestViewerError(.unauthorized)),
        (.cover, 404, StackNestViewerError(.httpStatus, statusCode: 404)),
        (.cover, 401, StackNestViewerError(.unauthorized)),
    ]

    @Test("要求の種類ごとの振り分け（進捗の 404 は本が無い。表紙の 404 は本が無いとは限らない）", arguments: routeFailureCases)
    func routeFailureMapping(route: StackNestStubServer.Route, status: Int, expected: StackNestViewerError) async throws {
        let stub = StackNestStubServer()
        stub.respond(route, with: .status(status))
        let session = try makeSession(stub)
        await #expect(throws: expected) {
            if route == .progress { try await session.postProgress(page: 1) } else { _ = try await session.cover() }
        }
    }

    static let permanentFailureCases: [(StackNestStubServer.Route, StackNestStubServer.Response, StackNestViewerError)] = [
        (.page(0), .status(401), StackNestViewerError(.unauthorized)),
        (.manifest, .status(403, headers: ["X-Library-Locked": "1"]), StackNestViewerError(.libraryLocked)),
        (.manifest, .status(404), StackNestViewerError(.bookNotFound)),
        (.cover, .status(403), StackNestViewerError(.unauthorized)),
        (.progress, .status(401), StackNestViewerError(.unauthorized)),
    ]

    @Test("恒久的な失敗の後のページ・manifest・表紙は、同期の顔も含めて要求を出さずに同じ失敗で戻る。書き戻しは要求を出す",
          arguments: permanentFailureCases)
    func permanentFailureIsAnsweredWithoutRequests(route: StackNestStubServer.Route,
                                                   response: StackNestStubServer.Response,
                                                   expected: StackNestViewerError) async throws
    {
        let stub = StackNestStubServer(pageCount: 3)
        stub.respond(route, with: response)
        let session = try makeSession(stub)
        await #expect(throws: expected) {
            switch route {
            case .page(let index): _ = try await session.page(index)
            case .cover: _ = try await session.cover()
            case .progress: try await session.postProgress(page: 1)
            default: _ = try await session.manifest()
            }
        }
        #expect(stub.requests.map(\.route) == [route])
        await #expect(throws: expected) { try await session.page(1) }
        await #expect(throws: expected) { try await session.page(7) }
        await #expect(throws: expected) { try await session.cover(maxWidth: 200) }
        await #expect(throws: expected) { try await session.manifest() }
        await #expect(throws: expected) { try await session.manifest(refresh: true) }
        let reader = StackNestBlockingReader(session: session)
        let blocking = await onThread { (Result { try reader.page(2) }, Result { try reader.manifest(refresh: true) }) }
        #expect(throws: expected) { try blocking.0.get() }
        #expect(throws: expected) { try blocking.1.get() }
        #expect(stub.requests.map(\.route) == [route], "どれも要求を出さない")
        // 書き戻しは記録した失敗で止めない（書き戻しの役は自分の送信の失敗で止まる）。
        stub.respond(.progress, with: .status(200))
        try await session.postProgress(page: 2)
        #expect(stub.requests.map(\.route) == [route, .progress])
    }

    @Test("一時的な失敗（500・つながらない）の後は、次の呼び出しで要求を出し直す")
    func transientFailureIsRetriedOnTheNextCall() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        stub.respond(.page(0), with: .status(500))
        stub.respond(.manifest, with: .failure(.cannotConnectToHost))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 500)) { try await session.page(0) }
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await session.manifest() }
        stub.respond(.page(0), with: .status(200, body: Data([7])))
        #expect(try await session.page(0).data == Data([7]))
        #expect(stub.requests.map(\.route) == [.page(0), .manifest, .page(0)])
    }

    @Test("manifest の JSON が読めなければ .invalidResponse")
    func brokenManifest() async throws {
        let stub = StackNestStubServer()
        stub.respond(.manifest, with: .status(200, body: Data("not json".utf8)))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.invalidResponse)) { try await session.manifest() }
    }

    @Test("リダイレクトには付いて行かない（鍵を別の宛先へ渡さない）。3xx は .httpStatus")
    func redirectIsRefused() async throws {
        let stub = StackNestStubServer()
        let elsewhere = URL(string: "http://127.0.0.1:2/api/v1/libraries/\(stub.bookURL.pathComponents[4])/elsewhere")!
        stub.respond(.manifest, with: .redirect(to: elsewhere))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 302)) { try await session.manifest() }
        #expect(stub.requests.count == 1)
        #expect(stub.requests.allSatisfy { $0.url.port == 51234 })
    }

    @Test("同じ宛先へのリダイレクトにも付いて行かない")
    func sameOriginRedirectIsRefused() async throws {
        let stub = StackNestStubServer()
        stub.respond(.manifest, with: .redirect(to: stub.bookURL.appendingPathComponent("pages/0")))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 302)) { try await session.manifest() }
        #expect(stub.requests.count == 1)
    }

    @Test("本文の上限: Content-Length の申告が超えたら受け取らずに .responseTooLarge")
    func contentLengthOverCap() async throws {
        let stub = StackNestStubServer()
        stub.respond(.progress, with: .status(200, headers: ["Content-Length": "5000"], body: Data(count: 10)))
        let session = try makeSession(stub) { $0.maxResponseBytes = 1000 }
        await #expect(throws: StackNestViewerError(.responseTooLarge)) { try await session.postProgress(page: 1) }
    }

    @Test("本文の上限: 申告が無く、受け取った量が超えたら .responseTooLarge。上限ちょうどは通る")
    func streamedBodyOverCap() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub) { $0.maxResponseBytes = 1000 }
        stub.respond(.progress, with: .status(200, body: Data(count: 1001)))
        await #expect(throws: StackNestViewerError(.responseTooLarge)) { try await session.postProgress(page: 1) }
        stub.respond(.progress, with: .status(200, body: Data(count: 1000)))
        try await session.postProgress(page: 2)
        #expect(StackNestBookSession.Configuration().maxResponseBytes == 64 * 1024 * 1024)
    }

    static let largeErrorBodyCases: [(StackNestStubServer.Route, Int, [String: String], StackNestViewerError)] = [
        (.manifest, 401, [:], StackNestViewerError(.unauthorized)),
        (.manifest, 403, ["X-Library-Locked": "1"], StackNestViewerError(.libraryLocked)),
        (.manifest, 404, [:], StackNestViewerError(.bookNotFound)),
        (.progress, 404, [:], StackNestViewerError(.bookNotFound)),
        (.cover, 404, [:], StackNestViewerError(.httpStatus, statusCode: 404)),
        (.manifest, 500, [:], StackNestViewerError(.httpStatus, statusCode: 500)),
        (.manifest, 502, [:], StackNestViewerError(.remoteUnavailable)),
    ]

    @Test("2xx でない応答は、本文が上限を超えても（申告でも実際の量でも）状態コードで振り分ける",
          arguments: largeErrorBodyCases)
    func errorStatusIsClassifiedBeforeTheSizeLimit(route: StackNestStubServer.Route, status: Int,
                                                   headers: [String: String], expected: StackNestViewerError) async throws
    {
        for announced in [true, false] {
            let stub = StackNestStubServer(pageCount: 3)
            var allHeaders = headers
            if announced { allHeaders["Content-Length"] = "5000" }
            stub.respond(route, with: .status(status, headers: allHeaders, body: Data(count: 2000)))
            let session = try makeSession(stub) { $0.maxResponseBytes = 1000 }
            await #expect(throws: expected, "Content-Length の申告: \(announced)") {
                switch route {
                case .cover: _ = try await session.cover()
                case .progress: try await session.postProgress(page: 1)
                default: _ = try await session.manifest()
                }
            }
        }
    }

    @Test("大きな本文の 2xx でない応答の恒久的な失敗も記録する（先読みが止まる）")
    func largeUnauthorizedBodyStopsPrefetching() async throws {
        let stub = StackNestStubServer(pageCount: 5)
        stub.respond(.manifest, with: .status(401, headers: ["Content-Length": "999999"], body: Data(count: 10)))
        let session = try makeSession(stub) { $0.maxResponseBytes = 1000 }
        await #expect(throws: StackNestViewerError(.unauthorized)) { try await session.manifest() }
        session.prefetch([0, 1])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.map(\.route) == [.manifest])
    }

    @Test("要求の URL は基点の後ろへ文字列で足す（IPv6 の区域 ID・末尾のスラッシュでも同じ宛先のまま）")
    func ipv6ZoneEndpoint() throws {
        let book = URL(string: "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7/")!
        let reference = try StackNestBookReference(version: 1, title: "t", bookURL: book, token: "t",
                                                   expiresAt: .distantFuture, pageCount: 9, direction: .rightToLeft,
                                                   startPage: 0)
        let session = StackNestBookSession(reference: reference)
        #expect(session.makeRequest(for: .page(index: 3, maxWidth: 200))?.url?.absoluteString
                == "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7/pages/3?maxw=200")
        #expect(session.makeRequest(for: .manifest(generation: 0))?.url?.absoluteString
                == "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7/manifest")
        let post = session.makeRequest(for: .progress(serial: 1, page: 5))
        #expect(post?.httpMethod == "POST")
        #expect(post?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(post?.httpBody == Data(#"{"page":5}"#.utf8))
        #expect(post?.timeoutInterval == 20)
    }

    @Test("loopback でない book には要求を 1 件も出さずに .hostNotAllowed")
    func nonLoopbackBookMakesNoRequest() async throws {
        let stub = StackNestStubServer()
        let session = StackNestBookSession(reference: try reference(stub, host: "192.0.2.1"),
                                           configuration: stub.configuration())
        await #expect(throws: StackNestViewerError(.hostNotAllowed)) { try await session.manifest() }
        await #expect(throws: StackNestViewerError(.hostNotAllowed)) { try await session.postProgress(page: 1) }
        #expect(stub.requests.isEmpty)
    }

    @Test("明示して広げたホストにはつなぐ。::1 は既定で通る")
    func widenedPolicyAllowsListedHost() async throws {
        let stub = StackNestStubServer()
        var configuration = stub.configuration()
        configuration.allowedHosts = .loopback(plus: ["192.0.2.1"])
        let widened = StackNestBookSession(reference: try reference(stub, host: "192.0.2.1"), configuration: configuration)
        _ = try await widened.manifest()
        let ipv6 = StackNestBookSession(reference: try reference(stub, host: "[::1]"), configuration: stub.configuration())
        _ = try await ipv6.manifest()
        #expect(stub.requestCount(.manifest) == 2)
    }

    @Test("init(contentsOf:) は loopback でない book を開く時点で断る")
    func contentsOfRefusesNonLoopbackBook() throws {
        let stub = StackNestStubServer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lan = try StackNestFixtures.writeReference(
            StackNestFixtures.referenceJSON(bookURL: URL(string: "http://192.0.2.1:51234/api/v1/libraries/L/books/1")!),
            in: folder, title: "Lan")
        #expect(throws: StackNestViewerError(.hostNotAllowed)) {
            _ = try StackNestBookSession(contentsOf: lan, configuration: stub.configuration())
        }
        let local = try StackNestFixtures.writeReference(StackNestFixtures.referenceJSON(bookURL: stub.bookURL), in: folder)
        let session = try StackNestBookSession(contentsOf: local, configuration: stub.configuration())
        #expect(session.reference.bookURL == stub.bookURL)
        #expect(stub.requests.isEmpty, "作るだけでは通信しない")
    }

    @Test("読んでいる途中に期限が来たら、その時点から要求を出さない")
    func expiryIsCheckedOnEveryRequest() async throws {
        let stub = StackNestStubServer()
        let expiresAt = Date().addingTimeInterval(3600)
        let session = try makeSession(stub, expiresAt: expiresAt) { $0.now = { expiresAt } }
        await #expect(throws: StackNestViewerError(.expired)) { try await session.manifest() }
        await #expect(throws: StackNestViewerError(.expired)) { try await session.postProgress(page: 1) }
        #expect(stub.requests.isEmpty)
    }

    @Test("URLSession はキャッシュ・クッキー・資格情報の保管を持たず、つながるのを待たない")
    func sessionHasNoPersistentStores() throws {
        let stub = StackNestStubServer()
        let host = URLSessionConfiguration.default
        host.protocolClasses = [] // 何を返しても外す
        // A host-supplied proxy (dead port) must not survive hardening.
        host.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9]
        let session = try makeSession(stub) { $0.makeURLSessionConfiguration = { host } }
        // ホストの設定は書き換えない（コピーに手を入れる）。
        #expect(host.urlCache != nil)
        #expect(host.httpCookieStorage != nil)
        #expect(host.connectionProxyDictionary?.isEmpty == false)
        #expect(host.timeoutIntervalForResource == URLSessionConfiguration.default.timeoutIntervalForResource)
        let configuration = session.urlSessionConfigurationForTesting
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true, "プロキシは使わない（鍵は book の宛先にだけ送る）")
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForResource == 30, "waitLimit 25 秒＋上乗せ 5 秒（待つ人のいない先読みの歯止め）")
    }

    @Test("async の顔も waitLimit で必ず戻る（要求の資源の時間切れより先に、待つ人の時計が効く）", .timeLimit(.minutes(1)))
    func asyncWaitLimitIsEnforced() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.waitLimit = .milliseconds(300) }
        let start = Date()
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await session.page(0) }
        // 資源の時間切れは 5.3 秒。1.5 秒より早く戻るのは、待つ人の時計が効いたから。
        #expect(Date().timeIntervalSince(start) < 1.5)
        #expect(await waitUntil { stub.stoppedRequestCount == 1 }, "最後の待つ人が抜けたので要求も取り消す")
        #expect(session.ticketCountForTesting == 0)
    }

    @Test("時計は待つ人ごとに、その呼び出しから数える（先に来た人の時間切れで、後の人は失敗しない）", .timeLimit(.minutes(1)))
    func waitLimitCountsFromEachCall() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.waitLimit = .milliseconds(600) }
        let first = Task { try await session.page(0) }
        #expect(await gate.arrival())
        try await Task.sleep(for: .milliseconds(400))
        let second = Task { try await session.page(0) }
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await first.value }
        #expect(session.waiterCountForTesting(.page(index: 0, maxWidth: nil)) == 1, "後の人はまだ待っている")
        gate.open()
        #expect(StackNestFixtures.marker(of: try await second.value.data) == 0)
    }

    @Test("古い件の manifest の応答が後から記録されても、新しい manifest は残る")
    func olderManifestResponseDoesNotOverwriteNewer() async throws {
        let stub = StackNestStubServer(pageCount: 10)
        let session = try makeSession(stub)
        let older = try await session.fetchManifest(fresh: false)
        stub.setPageCount(4)
        #expect(try await session.manifest(refresh: true).pageCount == 4)
        // 先に取った（件の古い）応答が最後に記録される。呼んだ人には読んだ値が返るが、状態は戻らない。
        #expect(try session.recordManifest(older).pageCount == 10)
        #expect(session.knownPageCountForTesting == 4)
        #expect(session.cachedManifest?.pageCount == 4)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 4)) { try await session.page(7) }
    }

    @Test("見立てを作って返すだけの補助関数で作ったセッションでも通信できる（セッションが見立てを持つ）")
    func sessionKeepsItsStubAlive() async throws {
        func sessionOnly() throws -> StackNestBookSession {
            let stub = StackNestStubServer(pageCount: 4)
            return StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        }
        let session = try sessionOnly()
        #expect(StackNestFixtures.marker(of: try await session.page(2).data) == 2)
    }

    @Test("marker(of:) は Data の一部（スライス）からも読め、見立ての参照ファイルは direction: に従う")
    func markerReadsSlicesAndReferenceHonoursDirection() throws {
        let png = StackNestFixtures.pngPage(marker: 77)
        let padded = Data(repeating: 0, count: 50) + png
        #expect(StackNestFixtures.marker(of: padded[50...]) == 77)
        #expect(StackNestFixtures.marker(of: png) == 77)
        #expect(try StackNestStubServer(direction: "ltr").reference().direction == .leftToRight)
        #expect(try StackNestStubServer().reference().direction == .rightToLeft)
        #expect(try StackNestStubServer(direction: "vertical").reference().direction == .unknown("vertical"))
    }

    @Test("同じ manifest を同時に読んでも（読み直しでなければ）、要求は 1 件")
    func concurrentManifestReadsShareOneRequest() async throws {
        let stub = StackNestStubServer()
        let gate = stub.gate(.manifest)
        defer { gate.open() }
        let session = try makeSession(stub)
        async let first = session.manifest()
        #expect(await gate.arrival())
        async let second = session.manifest()
        #expect(await waitUntil { session.waiterCountForTesting(.manifest(generation: 0)) == 2 })
        gate.open()
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(stub.requestCount(.manifest) == 1)
    }

    @Test("読み直し（refresh: true）は、前から飛んでいる manifest の要求に乗らず、自分の要求の答えを返す")
    func refreshDoesNotJoinAnOlderFlight() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.manifest)
        defer { gate.open() }
        let session = try makeSession(stub)
        let older = Task { try await session.manifest() }
        #expect(await gate.arrival(), "先の要求は 3 ページの時点で StackNest に届いた")
        stub.setPageCount(5)
        let refreshed = Task { try await session.manifest(refresh: true) }
        #expect(await gate.arrival(), "読み直しは自分の要求を出す")
        // 読み直しの後の、読み直しでない読み出しは新しい方の件に乗る。
        let joining = Task { try await session.manifest() }
        #expect(await waitUntil { session.waiterCountForTesting(.manifest(generation: 1)) == 2 })
        gate.open()
        #expect(try await refreshed.value.pageCount == 5)
        #expect(try await joining.value.pageCount == 5)
        #expect(try await older.value.pageCount == 3, "先の要求の人には、その答えを返す")
        #expect(session.knownPageCountForTesting == 5, "古い答えは新しい状態を上書きしない")
        #expect(stub.requestCount(.manifest) == 2)
    }

    @Test("404 の後の読み直しも、前から飛んでいる manifest の要求に乗らない（減ったページ数で振り分ける）")
    func missingPageRecheckDoesNotJoinAnOlderFlight() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.manifest)
        defer { gate.open() }
        let session = try makeSession(stub)
        let older = Task { try await session.manifest() }
        #expect(await gate.arrival())
        stub.setPageCount(2)
        let page = Task { try await session.page(2) }
        #expect(await gate.arrival(), "404 の後に自分の読み直しを出す")
        gate.open()
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 2)) { try await page.value }
        #expect(try await older.value.pageCount == 3)
        #expect(stub.requests.map(\.route) == [.manifest, .page(2), .manifest])
    }

    @Test("加わる前に取り消された待つ人は、要求を出さずに 1 度だけ取り消しで戻る", .timeLimit(.minutes(1)))
    func cancelBeforeRegistrationResumesOnce() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        for _ in 0..<200 {
            let task = Task {
                // 取り消しが先に届くまで待ってから呼ぶ（onCancel が登録より先に走る形）。
                while !Task.isCancelled { await Task.yield() }
                return try await session.manifest(refresh: true)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(stub.requests.isEmpty)
        #expect(session.ticketCountForTesting == 0, "札が残らない")
    }

    @Test("完了と取り消しが競っても、待つ人は 1 度だけ戻る（二重の再開で落ちない・取りこぼしで止まらない）",
          .timeLimit(.minutes(1)))
    func completionAndCancellationRaceResumesOnce() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        var outcomes = (succeeded: 0, cancelled: 0)
        for round in 0..<300 {
            let task = Task { try await session.manifest(refresh: true) }
            if round % 3 != 0 { try? await Task.sleep(nanoseconds: UInt64.random(in: 0...300_000)) }
            task.cancel()
            switch await task.result {
            case .success: outcomes.succeeded += 1
            case .failure(let error):
                #expect(error is CancellationError, "\(error)")
                outcomes.cancelled += 1
            }
        }
        #expect(outcomes.succeeded + outcomes.cancelled == 300)
        #expect(await waitUntil { session.ticketCountForTesting == 0 && session.inFlightKeysForTesting.isEmpty })
    }

    @Test("閉じて手放したセッションは解放され、URLSession も delegate を手放す（1 冊ごとに漏れない）")
    func sessionIsReleasedAfterClose() async throws {
        let stub = StackNestStubServer()
        let sessionRef: WeakBox
        let delegateRef: WeakBox
        do {
            let session = try makeSession(stub)
            _ = try await session.manifest()
            session.close()
            sessionRef = WeakBox(session)
            delegateRef = WeakBox(session.delegateForTesting)
        }
        #expect(await waitUntil { sessionRef.isReleased })
        #expect(await waitUntil { delegateRef.isReleased }, "invalidateAndCancel で delegate が手放される")
    }
}

@Suite("受け皿の単体")
struct ResponseSinkTests {
    private func response(status: Int = 200, contentLength: String?) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1:51234/")!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: contentLength.map { ["Content-Length": $0] } ?? [:])!
    }

    @Test("Content-Length の申告が上限以下なら、その大きさを先に確保する（申告が無い・0・上限超えは確保しない）")
    func reservesTheAnnouncedLength() {
        let cases: [(String?, Bool, Int)] = [("600", true, 600), ("1000", true, 1000), ("1001", false, 0),
                                             (nil, true, 0), ("0", true, 0)]
        for (length, accepted, reserved) in cases {
            let sink = ResponseSink(limit: 1000) { _ in }
            #expect(sink.receive(response(contentLength: length)) == accepted, "\(length ?? "nil")")
            #expect(sink.reservedCapacityForTesting == reserved, "\(length ?? "nil")")
        }
    }

    @Test("確保しても本文はそのまま組み上がり、上限は受け取った量で見る（申告より多く届いた分も）")
    func reservedBodyIsAssembledAndStillCapped() {
        let outcome = OutcomeBox()
        let sink = ResponseSink(limit: 1000) { outcome.set($0) }
        #expect(sink.receive(response(contentLength: "300")))
        #expect(sink.append(Data(repeating: 1, count: 200)))
        #expect(sink.append(Data(repeating: 2, count: 100)))
        sink.complete(error: nil)
        #expect(outcome.value?.data == Data(repeating: 1, count: 200) + Data(repeating: 2, count: 100))

        let overflow = ResponseSink(limit: 1000) { _ in }
        #expect(overflow.receive(response(contentLength: "300")))
        #expect(overflow.append(Data(count: 1000)))
        #expect(!overflow.append(Data(count: 1)), "申告より多く届いても、上限を超えたら断る")
    }

    @Test("申告どおりの大きなページも、セッションを通してそのまま届く")
    func announcedPageArrivesIntact() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let body = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })
        stub.respond(.page(1), with: .status(200, headers: ["Content-Length": "\(body.count)", "Content-Type": "image/jpeg"],
                                             body: body))
        let session = try makeSession(stub)
        #expect(try await session.page(1) == StackNestPage(data: body, contentType: "image/jpeg"))
    }
}

/// 完了の結果を受け取る箱（完了の閉包は `@Sendable`）。
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ResponseSink.Outcome?
    func set(_ outcome: ResponseSink.Outcome) { lock.withLock { stored = outcome } }
    var value: ResponseSink.Outcome? { lock.withLock { stored } }
}
