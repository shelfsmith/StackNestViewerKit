import Foundation

/// いっしょに渡した本の組（参照ファイルの `handoff`）。StackNest で複数の本を選んで外部ビューアで開くと、同じ組の
/// 参照ファイルには同じ `id` と、選んだ並びでの位置 `index`（0 始まり）と、組の冊数 `count` が入る。ビューアは
/// 同じ `id` の参照ファイルを 1 回の選択として、`index` の順に扱える（先頭を開き、残りを「次の本」にするなど）。
/// 届き方（1 回の `open` か何回かに分かれるか・届く順）には頼らない。
///
/// A group of books handed over together (the reference file's `handoff`). When several books are selected in
/// StackNest and opened in an external viewer, each reference file of the group carries the same `id`, its
/// position `index` (0-based) in the selection and the group's size `count`. A viewer can treat files sharing an
/// `id` as one selection in `index` order (opening the first and keeping the rest as the next books, say), without
/// relying on how they arrive (in one `open` or several, in which order).
public struct StackNestHandoffGroup: Sendable, Hashable, CustomStringConvertible {
    /// 組の印（乱数。等しいかだけを比べる）。 / The group's identifier (random; compare for equality only).
    public let id: String
    /// 組の中での位置（0 始まり・選んだ並び）。 / The position in the group (0-based, selection order).
    public let index: Int
    /// 組の冊数。 / The number of books in the group.
    public let count: Int

    /// 組の冊数の上限。 / The largest accepted `count`.
    public static let maxCount = 10_000

    /// 作る側。読む側が受け付けない値（印の形・`0 ≤ index < count ≤ maxCount`）は投げる。
    ///
    /// For the producer. Throws for values a reader would ignore (the identifier's shape, or
    /// `0 ≤ index < count ≤ maxCount` not holding).
    public init(id: String, index: Int, count: Int) throws {
        guard Self.isAcceptable(id: id, index: index, count: count) else {
            throw StackNestViewerError(.invalidReference)
        }
        self.id = id
        self.index = index
        self.count = count
    }

    private init(uncheckedID id: String, index: Int, count: Int) {
        self.id = id
        self.index = index
        self.count = count
    }

    /// 参照ファイルの `handoff` の値を読む。無い・形が外れるなら nil（参照ファイルは断らず、1 冊として開ける）。
    static func parse(_ value: Any?) -> StackNestHandoffGroup? {
        guard let object = value as? [String: Any], let id = object["id"] as? String,
              let index = JSONValues.integer(object["index"]), let count = JSONValues.integer(object["count"]),
              isAcceptable(id: id, index: index, count: count)
        else { return nil }
        return StackNestHandoffGroup(uncheckedID: id, index: index, count: count)
    }

    /// 印は 8〜64 文字の ASCII の英数字と `-`・`_`（base64url）。位置と冊数は `0 ≤ index < count ≤ maxCount`。
    static func isAcceptable(id: String, index: Int, count: Int) -> Bool {
        let scalars = id.unicodeScalars
        guard (8...64).contains(scalars.count),
              scalars.allSatisfy({ scalar in
                  switch scalar {
                  case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
                  default: return false
                  }
              })
        else { return false }
        return index >= 0 && index < count && count <= maxCount
    }

    /// 説明（印は秘密ではないのでそのまま出す）。 / A description (the identifier isn't secret).
    public var description: String { "StackNestHandoffGroup(id: \(id), index: \(index), count: \(count))" }
}
