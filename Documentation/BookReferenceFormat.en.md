# StackNest Reference File (.stacknestbook) — Version 1

[日本語](BookReferenceFormat.md) | **English**

This document is for authors of external viewers. It describes how a viewer declares support, the reference file StackNest hands to a supported external viewer, and the API the viewer reads the book through.

Swift viewers can use StackNestViewerKit, which implements everything here (see the [README](../README.md)). Viewers written in other languages can implement this document directly; [Samples](Samples) has example reference files, including ones a reader must refuse.

## How it works

1. The user turns on "Sync Reading Position with StackNest (Supported Apps Only)" in StackNest and sets images to open in an external viewer.
2. Only when that viewer declares support in its `Info.plist` (see [Declaring support](#declaring-support)), StackNest writes a **reference file** (extension `.stacknestbook`) instead of the book's file and opens it in the external viewer. The viewer used is the one set for the book's own type for archives, folders and images, and the one set for archives for PDFs (local or remote) and image-only EPUBs from a remote library. A local EPUB isn't handed off by reference; it opens as a file as before.
3. The viewer fetches pages one at a time from the API named in the reference file, and writes back the page the reader reaches. Every request carries the viewer's identification (see [Identification header](#identification-header)).
4. A while after the hand-off (15 seconds by default), StackNest checks once whether the token was used (see [Checking that the book was loaded](#checking-that-the-book-was-loaded)).

## Declaring support

**This declaration is required.** A supporting viewer puts this key in its `Contents/Info.plist`:

```xml
<key>StackNestViewerSupport</key>
<dict>
  <key>referenceFormatVersions</key>
  <array><integer>1</integer></array>
</dict>
```

- List the reference file versions the viewer can read in `referenceFormatVersions`, as integers. StackNest picks the **highest version both sides support** (StackNest writes `1` today) and puts it in the file's `version`. A viewer that declares `[1, 2]` gets version 2 once StackNest can write it, and version 1 until then.
- Before the hand-off, StackNest reads the viewer's `Info.plist` directly (it doesn't rely on LaunchServices or any cache). In any of these cases the viewer counts as unsupported: StackNest issues no token, writes no reference file, and hands the book over as before (a local book as the file, a remote book in StackNest's built-in viewer).
  - The key is missing, isn't a `dict`, or its `referenceFormatVersions` isn't an array
  - No version is supported by both sides
- Elements that aren't integers (booleans, reals, strings) and values of 0 or less are ignored.
- Declaring that the viewer opens the reference file type (`CFBundleDocumentTypes`, UTType) is **not used to decide support**, so that an app that claims to open any file isn't mistaken for a supporting viewer.

## Type

| Item | Value |
|---|---|
| Extension | `stacknestbook` |
| UTType | `app.shelfsmith.stacknest.book-reference` (conforms to `public.json`; exported by StackNest) |

To accept the reference file as a document, import this type with `UTImportedTypeDeclarations` in the viewer's `Info.plist` and accept it as a document type with `CFBundleDocumentTypes` (it arrives in `application(_:open:)`). StackNest names the app when it opens the file, so a rank (`LSHandlerRank`) of `Alternate` is enough. This is for how the file looks in the Finder and for receiving it; support itself is decided by the declaration above.

## Contents (UTF-8 JSON)

```json
{
  "format": "stacknest-book-reference",
  "version": 1,
  "title": "Book Title",
  "book": "http://127.0.0.1:51234/api/v1/libraries/<lib-uuid>/books/<id>",
  "token": "<per-book token>",
  "expiresAt": "2026-10-31T12:00:00Z",
  "pageCount": 180,
  "direction": "rtl",
  "startPage": 41
}
```

| Key | Type | Meaning |
|---|---|---|
| `format` | string | Always `stacknest-book-reference`. Don't open the file if it differs |
| `version` | integer | Format version, chosen by StackNest from the versions the viewer declares (this document is `1`). **Don't open the file if you can't read the value** |
| `title` | string | The book's title (for the window title and so on) |
| `book` | string (URL) | Base of the book's API; the four requests below are appended to it |
| `token` | string | A read token for this book only. Send it as `Authorization: Bearer <token>`. It uses only the characters of an RFC 6750 `b64token` (letters, digits, `-._~+/`, and `=` at the end); a reader refuses a file whose token has any other character |
| `expiresAt` | string (ISO 8601) | When the token expires (30 days after it was issued). StackNest writes UTC with `Z` and no fractional seconds; readers also accept fractional seconds and an offset such as `+09:00`, but not a time without a zone |
| `pageCount` | integer | Page count when the book was opened (`manifest` is authoritative) |
| `direction` | `"rtl"` / `"ltr"` | Reading direction when the book was opened (`manifest` is authoritative) |
| `startPage` | integer (0-based) | Reading position when the book was opened. Open here, after clamping it into `0`…`pageCount - 1` of the `manifest` you read (the book may have shrunk; Swift viewers use `clampedStartPage`) |
| `handoff` | object (optional) | The group of books handed over together (`{"id": …, "index": …, "count": …}`). Present only when several books are handed over at once. See [Books handed over together](#books-handed-over-together-handoff) |

- Ignore keys you don't know, so that later versions that add keys still open.
- `title` and `direction` may be absent, and the file still opens. A missing `title`, or one that isn't a string, is treated as an empty title; a missing `direction`, or a value other than `"rtl"` or `"ltr"`, means the file's direction isn't used (after opening, follow `direction` from `manifest`). `handoff` may be absent too; one that doesn't follow the rules below is treated as absent and the file opens as a single book. A file that lacks any other key (`format`, `version`, `book`, `token`, `expiresAt`, `pageCount`, `startPage`), or has one of the wrong type, is refused.
- "Integer" for `version`, `pageCount` and `startPage` (and `handoff`'s `index` and `count`) means a JSON number that isn't a boolean, has no fractional part (`5.0` is read as `5`; `5.5` is not an integer) and has an absolute value below 10^15.
- A reader **refuses** these files (tell the reader to open the book from StackNest again):
  - can't be read (can't be opened or read), is larger than 1 MiB (1,048,576 bytes), or isn't readable as a JSON object
  - `format` is not `stacknest-book-reference`, or `version` is below 1 (a broken file)
  - `version` is missing or not an integer, or is a version the reader can't read (a newer version); both are treated as an unsupported version (telling the reader to update the app is fine)
  - `book` is missing, isn't a string, can't be parsed as a URL, or has a scheme other than `http` or `https`, an empty host, a query (`?`), a fragment (`#`), or credentials (`user:pw@`). A query or fragment would swallow the `manifest` and other paths appended to it and send the request elsewhere, and credentials invite mixing up destinations
  - `token` is empty or contains a character outside `b64token` (a run of only `=` is refused too)
  - `expiresAt` is in a form that can't be read (such as a time without a zone)
  - `pageCount` is not an integer, is negative, or is above 100,000 (0 is allowed)
  - `startPage` is not an integer, is negative, or is 10^15 or more. A value below 10^15 that exceeds `pageCount` isn't refused; open at the nearest valid page, clamped to `0`…`pageCount - 1`
- A file whose `expiresAt` has passed still parses, and is reported as expired. StackNestViewerKit can still create a session from an expired reference file (`init(contentsOf:)` succeeds), but the first request (`manifest()` and so on) fails with `expired` without a network request. A reader should check the expiry and tell the user to open the book from StackNest again.
- The format check doesn't restrict the host of `book` (LAN and IPv6 addresses are valid as a format). Whether to restrict where to connect is the reader's decision (StackNestViewerKit connects only to 127.0.0.1 and `::1` by default; see "What we ask of viewers" below).
- Among the [Samples](Samples), `reference-v1`, `reference-v1-handoff` (with a group), `reference-v1-unknown-keys`, `reference-expired`, `reference-lan-host` and `reference-ipv6-zone` are valid as a format (StackNestViewerKit still won't read `reference-expired`, because its first request fails as expired, nor `reference-lan-host` and `reference-ipv6-zone`, because of its default host restriction). `reference-credentials` (credentials in `book`), `reference-malformed` (broken JSON) and `reference-v2` (a version the reader can't read) are refused.
- For a book in a local library, `book` is `http://127.0.0.1:<port>/api/v1/libraries/<lib>/books/<id>` (an endpoint that listens on that Mac only).
- **For a book in a remote library, `book` is also on 127.0.0.1: `http://127.0.0.1:<port>/api/v1/relay/<relayID>`** (trial). StackNest relays the requests it receives there to the remote server. Measured: a sandboxed viewer under `NSAllowsLocalNetworking` can reach loopback and private-range addresses, but App Transport Security blocks plain HTTP to Tailscale addresses (100.64.0.0/10) and public addresses. That is why StackNest relays remote books, so the viewer only ever connects to 127.0.0.1 on its own Mac. The four requests below are the same as for a local book, and the viewer doesn't need to tell the two forms of `book` apart. The remote server's token never reaches the viewer (the file's `token` is the relay's own token, and `expiresAt` is the earlier of 30 days after issue and the remote token's expiry).
- The endpoint works only while StackNest is running with the setting on, and its port can change. If the connection is refused, tell the reader to open the book from StackNest again. Quitting StackNest drops its relays, so later requests get **401** (so does an expired relay; again, tell the reader to open the book from StackNest again). A relayed request gets **502** when the remote server can't be reached, the response is too large, or it redirects. A relayed `progress` body over 64 KiB gets **413** and is not forwarded. Other remote responses (including 403, 404 and `X-Library-Locked`) are passed through unchanged. When the remote server refuses the relay with **401 or 403** (a changed password, revoked access and so on), StackNest passes that response through and closes the relay, so later requests get **401**, even for pages it has cached (tell the reader to open the book from StackNest again).

## API

Send `Authorization: Bearer <token>` and the [identification header](#identification-header) with every request.

| Request | Response |
|---|---|
| `GET {book}/manifest` | `{"pageCount": 180, "direction": "rtl", "format": "archive", "etag": "…"}` (ignore other keys). `format` is informational: `archive`, `folder`, `image`, or `text` (PDF and image-only EPUB). Read every book through `pages/{n}` regardless of it |
| `GET {book}/pages/{n}` | The image of page `n` (0-based): JPEG, PNG, WebP and so on (check `Content-Type`). Ask for a smaller image with `?maxw=<width>`. The response usually carries an `ETag`; when it does, `If-None-Match` can return 304 (relayed pages may come without one; see [Relayed pages](#relayed-pages)) |
| `GET {book}/cover` | The cover image (`?maxw=` works too) |
| `POST {book}/progress` | Body `{"page": n}` (0-based) writes back the reading position. 200 |

- The token works for these four requests only. Any other URL or any other book is **403**.
- A **403** on the book's own URL that carries the header `X-Library-Locked: 1` means the library's lock changed after the file was made (its password was changed, or it was locked). Tell the reader to unlock the library in StackNest and open the book from StackNest again.
- **401** means the token expired (or was revoked). It is also 401 when, after the token was issued, the book's number was taken by a different book (the book was removed and another one was added). Tell the reader to open the book from StackNest again.
- **404** means the book is gone (removed from the library, or the server closed the library). For `pages/{n}`, a page number past the end is also **404**. A **404** on `cover` can also mean the book has no cover image.
- `pages/{n}` returns **500** when a page can't be rendered, and `progress` returns **400** for a negative page.

### Relayed pages

For a remote book (a `book` under `/api/v1/relay/`), `pages/{n}` without `maxw` (or with `maxw=1600`) returns the same image StackNest's built-in viewer gets. StackNest keeps relayed pages in its local cache, shares them with the built-in viewer, and after the hand-off prefetches the pages around the one being read (or every page, depending on StackNest's settings) in the background:

- A page wider than 1600 pixels arrives scaled so that its longer side is at most 1600 pixels, re-encoded as JPEG (PNG and WebP pages too). Pages 1600 pixels wide or narrower arrive unchanged. Don't assume the original size or format; check `Content-Type`.
- These responses carry no `ETag`, so fetch them again without `If-None-Match` (they come from the cache, so it's fast).
- A request with any other `maxw` is passed to the remote server and isn't cached.
- `manifest`, `cover` and `progress` are always passed through, and a `manifest` always carries `etag`.

## Identification header

**This header is required.** Send it with every request to the book's API:

```
X-StackNest-Viewer: <bundle id>/<viewer version>; format=<reference file version>[; kit=<StackNestViewerKit version>]
```

Example: `X-StackNest-Viewer: com.example.viewer/1.80; format=1; kit=0.1.0`

- `<viewer version>` is the version the user sees, such as `CFBundleShortVersionString`. Put the opened file's `version` in `format=`.
- Parameters are `key=value` pairs separated by `;`, with `format` first. StackNest skips parameters it doesn't know, so more can be added later.
- StackNestViewerKit adds `kit=` by itself. A viewer that implements this document without the kit doesn't need to send it.
- The bundle ID, the viewer version and the kit version use only `A-Z a-z 0-9 . _ + -` (StackNestViewerKit replaces other characters with `_`). The bundle ID and the viewer version are at most 64 characters and the kit version at most 16, so the whole value fits in 200 characters.
- StackNest doesn't refuse a request without it. The first time the token is used, StackNest records the time and this header's value once (printable ASCII only, cut at 200 characters). Settings ▸ View ▸ External Viewer uses the record to show which viewer has been confirmed to work (with the date and version). The record keeps the whole value, `kit=` included; the setting shows the bundle ID, the viewer version and `format`.

## Books handed over together (handoff)

When the reader selects several books in StackNest and opens them in an external viewer, StackNest writes a reference file for each book handed to that viewer and puts the same group mark in every one of them.

```json
"handoff": {"id": "ZXhhbXBsZS1oYW5kb2Zm", "index": 1, "count": 3}
```

| Key | Type | Meaning |
|---|---|---|
| `id` | string | The group's mark (8 to 64 ASCII letters, digits, `-` and `_`). Reference files of one group share it. Compare it for equality only |
| `index` | integer | The position in the group (0-based): the order of the selection in StackNest's list (its display order) |
| `count` | integer | The number of books in the group (`index` < `count` ≤ 10,000) |

- A single book never gets it. When the books go to different apps because of their kind (archive, folder, image), each app gets its own group.
- StackNest hands each app the group's reference files in one `open`. Still, don't rely on how they arrive (in one `application(_:open:)`, split across several, or in which order): collect the files sharing an `id` and order them by `index`. Don't wait forever for `count` files (a book that couldn't be handed over sends no file); if the group isn't complete a few seconds after the first file arrives, go on with what arrived.
- How to open the group is up to the viewer (open the first and keep the rest as the next books, open each in its own window, and so on). **Fetch each book's `manifest` as soon as its file arrives, even for books you don't open right away.** StackNest checks, for each reference file, whether its token was used 15 seconds after handing it over (see [Checking that the book was loaded](#checking-that-the-book-was-loaded)).
- A `handoff` that doesn't follow the rules above (the characters or length of `id`, the range or type of `index` and `count`) is treated as absent: the file isn't refused and opens as a single book. StackNestViewerKit gives `nil`.
- Older viewers that don't know `handoff` skip it as an unknown key and keep opening each file as a single book.

## Checking that the book was loaded

- A while after the hand-off (15 seconds by default), StackNest checks once whether the token was used, from the records of its own 127.0.0.1 endpoint, for local books and relayed remote books alike. (Only in the form that connects to the remote server directly instead of relaying does it check through the status API, `GET /api/v1/viewer-tokens/{tokenID}`, from the connection that issued the token.)
- For a relay token, "used" means the viewer **reached** the 127.0.0.1 endpoint with a valid relay token, not that it loaded a page (it is recorded even if the remote answers 502, as soon as a request such as `manifest` arrives). A relay token's record carries no real library or book but a sentinel identity (library `"relay"`, book 0); viewers needn't care.
- If it wasn't used yet, StackNest tells the reader that the app hasn't loaded the book and offers a button to open it the usual way (a local book as the file, a remote book in the built-in viewer). The token isn't revoked, so a viewer that starts late still works.
- When you receive a reference file, fetch `manifest` first, so the open is noticed early.

## What we ask of viewers

- Open at `startPage`. If the viewer keeps its own reading position, prefer the reference file's `startPage`.
- Don't write back on every page turn; batch for a few seconds and send `progress`. Send it when the book is closed, too.
- Send the [identification header](#identification-header) with every request.
- The token is a secret. Don't log it or send it anywhere else (see Security notes below).
- Traffic is plain HTTP (StackNest is meant for a LAN or Tailscale). Allow plain HTTP to 127.0.0.1 and the LAN in App Transport Security, and if the viewer is sandboxed, give it the outgoing network (client) entitlement.
- StackNestViewerKit connects only to `127.0.0.1` and `::1` by default, because StackNest writes `book` on 127.0.0.1 for local and relayed remote books alike. A viewer that needs another host must allow it explicitly (`allowedHosts`).
- By default StackNestViewerKit makes requests only when the path of `book` has one of the two shapes StackNest writes (`/api/v1/libraries/<lib>/books/<id>` and `/api/v1/relay/<relayID>`), and otherwise fails with `invalidReference` without a request (tell the reader to open the book from StackNest again). Each segment must be non-empty, not `.` or `..`, and made of letters, digits and `-._~` only (no percent-encoding), with at most one trailing slash. A viewer that needs a base of another shape must allow it explicitly (`allowsAnyBookPath`). Viewers implementing this document directly should make the same check (see Security notes below).

## Security notes

- The token is **plaintext** inside the reference file. StackNest writes the file with mode 600 (owner only) inside directories with mode 700. The token lasts 30 days. The viewer must not copy it elsewhere or log it.
- When the base in `book` is a plain `http://` address on a LAN, the token travels in cleartext. StackNest serves plain HTTP only. Over a plain LAN the token is not encrypted; using StackNest's remote connection over Tailscale encrypts it. When remote books are relayed (the trial default), the viewer's traffic stays within 127.0.0.1, and the hop between StackNest and the remote server takes the same path as StackNest's remote connection.
- The base may be an IPv6 literal (for example `http://[fe80::1%25en0]:51234/…`), so the viewer must parse bracketed hosts, including zone IDs.
- Send the token only to the origin (scheme, host and port) given by `book` in the file. Don't attach it to redirects or to any other host.
- Restricting the host to 127.0.0.1 still leaves the port and path to the reference file. If a tampered file points `book` at a path of another service on 127.0.0.1, the viewer sends that service fixed-shape requests carrying the token (`GET {book}/manifest`, `POST {book}/progress` and so on). Check that the path of `book` has one of the shapes StackNest writes (the two above) before making requests (StackNestViewerKit does so by default).
- Only the principal that issued a token can read whether it was used (`GET /api/v1/viewer-tokens/{tokenID}`). But when the shared server runs with a fixed token (no grants), principals can't be told apart, so every connection holding that token can read the use status (the time and the identification header only) of per-book tokens issued with it. On the 127.0.0.1 endpoint with Local Control on, the CLI and MCP token can read the status of tokens the app issued. Either way only the identification header's value is visible, never the book or the token.

## Versions

| Version | Notes |
|---|---|
| 1 | This document |

A viewer declares the versions it reads in `referenceFormatVersions`, and StackNest writes the highest version both support. When a later version adds keys, a viewer that declares only version 1 still gets version 1.

The full API is described in `/openapi.yaml` (`/docs`) served by the StackNest server.

## Document history

Changes to this document that don't change the format version.

| Date | Change |
|---|---|
| 2026-10-10 | Moved to the StackNestViewerKit repository. Added `kit=` to the identification header, relayed pages, the characters of `token`, the accepted forms of `expiresAt` and StackNestViewerKit's loopback default |
| 2026-10-18 | Added that StackNestViewerKit checks the shape of the `book` path by default (`allowsAnyBookPath`), and the security reason for it |
| 2026-10-19 | Added `handoff` (the group of books handed over together) to the reference file |
