import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Published private(set) var collections: [LibraryCollection] = []
    @Published private(set) var isImporting = false
    private var saveScheduled = false

    private var collectionsFile: URL { AppPaths.support.appendingPathComponent("collections.json") }

    init() {
        items = JSONStore.load([LibraryItem].self, from: AppPaths.libraryFile) ?? []
        collections = JSONStore.load([LibraryCollection].self, from: collectionsFile) ?? []
    }

    func item(_ id: UUID) -> LibraryItem? { items.first { $0.id == id } }

    func update(_ item: LibraryItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx] = item
        scheduleSave()
    }

    func update(_ changed: [LibraryItem]) {
        var index: [UUID: Int] = [:]
        for (i, item) in items.enumerated() { index[item.id] = i }
        for item in changed { if let i = index[item.id] { items[i] = item } }
        scheduleSave()
    }

    func toggleFavorite(_ ids: Set<UUID>) {
        let makeFavorite = items.filter { ids.contains($0.id) }.contains { !$0.isFavorite }
        for i in items.indices where ids.contains(items[i].id) { items[i].favorite = makeFavorite }
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        for i in collections.indices { collections[i].itemIDs.removeAll { ids.contains($0) } }
        scheduleSave()
    }

    func moveToTrash(_ ids: Set<UUID>) {
        let urls = items.filter { ids.contains($0.id) && $0.fileExists }.map(\.fileURL)
        NSWorkspace.shared.recycle(urls) { _, _ in }
        remove(ids)
    }

    func markPlayed(_ id: UUID, position: Double? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].playCount = (items[idx].playCount ?? 0) + 1
        items[idx].lastPlayed = Date()
        if let position { items[idx].resumePosition = position }
        scheduleSave()
    }

    func savePosition(_ id: UUID, _ position: Double?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].resumePosition = position
        scheduleSave()
    }

    // MARK: Collections

    @discardableResult
    func createCollection(_ name: String, items ids: [UUID] = []) -> LibraryCollection {
        let collection = LibraryCollection(name: name.isEmpty ? String(localized: "New collection") : name, itemIDs: ids)
        collections.append(collection)
        scheduleSave()
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let i = collections.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        collections[i].name = name
        scheduleSave()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        scheduleSave()
    }

    func add(_ ids: [UUID], to collectionID: UUID) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        for id in ids where !collections[i].itemIDs.contains(id) { collections[i].itemIDs.append(id) }
        scheduleSave()
    }

    func removeFromCollection(_ ids: Set<UUID>, collectionID: UUID) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[i].itemIDs.removeAll { ids.contains($0) }
        scheduleSave()
    }

    func moveInCollection(_ collectionID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[i].itemIDs.move(fromOffsets: offsets, toOffset: destination)
        scheduleSave()
    }

    /// Puts the given ids first (in this order); ids not mentioned keep their relative order at the end.
    func setCollectionOrder(_ id: UUID, _ ordered: [UUID]) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        let rest = collections[i].itemIDs.filter { !ordered.contains($0) }
        collections[i].itemIDs = ordered.filter { collections[i].itemIDs.contains($0) } + rest
        scheduleSave()
    }

    func items(in collection: LibraryCollection) -> [LibraryItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return collection.itemIDs.compactMap { byID[$0] }
    }

    func exportM3U(_ list: [LibraryItem], name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MusicNaming.sanitize(name) + ".m3u8"
        panel.allowedContentTypes = [.init(filenameExtension: "m3u8") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.deletingLastPathComponent().path
        PlaylistWriter.write(name: url.deletingPathExtension().lastPathComponent, folder: folder,
                             entries: list.map { .init(path: $0.filePath, title: "\($0.displayArtist) - \($0.title)", duration: $0.duration) })
    }

    // MARK: Import & metadata

    /// Adds media files from a folder (recursively) to the library.
    func importFolder(_ folder: URL) async -> Int {
        isImporting = true
        defer { isImporting = false }
        let known = Set(items.map(\.filePath))
        let exts = Set(MusicNaming.audioExtensions + MusicNaming.videoExtensions)
        let files: [URL] = await Task.detached {
            var found: [URL] = []
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                if exts.contains(url.pathExtension.lowercased()) { found.append(url) }
                if found.count > 5000 { break }
            }
            return found
        }.value
        var added = 0
        let tools = ToolManager.shared
        for url in files where !known.contains(url.path) {
            var item = LibraryItem(url: "", title: url.deletingPathExtension().lastPathComponent, filePath: url.path,
                                   thumbnail: nil, uploader: nil, duration: nil,
                                   isAudio: MusicNaming.audioExtensions.contains(url.pathExtension.lowercased()),
                                   fileSize: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
                                   date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
            item.source = String(localized: "Imported")
            if let ffprobe = tools.path(for: .ffprobe), let meta = await MetadataReader.read(url.path, ffprobe: ffprobe) {
                apply(meta, to: &item)
            }
            if let ffmpeg = tools.path(for: .ffmpeg) {
                item.thumbnail = await ThumbnailMaker.make(for: url.path, id: item.id, duration: item.duration, ffmpeg: ffmpeg)
            }
            items.insert(item, at: 0)
            added += 1
        }
        scheduleSave()
        return added
    }

    /// Fills missing duration/artist/album/track number from the files themselves.
    func refreshMetadata() async -> Int {
        guard let ffprobe = ToolManager.shared.path(for: .ffprobe) else { return 0 }
        var changed = 0
        for item in items where item.fileExists && (item.duration == nil || item.artist == nil || item.album == nil) {
            guard let meta = await MetadataReader.read(item.filePath, ffprobe: ffprobe) else { continue }
            var copy = item
            apply(meta, to: &copy)
            if copy != item { update(copy); changed += 1 }
        }
        return changed
    }

    private func apply(_ meta: FileMetadata, to item: inout LibraryItem) {
        if item.duration == nil { item.duration = meta.duration }
        if let title = meta.tags.title, !title.isEmpty, item.url.isEmpty { item.title = title }
        if item.artist == nil { item.artist = meta.tags.artist }
        if item.album == nil { item.album = meta.tags.album }
        if item.trackNumber == nil { item.trackNumber = meta.tags.trackNumber }
        if meta.hasAudio && !meta.hasVideo { item.isAudio = true }
    }

    /// Edits title/artist/album/track for one or more items, optionally writing the tags into the files.
    func applyTags(_ tags: MediaTags, to ids: Set<UUID>, writeToFiles: Bool) async -> Int {
        var failures = 0
        let ffmpeg = ToolManager.shared.path(for: .ffmpeg)
        for id in ids {
            guard var item = self.item(id) else { continue }
            if ids.count == 1 {
                if let t = tags.title, !t.isEmpty { item.title = t }
                item.trackNumber = tags.trackNumber
            }
            if let a = tags.artist, !a.isEmpty { item.artist = a }
            if let a = tags.album, !a.isEmpty { item.album = a }
            if writeToFiles, item.fileExists, let ffmpeg {
                var fileTags = tags
                if ids.count > 1 { fileTags.title = nil; fileTags.trackNumber = nil }
                if !(await TagWriter.write(fileTags, to: item.filePath, ffmpeg: ffmpeg)) { failures += 1 }
                item.fileSize = (try? FileManager.default.attributesOfItem(atPath: item.filePath)[.size] as? NSNumber)?.int64Value
            }
            update(item)
        }
        return failures
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

    func replaceAll(_ newItems: [LibraryItem], collections newCollections: [LibraryCollection]? = nil) {
        items = newItems
        if let newCollections { collections = newCollections }
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
                JSONStore.save(self.collections, to: self.collectionsFile)
            }
        }
    }

    func saveNow() {
        guard !DemoMode.isActive else { return }
        JSONStore.save(items, to: AppPaths.libraryFile)
        JSONStore.save(collections, to: collectionsFile)
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
