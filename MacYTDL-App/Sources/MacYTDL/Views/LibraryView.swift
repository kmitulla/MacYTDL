import SwiftUI
import Quartz

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var kind: Kind = .all
    @State private var sort: Sort = .newest
    @State private var asGrid = true

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

    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, title, size
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .title: return "Title"
            case .size: return "Size"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Library", subtitle: "\(library.items.count) files · \(Format.bytes(library.totalSize))") {
                HStack(spacing: 8) {
                    Picker("", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.title).tag($0) }
                        }
                        Divider()
                        Button("Remove missing files from list") { library.removeMissing() }
                        Button("Clear list (keeps files)", role: .destructive) { library.clear() }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .frame(width: 44)
                    Button {
                        asGrid.toggle()
                    } label: {
                        Image(systemName: asGrid ? "list.bullet" : "square.grid.2x2")
                    }
                    .glassButtonStyle()
                    .help(asGrid ? LocalizedStringKey("Show as list") : LocalizedStringKey("Show as grid"))
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 14)

            if items.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? LocalizedStringKey("Your library is empty") : LocalizedStringKey("No results"), systemImage: "books.vertical")
                } description: {
                    Text(query.isEmpty ? LocalizedStringKey("Everything you download appears here – searchable and one click away.") : LocalizedStringKey("Try another search term."))
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    if asGrid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)], spacing: 18) {
                            ForEach(items) { item in LibraryCard(item: item) }
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(items) { item in LibraryRow(item: item) }
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search library")
    }

    private var items: [LibraryItem] {
        var result = library.items
        switch kind {
        case .all: break
        case .video: result = result.filter { !$0.isAudio }
        case .audio: result = result.filter { $0.isAudio }
        }
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.uploader ?? "").localizedCaseInsensitiveContains(query)
                    || $0.url.localizedCaseInsensitiveContains(query)
            }
        }
        switch sort {
        case .newest: result.sort { $0.date > $1.date }
        case .oldest: result.sort { $0.date < $1.date }
        case .title: result.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .size: result.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        }
        return result
    }
}

private struct LibraryCard: View {
    let item: LibraryItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: item.thumbnail, cornerRadius: 14, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if hovering && item.fileExists {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.35))
                            .transition(.scale.combined(with: .opacity))
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
            HStack(spacing: 6) {
                if !item.fileExists {
                    Pill(text: String(localized: "File missing"), symbol: "exclamationmark.triangle", color: .orange)
                } else {
                    Image(systemName: item.isAudio ? "music.note" : "film")
                    Text(Format.bytes(item.fileSize))
                }
                Spacer()
                Text(item.date, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .acrylic(cornerRadius: 18)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if item.fileExists { Finder.open(item.filePath) } }
        .contextMenu { LibraryItemMenu(item: item) }
        .draggable(item.fileURL)
    }
}

private struct LibraryRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.thumbnail, cornerRadius: 6, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                .frame(width: 72, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.uploader ?? URLTools.displayHost(item.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.duration(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(Format.bytes(item.fileSize)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(item.date, style: .date).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Button { Finder.reveal(item.filePath) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .acrylic(cornerRadius: 12)
        .opacity(item.fileExists ? 1 : 0.5)
        .onTapGesture(count: 2) { if item.fileExists { Finder.open(item.filePath) } }
        .contextMenu { LibraryItemMenu(item: item) }
        .draggable(item.fileURL)
    }
}

struct LibraryItemMenu: View {
    let item: LibraryItem

    var body: some View {
        Button("Open") { Finder.open(item.filePath) }.disabled(!item.fileExists)
        Button("Show in Finder") { Finder.reveal(item.filePath) }
        Button("Quick Look") { QuickLook.show(item.fileURL) }.disabled(!item.fileExists)
        Divider()
        Button("Copy Link") { Finder.copy(item.url) }
        Button("Open Link in Browser") { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
        Button("Download Again") {
            DownloadManager.shared.quickDownload(item.url, preset: item.isAudio ? .audioMP3 : nil)
        }
        if item.fileExists {
            ShareLink(item: item.fileURL) { Text("Share…") }
        }
        Divider()
        Button("Remove from Library") { LibraryStore.shared.remove(item) }
        Button("Move File to Trash", role: .destructive) { LibraryStore.shared.moveToTrash(item) }
            .disabled(!item.fileExists)
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
