import SwiftUI
import AVKit

/// Floating glass mini player at the bottom of the main window.
struct MiniPlayerBar: View {
    @ObservedObject var player = PlayerController.shared
    @EnvironmentObject private var appState: AppState
    @State private var scrubbing: Double?

    var body: some View {
        if let item = player.current {
            VStack(spacing: 6) {
                if let error = player.error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).lineLimit(2)
                        Spacer()
                        Button("Convert") { LibraryActions.convertForPlayer(item) }
                        Button("Open externally") { Finder.open(item.filePath) }
                        Button { player.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .controlSize(.small)
                }
                HStack(spacing: 14) {
                    artwork(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(item.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 190, alignment: .leading)

                    HStack(spacing: 4) {
                        transport("backward.fill", help: "Previous") { player.previous() }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 34, height: 34)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .help("Play/Pause (⌥Space)")
                        transport("forward.fill", help: "Next") { player.next() }
                    }

                    HStack(spacing: 8) {
                        Text(Format.duration(scrubbing ?? player.currentTime).ifEmpty("0:00"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        Slider(value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrubbing = $0 }),
                               in: 0...max(1, player.duration)) { editing in
                            if !editing, let value = scrubbing { player.seek(to: value); scrubbing = nil }
                        }
                        .controlSize(.small)
                        Text(Format.duration(player.duration).ifEmpty("0:00"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    }
                    .frame(minWidth: 160)

                    HStack(spacing: 2) {
                        toggle("shuffle", active: player.shuffle, help: "Shuffle") { player.shuffle.toggle() }
                        toggle(player.repeatMode.symbol, active: player.repeatMode != .off, help: "Repeat") { player.cycleRepeat() }
                        Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                        Slider(value: $player.volume, in: 0...1).frame(width: 70).controlSize(.mini)
                        transport("rectangle.expand.vertical", help: "Open player") { appState.openPlayerWindow?() }
                        transport("xmark", help: "Stop") { player.stop() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassSurface(cornerRadius: 22, interactive: true)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func artwork(_ item: LibraryItem) -> some View {
        Group {
            if let image = player.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Thumbnail(url: item.thumbnail, cornerRadius: 8, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { appState.openPlayerWindow?() }
    }

    private func transport(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggle(_ symbol: String, active: Bool, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The separate player window (video with PiP & full screen, or large artwork for music) with "Up Next".
struct PlayerWindowView: View {
    @ObservedObject var player = PlayerController.shared
    @State private var showQueue = true

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if let item = player.current {
                    if item.isAudio {
                        AudioArtworkView(item: item)
                    } else {
                        AVPlayerViewRepresentable(player: player.player)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.circle").font(.system(size: 54))
                        Text("Nothing is playing").font(.title3)
                        Text("Double-click something in the library.").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
            if showQueue {
                Divider()
                PlayerQueueList()
                    .frame(width: 300)
            }
        }
        .frame(minWidth: 640, minHeight: 380)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Speed", selection: $player.rate) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Text(verbatim: "\(rate == 1 ? "1" : String(format: "%g", rate))×").tag(Float(rate))
                    }
                }
                .help("Playback speed")
                Button { showQueue.toggle() } label: { Label("Up Next", systemImage: "list.bullet") }
                    .help("Show or hide the queue")
            }
        }
        .navigationTitle(player.current?.title ?? String(localized: "Player"))
    }
}

private struct AudioArtworkView: View {
    let item: LibraryItem
    @ObservedObject var player = PlayerController.shared

    var body: some View {
        ZStack {
            Thumbnail(url: item.thumbnail, cornerRadius: 0, symbol: "music.note")
                .blur(radius: 60)
                .opacity(0.55)
                .scaleEffect(1.3)
            VStack(spacing: 18) {
                Group {
                    if let image = player.artwork {
                        Image(nsImage: image).resizable().aspectRatio(1, contentMode: .fill)
                    } else {
                        Thumbnail(url: item.thumbnail, cornerRadius: 0, symbol: "music.note")
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .scaleEffect(player.isPlaying ? 1 : 0.94)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                VStack(spacing: 4) {
                    Text(item.title).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                    Text([item.displayArtist, item.album].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                HStack(spacing: 26) {
                    big("gobackward.15") { player.skip(-15) }
                    big("backward.fill") { player.previous() }
                    big(player.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 54) { player.toggle() }
                    big("forward.fill") { player.next() }
                    big("goforward.30") { player.skip(30) }
                }
                .foregroundStyle(.white)
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                    .frame(maxWidth: 360)
                    .tint(.white)
            }
            .padding(30)
        }
        .clipped()
    }

    private func big(_ symbol: String, size: CGFloat = 26, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size)) }
            .buttonStyle(.plain)
    }
}

private struct PlayerQueueList: View {
    @ObservedObject var player = PlayerController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                Text("\(player.queue.count) items").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            List {
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { offset, item in
                    HStack(spacing: 10) {
                        Thumbnail(url: item.thumbnail, cornerRadius: 5, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                            .frame(width: 44, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1).fontWeight(offset == player.index ? .semibold : .regular)
                            Text(item.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if offset == player.index {
                            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .foregroundStyle(.tint)
                                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.jump(to: offset) }
                    .contextMenu {
                        Button("Play") { player.jump(to: offset) }
                        Button("Remove from Up Next") { player.removeFromQueue(at: IndexSet(integer: offset)) }
                    }
                }
                .onMove { player.moveInQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }
            }
            .listStyle(.inset)
        }
    }
}

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.showsSharingServiceButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
