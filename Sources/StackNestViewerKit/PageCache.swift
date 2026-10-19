import Foundation

/// 直近に取ったページのバイト列（古いものから捨てる）。件数と合計の大きさの両方で絞り、1 枚が予算の半分を
/// 超えるページは持たない（1 枚で予算を食い、ほかのページを全部追い出さないため）。鍵は（ページ番号, 幅）。
struct PageCache {
    private let capacity: Int
    private let byteBudget: Int
    private var entries: [(key: RequestKey, response: FetchedResponse)] = []
    /// 持っているページのバイト数の合計。
    private(set) var totalBytes = 0

    init(capacity: Int, byteBudget: Int) {
        self.capacity = max(capacity, 0)
        self.byteBudget = max(byteBudget, 0)
    }

    /// 持っていれば返し、新しい側へ回す。
    mutating func value(for key: RequestKey) -> FetchedResponse? {
        guard let position = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: position)
        entries.append(entry)
        return entry.response
    }

    func contains(_ key: RequestKey) -> Bool { entries.contains { $0.key == key } }

    /// 持っていれば新しい側へ回す（返さない）。持っていなければ何もしない。
    mutating func touch(_ key: RequestKey) {
        guard let position = entries.firstIndex(where: { $0.key == key }) else { return }
        entries.append(entries.remove(at: position))
    }

    mutating func store(_ response: FetchedResponse, for key: RequestKey) {
        if let position = entries.firstIndex(where: { $0.key == key }) {
            totalBytes -= entries.remove(at: position).response.data.count
        }
        guard response.data.count <= byteBudget / 2 else { return }
        entries.append((key, response))
        totalBytes += response.data.count
        while entries.count > capacity || totalBytes > byteBudget {
            totalBytes -= entries.removeFirst().response.data.count
        }
    }

    /// ページ数が減ったときに、範囲の外になったページを捨てる。
    mutating func removePages(atOrAbove count: Int) {
        entries.removeAll { entry in
            guard case .page(let index, _) = entry.key, index >= count else { return false }
            totalBytes -= entry.response.data.count
            return true
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    /// 持っている鍵（古い順）。
    var keys: [RequestKey] { entries.map(\.key) }
}
