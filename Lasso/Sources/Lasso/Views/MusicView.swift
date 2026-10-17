import SwiftUI

/// One row of the track list (stable identity for reordering).
struct MusicRow: Identifiable, Hashable {
    let id = UUID()
    var track: MusicTrack
    /// For non-Spotify playlists: the direct link of the entry.
    var directURL: String?
    var thumbnail: String?
    var originalIndex: Int
}

enum MusicSort: String, CaseIterable, Identifiable {
    case original, title, artist, album, duration, shuffle
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .original: return "Original order"
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album & track"
        case .duration: return "Length"
        case .shuffle: return "Shuffle"
        }
    }
}

@MainActor
final class MusicModel: ObservableObject {
    static let shared = MusicModel()

    @Published var urlText = ""
    @Published var collection: MusicCollection?
    @Published var rows: [MusicRow] = []
    @Published var selected: Set<UUID> = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var isSpotify = true
    @Published var preset: QualityPreset = Preferences.shared.musicPreset
    @Published var ownFolder = Preferences.shared.musicFolderPerCollection
    @Published var numbering = true
    @Published var createM3U = true
    @Published var skipExisting = true
    @Published var folder = Preferences.shared.downloadFolder
    @Published var filter = ""
    private var task: Task<Void, Never>?

    var selectedRows: [MusicRow] { rows.filter { selected.contains($0.id) } }

    func load(_ raw: String? = nil) {
        if let raw { urlText = raw }
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        error = nil
        isLoading = true
        collection = nil
        rows = []
        folder = Preferences.shared.downloadFolder
        task?.cancel()
        task = Task {
            do {
                if SpotifyService.isSpotify(text) {
                    let result = try await SpotifyService.fetch(text)
                    guard !Task.isCancelled else { return }
                    isSpotify = true
                    if !preset.isAudio { preset = Preferences.shared.musicPreset }
                    apply(result, rows: result.tracks.enumerated().map {
                        MusicRow(track: $0.element, directURL: nil, thumbnail: $0.element.coverURL ?? result.coverURL, originalIndex: $0.offset)
                    })
                } else {
                    let url = URLTools.normalize(text)
                    let info = try await MetadataService.fetch(url: url, playlist: true)
                    guard !Task.isCancelled else { return }
                    isSpotify = false
                    let entries = info.isPlaylist ? info.entries : [PlaylistEntry(id: info.id, videoID: info.id, ieKey: info.extractor, index: 1,
                                                                                    title: info.title, url: info.url, duration: info.duration,
                                                                                    thumbnail: info.thumbnail, uploader: info.uploader)]
                    let collection = MusicCollection(id: info.id, kind: info.isPlaylist ? .playlist : .track, name: info.title,
                                                     owner: info.uploader, coverURL: info.thumbnail, sourceURL: url, tracks: [])
                    apply(collection, rows: entries.enumerated().map { offset, entry in
                        let track = MusicTrack(title: entry.title, artists: entry.uploader.map { [$0] } ?? [], album: nil, albumArtist: nil,
                                               trackNumber: nil, trackCount: nil, durationMs: entry.duration.map { Int($0 * 1000) },
                                               releaseYear: nil, coverURL: entry.thumbnail, sourceURL: entry.url, explicit: nil)
                        return MusicRow(track: track, directURL: entry.url, thumbnail: entry.thumbnail, originalIndex: offset)
                    })
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func apply(_ collection: MusicCollection, rows: [MusicRow]) {
        self.collection = collection
        self.rows = rows
        selected = Set(rows.map(\.id))
        isLoading = false
    }

    func sort(_ mode: MusicSort) {
        switch mode {
        case .original: rows.sort { $0.originalIndex < $1.originalIndex }
        case .title: rows.sort { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        case .artist: rows.sort { ($0.track.mainArtist, $0.track.title) < ($1.track.mainArtist, $1.track.title) }
        case .album: rows.sort { ($0.track.album ?? "", $0.track.trackNumber ?? 999, $0.originalIndex) < ($1.track.album ?? "", $1.track.trackNumber ?? 999, $1.originalIndex) }
        case .duration: rows.sort { ($0.track.durationMs ?? 0) > ($1.track.durationMs ?? 0) }
        case .shuffle: rows.shuffle()
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        rows.move(fromOffsets: source, toOffset: destination)
    }

    func download() {
        guard let collection else { return }
        let chosen = selectedRows
        guard !chosen.isEmpty else { return }
        var options = Preferences.shared.newOptions()
        options.folder = folder
        options.preset = preset
        options.numberTracks = numbering && collection.kind != .track
        options.createM3U = createM3U
        options.skipExisting = skipExisting
        options.embedThumbnail = true
        options.embedMetadata = true
        if isSpotify {
            DownloadManager.shared.addMusic(collection, tracks: chosen.map(\.track), options: options, ownFolder: ownFolder)
        } else {
            DownloadManager.shared.addPlaylistItems(collection, items: chosen.map { ($0.directURL ?? "", $0.track.title, $0.thumbnail) },
                                                    options: options, ownFolder: ownFolder)
        }
        ToastCenter.shared.show(String(localized: "\(chosen.count) items added to downloads"), symbol: "arrow.down.circle.fill")
        AppState.shared.selection = .queue
    }
}

struct MusicView: View {
    @ObservedObject private var model = MusicModel.shared
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Music & Playlists",
                           subtitle: "Whole albums and playlists from Spotify, YouTube Music, YouTube or SoundCloud – named, numbered and tagged.")
                urlBar
                if model.isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(SpotifyService.isSpotify(model.urlText) ? "Reading the song list from Spotify…" : "Reading the playlist…")
                            .foregroundStyle(.secondary)
                    }
                    .card(cornerRadius: 20)
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .card(cornerRadius: 18)
                } else if let collection = model.collection {
                    header(collection)
                    optionsCard
                    trackList
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var urlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list").font(.title3).foregroundStyle(.secondary)
            TextField("Spotify, YouTube Music, YouTube or SoundCloud link…", text: $model.urlText)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit { model.load() }
            Button {
                if let text = NSPasteboard.general.string(forType: .string) { model.load(text) }
            } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            .glassButtonStyle()
            .controlSize(.large)
            Button { model.load() } label: {
                Label("Load", systemImage: "arrow.down.forward.circle").fontWeight(.semibold)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.large)
            .disabled(model.urlText.isEmpty || model.isLoading)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassCapsule(interactive: true)
    }

    private func header(_ c: MusicCollection) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Thumbnail(url: c.coverURL, cornerRadius: 16, symbol: "music.note.list")
                .frame(width: 150, height: 150)
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Pill(text: kindLabel(c.kind), symbol: model.isSpotify ? "dot.radiowaves.left.and.right" : "play.rectangle",
                         color: model.isSpotify ? .green : .accentColor)
                    if model.isSpotify { Pill(text: "Spotify", color: .green) }
                }
                Text(c.name).font(.title.weight(.bold)).lineLimit(2)
                if let owner = c.owner, !owner.isEmpty {
                    Text(owner).font(.title3).foregroundStyle(.secondary)
                }
                Text("\(model.rows.count) songs · \(Format.duration(model.rows.compactMap(\.track.durationSeconds).reduce(0, +)))")
                    .foregroundStyle(.secondary)
                if model.isSpotify {
                    Label("Spotify itself is DRM-protected: Lasso finds each song on YouTube Music (matching length) and tags it with Spotify's title, artist, album and track number.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if c.possiblyTruncated {
                    Label("Spotify only shows the first 100 songs without login. Add your free Spotify API key under Settings › Music to load all.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .card(cornerRadius: 24, padding: 20)
    }

    private func kindLabel(_ kind: MusicCollection.Kind) -> String {
        switch kind {
        case .track: return String(localized: "Song")
        case .album: return String(localized: "Album")
        case .playlist: return String(localized: "Playlist")
        case .artist: return String(localized: "Artist")
        }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Format").font(.headline)
                Picker("", selection: $model.preset) {
                    Section("Audio") { ForEach(QualityPreset.audioPresets) { Text($0.title).tag($0) } }
                    if !model.isSpotify {
                        Section("Video") { ForEach(QualityPreset.videoPresets) { Text($0.title).tag($0) } }
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Text(model.preset.subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 18) {
                Toggle("Own folder", isOn: $model.ownFolder)
                    .help("Saves everything in a folder named after the album/playlist")
                Toggle("Number files (01, 02, …)", isOn: $model.numbering)
                Toggle("Playlist file (.m3u8)", isOn: $model.createM3U)
                    .help("For Music, VLC, Plex, car stereos …")
                Toggle("Skip already downloaded", isOn: $model.skipExisting)
                    .help("Load the same playlist again later and only get the new songs")
            }
            .toggleStyle(.checkbox)
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text((model.folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                if model.ownFolder, let name = model.collection?.name, model.collection?.kind != .track {
                    Text("/ \(MusicNaming.sanitize(name))").foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Change…") { if let f = Finder.chooseFolder(startingAt: model.folder) { model.folder = f } }
                Spacer()
            }
            .font(.callout)
        }
        .card(cornerRadius: 20)
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Songs").font(.headline)
                Text("\(model.selected.count) of \(model.rows.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 150)
                Menu {
                    ForEach(MusicSort.allCases) { mode in Button(mode.title) { withAnimation { model.sort(mode) } } }
                } label: { Label("Order", systemImage: "arrow.up.arrow.down") }
                .fixedSize()
                .help("Sort the songs – or drag them into your own order")
                Button("All") { model.selected = Set(model.rows.map(\.id)) }
                Button("None") { model.selected = [] }
            }
            List {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { offset, row in
                    if model.filter.isEmpty || row.track.title.localizedCaseInsensitiveContains(model.filter)
                        || row.track.artistLine.localizedCaseInsensitiveContains(model.filter) {
                        MusicTrackRow(row: row, number: offset + 1, selected: model.selected.contains(row.id)) {
                            if model.selected.contains(row.id) { model.selected.remove(row.id) } else { model.selected.insert(row.id) }
                        }
                    }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.inset)
            .frame(height: min(520, CGFloat(model.rows.count) * 52 + 20))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack {
                Label("Drag songs to change the order – numbering and the playlist file follow it.", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.download()
                } label: {
                    Label("Download \(model.selected.count) songs", systemImage: "arrow.down.circle.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.extraLarge)
                .disabled(model.selected.isEmpty)
            }
        }
        .card(cornerRadius: 20)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                tip("music.note.list", "Spotify playlists & albums", "Paste open.spotify.com links – songs, albums, playlists or an artist's top songs.")
                tip("play.square.stack", "YouTube & YouTube Music", "Whole playlists as MP3/M4A or video, numbered in your order.")
                tip("arrow.triangle.2.circlepath", "Sync later", "Load the same playlist again – only new songs are downloaded.")
                tip("tag", "Clean tags & covers", "Title, artist, album, track number and square cover art in every file.")
            }
        }
    }

    private func tip(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card(cornerRadius: 18, padding: 14)
    }
}

private struct MusicTrackRow: View {
    let row: MusicRow
    let number: Int
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            Thumbnail(url: row.thumbnail, cornerRadius: 5, symbol: "music.note")
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.track.title).lineLimit(1)
                    if row.track.explicit == true {
                        Text(verbatim: "E").font(.caption2.weight(.bold)).padding(.horizontal, 4)
                            .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text([row.track.artistLine, row.track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Format.duration(row.track.durationSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .opacity(selected ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}
