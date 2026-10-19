# ``StackNestViewerKitCore``

参照ファイルの形式・対応の宣言・名乗り・エラーと文言。通信を持たない。

The reference file format, the support declaration, the identification header, and errors and messages. No networking.

## 概要 / Overview

StackNest（参照ファイルを作る側）とビューア（読む側）が共有する定義。ビューアは `StackNestViewerKit` を通して使う。

Definitions shared by StackNest (which writes reference files) and viewers (which read them). Viewers use them
through `StackNestViewerKit`.

## Topics

### 参照ファイル / Reference Files

- ``StackNestBookReference``
- ``StackNestBookManifest``
- ``StackNestReopenRequest``
- ``StackNestReadingDirection``
- ``StackNestFormat``

### 宣言と名乗り / Declaration and Identification

- ``StackNestViewerSupport``
- ``StackNestViewerIdentification``
- ``StackNestViewerKitInfo``

### エラー / Errors

- ``StackNestViewerError``
- ``StackNestLanguage``
