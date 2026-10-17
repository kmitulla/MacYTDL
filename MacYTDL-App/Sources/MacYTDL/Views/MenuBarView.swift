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
                    Text("MacYTDL").font(.headline)
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
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
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
                Text("Welcome to MacYTDL")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Save videos and music from 1,800+ websites – fast, private and without ads.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                feature("bolt.fill", "Everything included", "yt-dlp, FFmpeg and Deno are built in and update themselves.")
                feature("sparkles", "Smart commands", "Say “only audio as MP3” – MacYTDL sets the right options.")
                feature("dot.radiowaves.left.and.right", "Subscriptions", "New videos from your favourite channels download automatically.")
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
                Toggle("Show MacYTDL in the menu bar", isOn: $prefs.showMenuBarExtra)
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
