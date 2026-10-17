import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var prefs: Preferences
    @State private var isDropTargeted = false

    private let clipboardTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            ZStack {
                AmbientBackground()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ToastOverlay()
                if isDropTargeted { DropHint() }
            }
            .toolbar { MainToolbar() }
        }
        .frame(minWidth: 940, minHeight: 620)
        .onDrop(of: [.url, .fileURL, .plainText, .text], isTargeted: $isDropTargeted, perform: handleDrop)
        .onReceive(clipboardTimer) { _ in
            if NSApp.isActive { appState.checkClipboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkClipboard()
        }
        .onChange(of: tools.lastMessage) { _, message in
            if let message {
                ToastCenter.shared.show(message, symbol: "shippingbox")
                tools.lastMessage = nil
            }
        }
        .sheet(isPresented: $appState.showOnboarding) {
            OnboardingView()
                .environmentObjects()
        }
        .sheet(item: $appState.logTask) { task in
            LogView(task: task)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .home: HomeView()
        case .search: SearchView()
        case .queue: QueueView()
        case .library: LibraryView()
        case .subscriptions: SubscriptionsView()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let text = LinkFileReader.read(url)
                    DispatchQueue.main.async { MainActor.assumeIsolated { AppState.shared.handleIncoming(text: text) } }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { AppState.shared.handleIncoming(text: url.absoluteString) } }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { AppState.shared.handleIncoming(text: text) } }
                }
            }
        }
        return handled
    }
}

private struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .foregroundStyle(.tint)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 48))
                    Text("Drop links here").font(.title2.weight(.semibold))
                }
                .foregroundStyle(.tint)
            }
            .padding(24)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var subscriptions: SubscriptionStore

    var body: some View {
        List(selection: Binding(get: { appState.selection }, set: { if let v = $0 { appState.selection = v } })) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            } header: {
                Text("MacYTDL")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .queue: return downloads.pendingCount
        case .subscriptions: return subscriptions.checking.count
        default: return 0
        }
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var tools: ToolManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if downloads.activeCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .symbolEffect(.pulse)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(downloads.activeCount) active")
                            .font(.callout.weight(.semibold))
                        Text(Format.speed(downloads.totalSpeed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                if let progress = downloads.overallProgress {
                    SlimProgressBar(value: progress)
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(tools.isReady ? Color.green : (tools.isPreparing ? Color.orange : Color.red))
                    .frame(width: 7, height: 7)
                Group {
                    if tools.isPreparing {
                        Text("Preparing components…")
                    } else if let version = tools.status[.ytdlp]?.version {
                        Text("yt-dlp \(version)")
                    } else {
                        Text("yt-dlp missing")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if let free = Finder.freeDiskSpace {
                    Text("\(Format.bytes(free)) free")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .glassSurface(cornerRadius: 14)
        .padding(10)
    }
}

// MARK: - Toolbar

private struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var prefs: Preferences

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appState.downloadFromClipboard()
            } label: {
                Label("Download from Clipboard", systemImage: "doc.on.clipboard")
            }
            .help("Download all links on the clipboard (⇧⌘V)")

            Button {
                Finder.openFolder(prefs.downloadFolder)
            } label: {
                Label("Download Folder", systemImage: "folder")
            }
            .help("Open the download folder (⇧⌘O)")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }
}
