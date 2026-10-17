import Foundation
import AppKit

/// Small helper to persist Codable values as JSON files in Application Support.
enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Every finished download, searchable in the Library.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var items: [LibraryItem] = []
    private var saveScheduled = false

    init() {
        items = JSONStore.load([LibraryItem].self, from: AppPaths.libraryFile) ?? []
    }

    func add(_ item: LibraryItem) {
        items.removeAll { $0.filePath == item.filePath }
        items.insert(item, at: 0)
        if items.count > 5000 { items.removeLast(items.count - 5000) }
        scheduleSave()
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    func removeMissing() {
        items.removeAll { !$0.fileExists }
        scheduleSave()
    }

    func clear() {
        items.removeAll()
        scheduleSave()
    }

    func moveToTrash(_ item: LibraryItem) {
        NSWorkspace.shared.recycle([item.fileURL]) { _, _ in }
        remove(item)
    }

    func replaceAll(_ newItems: [LibraryItem]) {
        items = newItems
    }

    var totalSize: Int64 { items.compactMap(\.fileSize).reduce(0, +) }

    private func scheduleSave() {
        guard !saveScheduled, !DemoMode.isActive else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                JSONStore.save(self.items, to: AppPaths.libraryFile)
            }
        }
    }

    func saveNow() {
        guard !DemoMode.isActive else { return }
        JSONStore.save(items, to: AppPaths.libraryFile)
    }
}

/// Channels and playlists that are checked for new videos automatically.
@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()

    @Published var subscriptions: [Subscription] = [] {
        didSet {
            if !DemoMode.isActive { JSONStore.save(subscriptions, to: AppPaths.subscriptionsFile) }
        }
    }
    @Published private(set) var checking: Set<UUID> = []

    private var timer: Timer?

    init() {
        subscriptions = JSONStore.load([Subscription].self, from: AppPaths.subscriptionsFile) ?? []
    }

    func archiveURL(for subscription: Subscription) -> URL {
        AppPaths.archives.appendingPathComponent("\(subscription.id.uuidString).txt")
    }

    /// Adds a subscription. With `onlyNew`, everything that exists today is marked as already downloaded.
    func add(url: String, info: MediaInfo?, preset: QualityPreset, onlyNew: Bool) {
        var sub = Subscription(url: url, title: info?.title ?? URLTools.displayHost(url), thumbnail: info?.thumbnail, preset: preset)
        if onlyNew, let info {
            let lines = info.entries.map { entry -> String in
                let extractor = (entry.ieKey ?? info.extractor ?? "youtube").lowercased()
                    .replacingOccurrences(of: "youtubetab", with: "youtube")
                return "\(extractor) \(entry.videoID)"
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: archiveURL(for: sub), atomically: true, encoding: .utf8)
            sub.lastChecked = Date()
        }
        subscriptions.insert(sub, at: 0)
        if !onlyNew { check(sub) }
    }

    func remove(_ sub: Subscription) {
        try? FileManager.default.removeItem(at: archiveURL(for: sub))
        subscriptions.removeAll { $0.id == sub.id }
    }

    func update(_ sub: Subscription) {
        if let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) {
            subscriptions[idx] = sub
        }
    }

    func check(_ sub: Subscription) {
        guard !checking.contains(sub.id) else { return }
        checking.insert(sub.id)
        DownloadManager.shared.enqueueSubscriptionCheck(sub)
    }

    func checkAll() {
        for sub in subscriptions where sub.enabled { check(sub) }
    }

    func didFinishCheck(id: UUID, newItems: Int, error: String?) {
        checking.remove(id)
        guard var sub = subscriptions.first(where: { $0.id == id }) else { return }
        sub.lastChecked = Date()
        sub.lastNewCount = newItems
        sub.totalDownloaded += newItems
        sub.lastError = error
        update(sub)
    }

    func startScheduler() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDueChecks() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.runDueChecks() }
        }
    }

    func runDueChecks() {
        let now = Date()
        for sub in subscriptions where sub.enabled {
            let due = (sub.lastChecked ?? .distantPast).addingTimeInterval(TimeInterval(sub.intervalHours) * 3600)
            if due <= now { check(sub) }
        }
    }
}
