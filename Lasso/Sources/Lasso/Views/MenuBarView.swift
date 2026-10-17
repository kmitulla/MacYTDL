import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Lasso").font(.headline)
                    Text(downloads.activeCount > 0
                         ? String(localized: "\(downloads.activeCount) active · \(Format.speed(downloads.totalSpeed))")
                         : String(localized: "Ready"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                appState.downloadFromClipboard()
            } label: {
                Label("Download link from clipboard", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.large)

            HStack {
                Button {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    let urls = URLTools.extractURLs(from: text)
                    if urls.isEmpty {
                        ToastCenter.shared.show(String(localized: "No link found on the clipboard."), symbol: "doc.on.clipboard")
                    } else {
                        downloads.addBatch(urls, preset: .audioMP3)
                    }
                } label: {
                    Label("As MP3", systemImage: "music.note").frame(maxWidth: .infinity)
                }
                Button {
                    showMainWindow()
                } label: {
                    Label("Open window", systemImage: "macwindow").frame(maxWidth: .infinity)
                }
            }
            .glassButtonStyle()

            MenuBarPlayer()

            let visible = downloads.tasks.filter { !$0.state.isFinished }.prefix(4)
            if !visible.isEmpty {
                Divider()
                ForEach(Array(visible)) { task in
                    MiniTaskRow(task: task)
                }
            } else if let last = downloads.tasks.last(where: { $0.state == .completed }) {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(last.title).lineLimit(1).font(.callout)
                    Spacer()
                    if let file = last.outputFiles.last {
                        Button { Finder.reveal(file) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Divider()
            HStack {
                Button("Downloads folder") { Finder.openFolder(prefs.downloadFolder) }
                    .buttonStyle(.borderless)
                Spacer()
                if downloads.pendingCount > 0 {
                    Button("Pause all") { downloads.pauseAll() }.buttonStyle(.borderless)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            let open = openWindow
            AppState.shared.openMainWindow = { open(id: "main") }
        }
    }

    private func showMainWindow() {
        WindowManager.shared.showMainWindow()
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            VStack(spacing: 6) {
                Text("Welcome to Lasso")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Save videos and music from 1,800+ websites – fast, private and without ads.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                feature("bolt.fill", "Everything included", "yt-dlp, FFmpeg and Deno are built in and update themselves.")
                feature("music.note.list", "Music & Spotify", "Albums and playlists from Spotify and YouTube Music, fully tagged.")
                feature("play.circle", "Player & library", "Play, sort by album and organize everything right in Lasso.")
                feature("lock.shield", "Private", "No account, no tracking. Everything happens on your Mac.")
            }
            .padding(18)
            .acrylic(cornerRadius: 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text("Downloads are saved to")
                    Text((prefs.downloadFolder as NSString).abbreviatingWithTildeInPath).fontWeight(.semibold)
                    Spacer()
                    Button("Change…") {
                        if let folder = Finder.chooseFolder(startingAt: prefs.downloadFolder) { prefs.downloadFolder = folder }
                    }
                }
                Toggle("Show Lasso in the menu bar", isOn: $prefs.showMenuBarExtra)
                Toggle("Suggest links I copy", isOn: $prefs.watchClipboard)
                HStack(spacing: 8) {
                    if tools.isPreparing {
                        ProgressView().controlSize(.small)
                        Text("Setting up components…")
                    } else if tools.isReady {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Components ready (yt-dlp \(tools.status[.ytdlp]?.version ?? "?"))")
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Components are missing – see Settings › Components.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)

            Button {
                prefs.onboardingDone = true
                appState.showOnboarding = false
                appState.focusURLField = UUID()
            } label: {
                Text("Get started").font(.headline).frame(width: 220)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 600)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        GridRow {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact now-playing controls in the menu bar popover.
private struct MenuBarPlayer: View {
    @ObservedObject private var player = PlayerController.shared

    var body: some View {
        if let item = player.current {
            HStack(spacing: 10) {
                Thumbnail(url: item.thumbnail, cornerRadius: 6, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(item.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: min(player.currentTime, max(1, player.duration)), total: max(1, player.duration))
                        .controlSize(.mini)
                }
                Spacer(minLength: 4)
                Button { player.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.borderless)
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                    .buttonStyle(.borderless)
                Button { player.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.borderless)
            }
            .padding(10)
            .glassSurface(cornerRadius: 14)
        }
    }
}
