import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    static let shared = SearchModel()

    @Published var query = ""
    @Published var results: [PlaylistEntry] = []
    @Published var isSearching = false
    @Published var error: String?
    @Published var preset: QualityPreset = Preferences.shared.defaultOptions.preset
    @Published var added: Set<String> = []
    private var task: Task<Void, Never>?

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if URLTools.isLikelyMediaURL(q) {
            AppState.shared.handleIncoming(text: q)
            return
        }
        isSearching = true
        error = nil
        task?.cancel()
        task = Task {
            do {
                let found = try await MetadataService.search(q)
                guard !Task.isCancelled else { return }
                results = found
                if found.isEmpty { error = String(localized: "No results.") }
            } catch {
                self.error = error.localizedDescription
            }
            isSearching = false
        }
    }
}

struct SearchView: View {
    @StateObject private var model = SearchModel.shared
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Search", subtitle: "Search YouTube right here – no browser, no ads.")

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                    TextField("What are you looking for?", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { model.search() }
                    Picker("", selection: $model.preset) {
                        Section("Video") { ForEach(QualityPreset.videoPresets) { Text($0.title).tag($0) } }
                        Section("Audio") { ForEach(QualityPreset.audioPresets) { Text($0.title).tag($0) } }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .help("Quality used by the quick download buttons")
                    Button {
                        model.search()
                    } label: {
                        Label("Search", systemImage: "arrow.right").fontWeight(.semibold)
                    }
                    .glassButtonStyle(prominent: true)
                    .controlSize(.large)
                    .disabled(model.query.isEmpty || model.isSearching)
                }
                .padding(.leading, 20)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .glassCapsule(interactive: true)

                if model.isSearching {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity)
                } else if let error = model.error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                } else if model.results.isEmpty {
                    ContentUnavailableView("Find something great",
                                           systemImage: "sparkle.magnifyingglass",
                                           description: Text("Results appear here. Download with one click – as video or audio."))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 16)], spacing: 18) {
                        ForEach(model.results) { entry in
                            SearchResultCard(entry: entry)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear { focused = model.results.isEmpty }
    }
}

private struct SearchResultCard: View {
    let entry: PlaylistEntry
    @ObservedObject private var model = SearchModel.shared
    @EnvironmentObject private var appState: AppState
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: entry.thumbnail, cornerRadius: 14)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if let duration = entry.duration {
                        Text(Format.duration(duration))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            Text(entry.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if let uploader = entry.uploader { Text(uploader).lineLimit(1) }
                if let views = entry.viewCount {
                    Text("·")
                    Text("\(Format.count(views)) views")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if model.added.contains(entry.id) {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                } else {
                    Button {
                        DownloadManager.shared.quickDownload(entry.url, preset: model.preset)
                        model.added.insert(entry.id)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .glassButtonStyle(prominent: true)
                    Button {
                        DownloadManager.shared.quickDownload(entry.url, preset: .audioMP3)
                        model.added.insert(entry.id)
                    } label: {
                        Label("MP3", systemImage: "music.note")
                    }
                    .glassButtonStyle()
                    .help("Download as MP3")
                }
                Spacer()
                Button {
                    appState.selection = .home
                    HomeModel.shared.analyze(entry.url)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .glassButtonStyle()
                .help("Open with all options")
            }
            .controlSize(.small)
        }
        .padding(10)
        .acrylic(cornerRadius: 18)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Link") { Finder.copy(entry.url) }
            Button("Open in Browser") { if let url = URL(string: entry.url) { NSWorkspace.shared.open(url) } }
        }
    }
}
