# 変更履歴 / Changelog

注目すべき変更をすべてここに記録する。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版は
[Semantic Versioning](https://semver.org/lang/ja/) に従う。各項目は日本語と英語で書く（GitHub Release の本文になる）。

All notable changes are recorded here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/). Each entry is written in Japanese and English; it becomes the GitHub
Release notes.

## [Unreleased]

### 修正 / Fixed

- `prefetch(_:maxWidth:)` にキャッシュの枚数いっぱいの希望を渡し続けると、新しく届いた先読みが次に読むページを追い出し、そのページを開くたびに取り直していた（キャッシュにある希望のページを、古いまま残していた）。指示のたびに、持っている希望のページを近い順に新しくし、先に追い出されるのは表示し終えたページ、次に遠い希望のページになるようにした。
  Passing `prefetch(_:maxWidth:)` as many pages as the cache holds made each newly prefetched page push out the page to be read next, so opening it fetched it again on every page turn (wanted pages already in the cache were left as the oldest entries). Each instruction now refreshes the wanted pages already cached, nearest last, so pages already shown are evicted first, then the farthest wanted pages.

## [0.2.0] - 2026-10-19

### 追加 / Added

- `StackNestBookSession.cachedPageBytes`（キャッシュに持っているページのバイト数）と `bufferedResponseBytes`（受け取り中の本文のバイト数）。ホストのリソースの監視が、セッションのメモリを数えられる。
  `StackNestBookSession.cachedPageBytes` (bytes of pages kept in the cache) and `bufferedResponseBytes` (body bytes of responses still arriving), so host resource monitors can account for a session's memory.
- `StackNestProgressRegistry` の公開の `init()` と、登録簿を渡せる `StackNestProgressReporter` の `init(session:startPage:timing:registry:onFailure:)`・`init(startPage:timing:registry:send:onFailure:)`。ホストの試験が、役をプロセスで 1 つの `StackNestProgressRegistry.shared` に載せずに済む。`registry:` を取らない形はこれまでどおり `shared` に載せる。
  A public `StackNestProgressRegistry.init()` and `StackNestProgressReporter` initializers that take a registry (`init(session:startPage:timing:registry:onFailure:)` and `init(startPage:timing:registry:send:onFailure:)`), so host tests can keep their reporters out of the process-wide `StackNestProgressRegistry.shared`. The initializers without `registry:` still use `shared`.
- 終了時の送り切り `StackNestProgressRegistry.flushAllBlocking(timeout:)`。送信をメインスレッドの外で走らせて呼んだスレッドで待つので、`applicationShouldTerminate` から呼んで `.terminateNow` を返す。送り切りへ渡した役は、送り切れたかに関わらず `hasUnsentWork` が false になる。文書の例もこの形に改めた（`flushAll(timeout:completion:)` と `.terminateLater` の組み合わせは、`DispatchQueue.main.async` などメインキューの仕事の中から終了が求められると、アプリが終わらないまま止まる）。
  `StackNestProgressRegistry.flushAllBlocking(timeout:)` for flushing at quit: it runs the sends off the main thread and waits on the calling thread, so call it from `applicationShouldTerminate` and return `.terminateNow`. A reporter handed to it reports `hasUnsentWork` as false afterwards, whether or not its sends completed. The documented example now uses it (pairing `flushAll(timeout:completion:)` with `.terminateLater` hangs the app when termination is requested from inside a main-queue job, such as `DispatchQueue.main.async`).
- `StackNestBookSession.Configuration.maxConcurrentRequests`（既定 6）。セッションが同時に出す要求の上限。
  `StackNestBookSession.Configuration.maxConcurrentRequests` (6 by default), the most requests a session has in flight at once.

### 変更 / Changed

- 恒久的な失敗（認証の失敗・ライブラリのロック・本が無いなど）を受けた後のセッションは、ページ・manifest・表紙を要求を出さずに同じ失敗で返す（これまでは先読みだけを止め、ほかは毎回要求を出して同じ失敗を受けていた）。書き戻しはこれまでどおり要求を出す。
  After a permanent failure (unauthorized, library locked, book not found and so on), a session answers page, manifest and cover calls with that same error without a request (previously only prefetching stopped, and every other call made a request only to get the same failure). Progress write-backs still make their request.
- `Content-Length` を申告した応答は、その大きさ（`maxResponseBytes` まで）を先に確保してから受け取る。足していくだけのときの、大きなページを受け取る間の確保のし直し（一時に倍近く）と確保の余りが無くなる。
  Responses that announce `Content-Length` now allocate that size (up to `maxResponseBytes`) before the body arrives, avoiding repeated reallocation (briefly close to twice the size) and leftover capacity while large pages are received.
- `pageCacheBytes` の半分を超えるページは持たれず、読むたびに取り直されることを説明に書いた（既定では 32 MiB を超え 64 MiB までのページ）。
  Documented that pages larger than half of `pageCacheBytes` are never kept and are fetched again on every read (with the defaults, pages over 32 MiB and up to 64 MiB).
- セッションは、`book` のパスが StackNest の書く形（`/api/v1/libraries/<library>/books/<id>` と `/api/v1/relay/<relayID>`）のときだけ要求を出し、ほかは要求を出さずに `invalidReference` で断る（`init(contentsOf:)` は開く時点で断る）。書き換えた参照ファイルで、鍵の付いた要求を 127.0.0.1 の別のサービスへ送らせないため。ほかの形の基点へつなぐホストは `Configuration.allowsAnyBookPath` で外せる。
  A session makes requests only when the `book` path has one of the shapes StackNest writes (`/api/v1/libraries/<library>/books/<id>` and `/api/v1/relay/<relayID>`), and otherwise fails with `invalidReference` without a request (`init(contentsOf:)` refuses when opening), so a tampered reference file can't send token-carrying requests to another service on 127.0.0.1. Hosts that connect to a base of another shape can turn this off with `Configuration.allowsAnyBookPath`.
- 書き戻しの役は、送信を切り離したタスクで、送ると決めたその場（まとめ待ちの終わり・`flush()`・`close()` の中）で始める。これまではメインアクターのタスクの中で始めていたので、メインスレッドが空くまで送信が始まらなかった。送信の後始末（失敗の扱いと `onFailure`、次に送るページの判断）は、これまでどおりメインアクターで行う（次のページの送信も、同じく切り離したタスクで始まる）。送り先を差し替えた役（`init(startPage:timing:send:onFailure:)`）で、送り先自身がメインアクターで走るなら、その分はこれまでどおりメインスレッドを待つ。
  A progress reporter now starts each send in a detached task right when it decides to send (when the batching wait ends, or inside `flush()` or `close()`). It used to start the send inside a main-actor task, so the send did not begin until the main thread was free. The follow-up work (handling failures and calling `onFailure`, deciding to send the next waiting page) still runs on the main actor; that next send also starts in a detached task. With a custom sender (`init(startPage:timing:send:onFailure:)`) that itself runs on the main actor, that part still waits for the main thread.
- セッションは同時に出す要求を `maxConcurrentRequests` までに絞り、残りを自分の列で待たせて、書き戻し → 表示の要求 → 先読みの順に出す（列で待つ先読みに表示の要求が乗れば前へ出る。待つ人がいなくなった件は要求を出さずに外す）。`URLSession` の宛先ごとの接続の数も同じ値にする。これまでは要求をすべてすぐ `URLSession` へ渡していたので、多くのスレッドから一度にページを頼むと、宛先ごとの接続の数（macOS の既定 6）を超えた分が `URLSession` の中で順の決まらないまま待ち、表示の要求が先読みの後ろで時間切れになることがあった。列で待つ時間はこれまでどおり `waitLimit` に数える。遅い中継の本で一度に多くのページを頼むと、後の方は今も StackNest へ届かないまま `cannotConnect` で戻ることがある。
  A session now keeps at most `maxConcurrentRequests` requests in flight; the rest wait in its own queue and start in this order: progress write-backs, display requests, prefetches (a queued prefetch that a display request joins moves ahead, and a queued fetch whose waiters all leave is dropped without a request). `URLSession`'s per-host connection limit is set to the same value. Previously every request went to `URLSession` at once, so when many threads asked for pages together, those beyond the per-host limit (6 by default on macOS) waited inside `URLSession` in no set order, where display requests could time out behind prefetches. Time spent in the queue still counts toward `waitLimit`: when a slow relayed book is asked for many pages at once, the later ones can still fail with `cannotConnect` without reaching StackNest.

### 修正 / Fixed

- 2xx でない応答を、本文の大きさより先に状態コードで振り分けるようにした。大きな本文を申告した（または送ってきた）401・403・404 などが、一時的な `responseTooLarge` になっていた（認証の失敗や本が無いことが伝わらず、先読みも止まらなかった）。2xx でない応答の本文は受け取らない。
  Non-2xx responses are now classified by their status code before the body size limit applies. A 401, 403, 404 and so on that announced (or sent) a large body used to become the transient `responseTooLarge`, hiding the real failure and leaving prefetching running. The bodies of non-2xx responses are no longer read.
- `manifest(refresh: true)`（同期の顔も）と、`pages/{n}` の 404 の後の manifest の確かめが、呼ぶ前から飛んでいた manifest の要求に乗らないようにした。乗ると変わる前のページ数を受け取ることがあり、減ったページの 404 が `pageOutOfRange` ではなく `httpStatus(404)` になっていた。`refresh` を付けない読み出しは、これまでどおり飛んでいる要求に乗る。
  `manifest(refresh: true)` (on the blocking face too) and the manifest check after a `pages/{n}` 404 no longer join a manifest request that was already in flight before the call. Joining could return the page count from before a change, so a 404 for a removed page was reported as `httpStatus(404)` instead of `pageOutOfRange`. Reads without `refresh` still join a request in flight.

## [0.1.0] - 2026-10-18

### 追加 / Added

- 参照ファイル（`.stacknestbook`・版 1）の型 `StackNestBookReference` と検査・作る側の `encodedJSON()`・manifest の型。
  The `.stacknestbook` reference file (version 1) type `StackNestBookReference` with validation, the producer's `encodedJSON()`, and the manifest type.
- `Info.plist` の対応の宣言 `StackNestViewerSupport` の解釈と自己点検、名乗り `X-StackNest-Viewer`（`kit=` 付き）。
  Interpretation and self-check of the `StackNestViewerSupport` declaration in `Info.plist`, and the `X-StackNest-Viewer` header with `kit=`.
- エラーの型 `StackNestViewerError` と、英日の既定の文言。
  The `StackNestViewerError` type with default English and Japanese messages.
- 本のセッション `StackNestBookSession`: manifest・ページ・表紙・書き戻し・先読み・メモリのキャッシュ。既定では `127.0.0.1` と `::1` にしかつながない。
  `StackNestBookSession` for the manifest, pages, cover, progress, prefetching and an in-memory cache; connects only to `127.0.0.1` and `::1` by default.
- 同期の読み出し API を持つビューアのための `StackNestBlockingReader`。
  `StackNestBlockingReader` for viewers with a synchronous reading API.
- 読書位置の書き戻し `StackNestProgressReporter` と、終了時の送り切り `StackNestProgressRegistry`。
  `StackNestProgressReporter` for writing the reading position back, and `StackNestProgressRegistry` for flushing at quit.
- 試験の道具 `StackNestViewerKitTesting`（`URLProtocol` の見立てとサンプル）。
  `StackNestViewerKitTesting` with a `URLProtocol` stub server and samples.
- 形式の文書（日英）とサンプルの参照ファイル、DocC の手引き。
  The format document in Japanese and English, sample reference files, and DocC guides.
- 手元で試すための `stacknest-fake-server` と `stacknest-kit-probe`（`Samples`）。
  `stacknest-fake-server` and `stacknest-kit-probe` for trying the kit locally (`Samples`).
