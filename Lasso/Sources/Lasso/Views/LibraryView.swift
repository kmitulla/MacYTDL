import SwiftUI
import Quartz

enum LibraryScope: Hashable {
    case all, favorites, collection(UUID)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case date, title, artist, album, duration, size, plays, lastPlayed
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .date: return "Date added"
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album & track"
        case .duration: return "Length"
        case .size: return "Size"
        case .plays: return "Most played"
        case .lastPlayed: return "Recently played"
        }
    }
}

enum LibraryGrouping: String, CaseIterable, Identifiable {
    case none, album, artist, source, month, kind
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .none: return "No grouping"
        case .album: return "Album"
        case .artist: return "Artist"
        case .source: return "Website"
        case .month: return "Month"
        case .kind: return "Video / Audio"
        }
    }
}

/// Shared actions for library items (used by grid, list, collections, menus).
@MainActor
enum LibraryActions {
    static func play(_ items: [LibraryItem], start: LibraryItem? = nil) {
        guard let first = start ?? items.first else { return }
        if Preferences.shared.playInApp && MediaConverter.isPlayableByAVFoundation(first) {
            PlayerController.shared.play(items.filter { MediaConverter.isPlayableByAVFoundation($0) }, startAt: first)
        } else if first.fileExists {
            Finder.open(first.filePath)
        }
    }

    static func convertForPlayer(_ item: LibraryItem) {
        convert([item], to: item.isAudio ? .m4a : .mp4, playWhenDone: true)
    }

    static func convert(_ items: [LibraryItem], to target: MediaConverter.Target, playWhenDone: Bool = false) {
        guard let ffmpeg = ToolManager.shared.path(for: .ffmpeg) else { return }
        ToastCenter.shared.show(String(localized: "Converting \(items.count) file(s)…"), symbol: "arrow.triangle.2.circlepath")
        Task { @MainActor in
            var created: [LibraryItem] = []
            for item in items where item.fileExists {
                guard let path = await MediaConverter.convert(item.filePath, to: target, ffmpeg: ffmpeg) else { continue }
                var copy = item
                copy.id = UUID()
                copy.filePath = path
                copy.isAudio = target != .mp4
                copy.date = Date()
                copy.fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
                copy.playCount = nil
                LibraryStore.shared.add(copy)
                created.append(copy)
            }
            let failed = items.count - created.count
            ToastCenter.shared.show(failed == 0 ? String(localized: "Conversion finished")
                                    : String(localized: "\(failed) file(s) could not be converted"),
                                    symbol: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            if playWhenDone, let first = created.first { play([first]) }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var prefs: Preferences
    @State private var query = ""
    @State private var kind: Kind = .all
    @AppStorage("librarySort") private var sort: LibrarySort = .date
    @AppStorage("libraryReverse") private var reverse = false
    @AppStorage("libraryGrouping") private var grouping: LibraryGrouping = .none
    @AppStorage("libraryGrid") private var asGrid = true
    @AppStorage("libraryCardSize") private var cardSize: Double = 230
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var sheet: LibrarySheet?
    @State private var busyMessage: String?

    enum Kind: String, CaseIterable, Identifiable {
        case all, video, audio
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .video: return "Videos"
            case .audio: return "Audio"
            }
        }
    }

    var body: some View {
        Group {
            if case .collection(let id) = appState.libraryScope, let collection = library.collections.first(where: { $0.id == id }) {
                CollectionView(collection: collection)
            } else {
                mainLibrary
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .tags(let ids): TagEditorSheet(ids: ids)
            case .organize(let ids): OrganizeSheet(ids: ids)
            case .duplicates: DuplicatesSheet()
            case .newCollection(let ids): NewCollectionSheet(ids: ids)
            }
        }
    }

    private var mainLibrary: some View {
        VStack(spacing: 0) {
            PageHeader(title: appState.libraryScope == .favorites ? "Favorites" : "Library",
                       subtitle: "\(items.count) files · \(Format.bytes(items.compactMap(\.fileSize).reduce(0, +)))") {
                headerControls
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 10)

            if let busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busyMessage).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }

            if items.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? LocalizedStringKey("Your library is empty") : LocalizedStringKey("No results"), systemImage: "books.vertical")
                } description: {
                    Text(query.isEmpty ? LocalizedStringKey("Everything you download appears here – searchable and one click away.") : LocalizedStringKey("Try another search term."))
                } actions: {
                    if query.isEmpty { Button("Import a folder…") { importFolder() } }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: grouping == .none ? [] : [.sectionHeaders]) {
                        ForEach(groups, id: \.key) { group in
                            Section {
                                if asGrid {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.45), spacing: 16)], spacing: 18) {
                                        ForEach(group.items) { item in
                                            LibraryCard(item: item, selecting: selecting, selected: selection.contains(item.id),
                                                        onTap: { tap(item) }, onPlay: { LibraryActions.play(group.items, start: item) })
                                                .contextMenu { menu(for: item, in: group.items) }
                                        }
                                    }
                                } else {
                                    LazyVStack(spacing: 4) {
                                        ForEach(group.items) { item in
                                            LibraryRow(item: item, selecting: selecting, selected: selection.contains(item.id),
                                                       onTap: { tap(item) }, onPlay: { LibraryActions.play(group.items, start: item) })
                                                .contextMenu { menu(for: item, in: group.items) }
                                        }
                                    }
                                }
                            } header: {
                                if grouping != .none {
                                    GroupHeader(title: group.key, count: group.items.count,
                                                cover: grouping == .album ? group.items.first?.thumbnail : nil) {
                                        LibraryActions.play(group.items)
                                    } shuffle: {
                                        PlayerController.shared.shuffle = true
                                        LibraryActions.play(group.items.shuffled())
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, selection.isEmpty ? 24 : 90)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .overlay(alignment: .bottom) {
            if !selection.isEmpty { selectionBar }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search library")
        .onChange(of: appState.libraryScope) { _, _ in selection = [] }
    }

    // MARK: Header

    private var headerControls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Reverse order", isOn: $reverse)
                Divider()
                Picker("Group by", selection: $grouping) {
                    ForEach(LibraryGrouping.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label("Sort & group", systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
            .help("Sort by album, artist, length … and group the library")

            Menu {
                Picker("View", selection: $asGrid) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(true)
                    Label("List", systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.inline)
                Divider()
                Button("Smaller cards") { cardSize = max(150, cardSize - 40) }.disabled(!asGrid)
                Button("Larger cards") { cardSize = min(380, cardSize + 40) }.disabled(!asGrid)
            } label: {
                Image(systemName: asGrid ? "square.grid.2x2" : "list.bullet")
            }
            .fixedSize()
            .help("Grid or list, card size")

            Button {
                selecting.toggle()
                if !selecting { selection = [] }
            } label: {
                Label(selecting ? LocalizedStringKey("Done") : LocalizedStringKey("Select"), systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .glassButtonStyle(prominent: selecting)

            Menu {
                Button("Import a folder…") { importFolder() }
                Button("Read metadata from files") { refreshMetadata() }
                Button("Find duplicates…") { sheet = .duplicates }
                Button("Organize files into folders…") { sheet = .organize(Set(items.map(\.id))) }
                Divider()
                Button("Play all") { LibraryActions.play(items) }
                Button("Export as playlist (.m3u8)…") { library.exportM3U(items, name: "Lasso") }
                Divider()
                Button("Remove missing files from list") { library.removeMissing() }
                Button("Clear list (keeps files)", role: .destructive) { library.clear() }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .fixedSize()
            .help("Organize: import, duplicates, folders, metadata")
        }
    }

    // MARK: Data

    private var items: [LibraryItem] {
        var result = library.items
        if appState.libraryScope == .favorites { result = result.filter(\.isFavorite) }
        switch kind {
        case .all: break
        case .video: result = result.filter { !$0.isAudio }
        case .audio: result = result.filter { $0.isAudio }
        }
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.artist ?? $0.uploader ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.album ?? "").localizedCaseInsensitiveContains(query)
                    || $0.url.localizedCaseInsensitiveContains(query)
            }
        }
        result.sort(by: comparator)
        return result
    }

    /// Natural order: newest/longest/largest/most played first, text A→Z. "Reverse order" flips it.
    private func comparator(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        reverse ? precedes(b, a) : precedes(a, b)
    }

    /// Strict ordering (ties broken by id) as required by `sort`.
    private func precedes(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        func text(_ x: String, _ y: String) -> ComparisonResult { x.localizedStandardCompare(y) }
        var result: ComparisonResult
        switch sort {
        case .date: result = b.date.compare(a.date)
        case .title: result = text(a.title, b.title)
        case .artist:
            result = text(a.displayArtist, b.displayArtist)
            if result == .orderedSame { result = text(a.title, b.title) }
        case .album:
            result = text(a.album ?? "\u{FFFF}", b.album ?? "\u{FFFF}")
            if result == .orderedSame {
                let (x, y) = (a.trackNumber ?? 999, b.trackNumber ?? 999)
                result = x == y ? text(a.title, b.title) : (x < y ? .orderedAscending : .orderedDescending)
            }
        case .duration: result = Self.descending(a.duration ?? 0, b.duration ?? 0)
        case .size: result = Self.descending(a.fileSize ?? 0, b.fileSize ?? 0)
        case .plays: result = Self.descending(a.playCount ?? 0, b.playCount ?? 0)
        case .lastPlayed: result = (b.lastPlayed ?? .distantPast).compare(a.lastPlayed ?? .distantPast)
        }
        if result == .orderedSame { return a.id.uuidString < b.id.uuidString }
        return result == .orderedAscending
    }

    private static func descending<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
        x == y ? .orderedSame : (x > y ? .orderedAscending : .orderedDescending)
    }

    private var groups: [(key: String, items: [LibraryItem])] {
        let list = items
        guard grouping != .none else { return [("", list)] }
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL yyyy"
        var order: [String] = []
        var buckets: [String: [LibraryItem]] = [:]
        for item in list {
            let key: String
            switch grouping {
            case .none: key = ""
            case .album: key = item.album ?? String(localized: "Unknown album")
            case .artist: key = item.displayArtist
            case .source: key = item.source ?? URLTools.displayHost(item.url)
            case .month: key = monthFormatter.string(from: item.date)
            case .kind: key = item.isAudio ? String(localized: "Audio") : String(localized: "Videos")
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        if grouping == .album {
            return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
                (key, buckets[key]!.sorted { ($0.trackNumber ?? 999, $0.title) < ($1.trackNumber ?? 999, $1.title) })
            }
        }
        if grouping == .artist || grouping == .source || grouping == .kind {
            return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, buckets[$0]!) }
        }
        return order.map { ($0, buckets[$0]!) }
    }

    // MARK: Interaction

    private func tap(_ item: LibraryItem) {
        if selecting || NSEvent.modifierFlags.contains(.command) {
            selecting = true
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        }
    }

    @ViewBuilder
    private func menu(for item: LibraryItem, in context: [LibraryItem]) -> some View {
        let ids = selection.contains(item.id) ? selection : [item.id]
        let chosen = library.items.filter { ids.contains($0.id) }
        LibraryItemMenu(item: item, context: context, ids: ids, chosen: chosen) { sheet = $0 }
    }

    private var selectionBar: some View {
        let chosen = library.items.filter { selection.contains($0.id) }
        return HStack(spacing: 10) {
            Text("\(selection.count) selected").font(.callout.weight(.semibold))
            Button("All") { selection = Set(items.map(\.id)) }.buttonStyle(.link)
            Divider().frame(height: 18)
            Button { LibraryActions.play(chosen) } label: { Label("Play", systemImage: "play.fill") }
            Button { PlayerController.shared.enqueue(chosen) } label: { Label("Up Next", systemImage: "text.line.last.and.arrowtriangle.forward") }
            CollectionMenu(ids: Array(selection)) { sheet = .newCollection(Array(selection)) }
            Button { library.toggleFavorite(selection) } label: { Label("Favorite", systemImage: "heart") }
            Button { sheet = .tags(selection) } label: { Label("Edit info", systemImage: "tag") }
            Menu {
                ForEach(MediaConverter.Target.allCases) { target in
                    Button(target.title) { LibraryActions.convert(chosen, to: target) }
                }
            } label: { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }
            Button { sheet = .organize(selection) } label: { Label("Organize", systemImage: "folder.badge.gearshape") }
            Menu {
                Button("Remove from library") { library.remove(selection); selection = [] }
                Button("Move files to Trash", role: .destructive) { library.moveToTrash(selection); selection = [] }
            } label: { Label("Remove", systemImage: "trash") }
            Button { selection = []; selecting = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCapsule(interactive: true)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busyMessage = String(localized: "Importing and reading metadata…")
        Task {
            let added = await library.importFolder(url)
            busyMessage = nil
            ToastCenter.shared.show(String(localized: "\(added) files imported"), symbol: "tray.and.arrow.down.fill")
        }
    }

    private func refreshMetadata() {
        busyMessage = String(localized: "Reading metadata from files…")
        Task {
            let changed = await library.refreshMetadata()
            busyMessage = nil
            ToastCenter.shared.show(String(localized: "\(changed) items updated"), symbol: "tag.fill")
        }
    }
}

enum LibrarySheet: Identifiable {
    case tags(Set<UUID>), organize(Set<UUID>), duplicates, newCollection([UUID])
    var id: String {
        switch self {
        case .tags(let ids): return "tags-\(ids.hashValue)"
        case .organize(let ids): return "organize-\(ids.hashValue)"
        case .duplicates: return "duplicates"
        case .newCollection(let ids): return "collection-\(ids.hashValue)"
        }
    }
}

private struct GroupHeader: View {
    let title: String
    let count: Int
    let cover: String?
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let cover {
                Thumbnail(url: cover, cornerRadius: 8, symbol: "opticaldisc").frame(width: 42, height: 42)
            }
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button(action: shuffle) { Image(systemName: "shuffle") }.buttonStyle(.borderless).help("Shuffle")
            Button(action: play) { Label("Play", systemImage: "play.fill") }.glassButtonStyle().controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .glassSurface(cornerRadius: 14)
        .padding(.top, 6)
    }
}

/// "Add to collection" menu.
struct CollectionMenu: View {
    let ids: [UUID]
    let newCollection: () -> Void
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Menu {
            Button("New collection…", action: newCollection)
            if !library.collections.isEmpty { Divider() }
            ForEach(library.collections) { collection in
                Button(collection.name) {
                    library.add(ids, to: collection.id)
                    ToastCenter.shared.show(String(localized: "Added to “\(collection.name)”"), symbol: "rectangle.stack.badge.plus")
                }
            }
        } label: {
            Label("Add to collection", systemImage: "rectangle.stack.badge.plus")
        }
    }
}

private struct LibraryCard: View {
    let item: LibraryItem
    let selecting: Bool
    let selected: Bool
    let onTap: () -> Void
    let onPlay: () -> Void
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var player = PlayerController.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: item.thumbnail, cornerRadius: 14, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                .aspectRatio(item.isAudio && item.source == "Spotify" ? 1 : 16 / 9, contentMode: .fit)
                .overlay {
                    if hovering && item.fileExists && !selecting {
                        Button(action: onPlay) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.35))
                            .padding(8)
                    } else if player.current?.id == item.id {
                        Image(systemName: "speaker.wave.2.fill")
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite || hovering {
                        Button {
                            LibraryStore.shared.toggleFavorite([item.id])
                        } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(item.isFavorite ? Color.pink : Color.white)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = item.duration, duration > 0 {
                        Text(Format.duration(duration))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .opacity(item.fileExists ? 1 : 0.45)
            Text(item.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Text([item.displayArtist, item.album].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !prefs.compactMode {
                HStack(spacing: 6) {
                    if !item.fileExists {
                        Pill(text: String(localized: "File missing"), symbol: "exclamationmark.triangle", color: .orange)
                    } else {
                        Image(systemName: item.isAudio ? "music.note" : "film")
                        Text(Format.bytes(item.fileSize))
                        Text(item.fileExtension.uppercased())
                    }
                    Spacer()
                    Text(item.date, format: .relative(presentation: .named))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .acrylic(cornerRadius: 18)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if item.fileExists && !selecting { onPlay() } }
        .onTapGesture(count: 1, perform: onTap)
        .draggable(item.fileURL)
    }
}

private struct LibraryRow: View {
    let item: LibraryItem
    let selecting: Bool
    let selected: Bool
    let onTap: () -> Void
    let onPlay: () -> Void
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var player = PlayerController.shared

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            if let n = item.trackNumber {
                Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
            }
            if prefs.showThumbnails {
                Thumbnail(url: item.thumbnail, cornerRadius: 6, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                    .frame(width: prefs.compactMode ? 48 : 72, height: prefs.compactMode ? 27 : 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).fontWeight(player.current?.id == item.id ? .semibold : .regular)
                    if item.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink) }
                }
                Text([item.displayArtist, item.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(item.fileExtension.uppercased()).font(.caption2).foregroundStyle(.tertiary)
            Text(Format.duration(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            Text(Format.bytes(item.fileSize)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(item.date, style: .date).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Button(action: onPlay) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(!item.fileExists)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, prefs.compactMode ? 4 : 8)
        .acrylic(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .opacity(item.fileExists ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.fileExists && !selecting { onPlay() } }
        .onTapGesture(count: 1, perform: onTap)
        .draggable(item.fileURL)
    }
}

struct LibraryItemMenu: View {
    let item: LibraryItem
    var context: [LibraryItem] = []
    var ids: Set<UUID> = []
    var chosen: [LibraryItem] = []
    var openSheet: ((LibrarySheet) -> Void)?

    private var targets: [LibraryItem] { chosen.isEmpty ? [item] : chosen }
    private var targetIDs: Set<UUID> { ids.isEmpty ? [item.id] : ids }

    var body: some View {
        Button("Play") { LibraryActions.play(context.isEmpty ? targets : context, start: item) }.disabled(!item.fileExists)
        Button("Play Next") { PlayerController.shared.playNext(targets) }.disabled(!item.fileExists)
        Button("Add to Up Next") { PlayerController.shared.enqueue(targets) }.disabled(!item.fileExists)
        Button("Open with Default App") { Finder.open(item.filePath) }.disabled(!item.fileExists)
        Button("Show in Finder") { Finder.reveal(item.filePath) }
        Button("Quick Look") { QuickLook.show(item.fileURL) }.disabled(!item.fileExists)
        Divider()
        Button(item.isFavorite ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites")) { LibraryStore.shared.toggleFavorite(targetIDs) }
        if let openSheet {
            CollectionMenu(ids: Array(targetIDs)) { openSheet(.newCollection(Array(targetIDs))) }
            Button("Edit Info…") { openSheet(.tags(targetIDs)) }
            Button("Organize into Folders…") { openSheet(.organize(targetIDs)) }
        }
        Menu("Convert to") {
            ForEach(MediaConverter.Target.allCases) { target in
                Button(target.title) { LibraryActions.convert(targets, to: target) }
            }
        }
        Divider()
        Button("Copy Link") { Finder.copy(item.url) }.disabled(item.url.isEmpty)
        Button("Open Link in Browser") { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }.disabled(item.url.isEmpty)
        Button("Download Again") {
            DownloadManager.shared.quickDownload(item.url, preset: item.isAudio ? .audioMP3 : nil)
        }
        .disabled(item.url.isEmpty || SpotifyService.isSpotify(item.url))
        if item.fileExists {
            ShareLink(item: item.fileURL) { Text("Share…") }
        }
        Divider()
        Button("Remove from Library") { LibraryStore.shared.remove(targetIDs) }
        Button("Move File to Trash", role: .destructive) { LibraryStore.shared.moveToTrash(targetIDs) }
            .disabled(!item.fileExists)
    }
}

// MARK: - Collections

struct CollectionView: View {
    let collection: LibraryCollection
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var player = PlayerController.shared
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        let items = library.items(in: collection)
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 18) {
                CollectionCover(items: items).frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Collection").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(collection.name).font(.system(size: 30, weight: .bold, design: .rounded)).lineLimit(1)
                    Text("\(items.count) items · \(Format.duration(items.compactMap(\.duration).reduce(0, +)))")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button { LibraryActions.play(items) } label: { Label("Play", systemImage: "play.fill") }
                            .glassButtonStyle(prominent: true)
                        Button {
                            player.shuffle = true
                            LibraryActions.play(items.shuffled())
                        } label: { Label("Shuffle", systemImage: "shuffle") }
                            .glassButtonStyle()
                        Menu {
                            Button("Rename…") { newName = collection.name; renaming = true }
                            Button("Export as playlist (.m3u8)…") { library.exportM3U(items, name: collection.name) }
                            Button("Sort by album") { sortCollection(items) { ($0.album ?? "\u{FFFF}", $0.trackNumber ?? 999, $0.title) < ($1.album ?? "\u{FFFF}", $1.trackNumber ?? 999, $1.title) } }
                            Button("Sort by artist") { sortCollection(items) { ($0.displayArtist, $0.title) < ($1.displayArtist, $1.title) } }
                            Button("Sort by title") { sortCollection(items) { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
                            Divider()
                            Button("Delete collection", role: .destructive) { confirmDelete = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .fixedSize()
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 14)

            if items.isEmpty {
                ContentUnavailableView("This collection is empty", systemImage: "rectangle.stack",
                                       description: Text("Right-click items in the library › Add to collection."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        HStack(spacing: 12) {
                            Text("\(offset + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            Thumbnail(url: item.thumbnail, cornerRadius: 6, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                                .frame(width: 64, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1).fontWeight(player.current?.id == item.id ? .semibold : .regular)
                                Text([item.displayArtist, item.album].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Format.duration(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { LibraryActions.play(items, start: item) }
                        .contextMenu {
                            Button("Play from here") { LibraryActions.play(items, start: item) }
                            Button("Remove from collection") { library.removeFromCollection([item.id], collectionID: collection.id) }
                            Button("Show in Finder") { Finder.reveal(item.filePath) }
                        }
                    }
                    .onMove { library.moveInCollection(collection.id, from: $0, to: $1) }
                    .onDelete { offsets in
                        library.removeFromCollection(Set(offsets.map { items[$0].id }), collectionID: collection.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
            }
        }
        .alert("Rename collection", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { library.renameCollection(collection.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(collection.name)”? The files stay in your library.", isPresented: $confirmDelete) {
            Button("Delete collection", role: .destructive) {
                library.deleteCollection(collection.id)
                appState.libraryScope = .all
            }
        }
    }

    private func sortCollection(_ items: [LibraryItem], by order: (LibraryItem, LibraryItem) -> Bool) {
        library.setCollectionOrder(collection.id, items.sorted(by: order).map(\.id))
    }
}

/// 2×2 mosaic of the first covers.
struct CollectionCover: View {
    let items: [LibraryItem]
    var body: some View {
        let thumbs = Array(items.prefix(4))
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.6), Color.purple.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if thumbs.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { cell(thumbs[0]); cell(thumbs[1]) }
                    GridRow { cell(thumbs[2]); cell(thumbs[3]) }
                }
            } else if let first = thumbs.first {
                Thumbnail(url: first.thumbnail, cornerRadius: 0)
            } else {
                Image(systemName: "rectangle.stack.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }

    private func cell(_ item: LibraryItem) -> some View {
        Thumbnail(url: item.thumbnail, cornerRadius: 0).frame(width: 60, height: 60).clipped()
    }
}

// MARK: - Sheets

private struct NewCollectionSheet: View {
    let ids: [UUID]
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New collection").font(.title2.weight(.bold))
            TextField("Name, e.g. “Road trip”", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            Text("\(ids.count) items will be added. You can reorder them later by dragging.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func create() {
        let collection = library.createCollection(name, items: ids)
        dismiss()
        appState.selection = .library
        appState.libraryScope = .collection(collection.id)
    }
}

private struct TagEditorSheet: View {
    let ids: Set<UUID>
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var track = ""
    @State private var writeToFiles = true
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if ids.count == 1 { Text("Edit info") } else { Text("Edit info for \(ids.count) items") }
            }
            .font(.title2.weight(.bold))
            Form {
                if ids.count == 1 {
                    TextField("Title", text: $title)
                }
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)
                if ids.count == 1 {
                    TextField("Track number", text: $track)
                }
                Toggle("Also write the tags into the files (Music, Finder, other players)", isOn: $writeToFiles)
            }
            .formStyle(.grouped)
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Saving…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(saving)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            let items = library.items.filter { ids.contains($0.id) }
            if let first = items.first {
                title = first.title
                artist = items.allSatisfy { $0.artist == first.artist } ? (first.artist ?? "") : ""
                album = items.allSatisfy { $0.album == first.album } ? (first.album ?? "") : ""
                track = first.trackNumber.map(String.init) ?? ""
            }
        }
    }

    private func save() {
        saving = true
        let tags = MediaTags(title: title, artist: artist.isEmpty ? nil : artist, album: album.isEmpty ? nil : album,
                             albumArtist: nil, trackNumber: Int(track), trackCount: nil, year: nil)
        Task {
            let failures = await library.applyTags(tags, to: ids, writeToFiles: writeToFiles)
            saving = false
            if failures > 0 {
                ToastCenter.shared.show(String(localized: "\(failures) file(s) could not be tagged"), symbol: "exclamationmark.triangle.fill")
            }
            dismiss()
        }
    }
}

private struct OrganizeSheet: View {
    let ids: Set<UUID>
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: LibraryOrganizer.Pattern = .artistAlbum
    @State private var root = ""

    var body: some View {
        let items = library.items.filter { ids.contains($0.id) }
        let moves = LibraryOrganizer.plan(items, pattern: pattern, root: root.isEmpty ? prefs.downloadFolder : root)
        VStack(alignment: .leading, spacing: 14) {
            Text("Organize files into folders").font(.title2.weight(.bold))
            Text("Lasso moves the files and keeps the library, collections and the player up to date.")
                .foregroundStyle(.secondary)
            Picker("Structure", selection: $pattern) {
                ForEach(LibraryOrganizer.Pattern.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Target folder")
                Text(((root.isEmpty ? prefs.downloadFolder : root) as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Change…") { if let f = Finder.chooseFolder(startingAt: root.isEmpty ? prefs.downloadFolder : root) { root = f } }
            }
            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(moves.prefix(60)) { move in
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                                Text((move.destination as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                            }
                        }
                        if moves.count > 60 { Text("… and \(moves.count - 60) more").font(.caption).foregroundStyle(.secondary) }
                        if moves.isEmpty { Text("Everything is already in place.").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move \(moves.count) files") {
                    let updated = LibraryOrganizer.perform(moves)
                    library.update(updated)
                    ToastCenter.shared.show(String(localized: "\(updated.count) files organized"), symbol: "folder.fill.badge.gearshape")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(moves.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}

private struct DuplicatesSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [DuplicateFinder.Group] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Duplicates").font(.title2.weight(.bold))
            Text("Same link or same title and length. The newest copy is kept.").foregroundStyle(.secondary)
            if groups.isEmpty {
                ContentUnavailableView("No duplicates found", systemImage: "checkmark.seal")
                    .frame(height: 220)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.items.first?.title ?? "") {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { offset, item in
                                HStack {
                                    Image(systemName: offset == 0 ? "checkmark.circle.fill" : "minus.circle")
                                        .foregroundStyle(offset == 0 ? Color.green : Color.orange)
                                    Text((item.filePath as NSString).abbreviatingWithTildeInPath)
                                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                                    Spacer()
                                    Text(Format.bytes(item.fileSize)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(height: 300)
            }
            HStack {
                Text("\(groups.reduce(0) { $0 + $1.items.count - 1 }) extra copies").foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove copies from library") {
                    library.remove(Set(groups.flatMap { $0.items.dropFirst().map(\.id) }))
                    dismiss()
                }
                .disabled(groups.isEmpty)
                Button("Move copies to Trash", role: .destructive) {
                    library.moveToTrash(Set(groups.flatMap { $0.items.dropFirst().map(\.id) }))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(groups.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640)
        .onAppear { groups = DuplicateFinder.find(library.items) }
    }
}

/// Minimal Quick Look panel bridge.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?

    static func show(_ url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { (url ?? URL(fileURLWithPath: "/")) as NSURL }
    }
}
