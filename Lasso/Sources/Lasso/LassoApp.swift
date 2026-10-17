import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers

/// Entry point: `--selftest` runs the headless engine test used by CI, otherwise the app starts.
@main
@MainActor
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--selftest") {
            let output = idx + 1 < args.count ? args[idx + 1] : NSTemporaryDirectory()
            SelfTest.run(outputFolder: output)
            return
        }
        Migration.run()
        LassoApp.main()
    }
}

struct LassoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var prefs = Preferences.shared
    @StateObject private var appState = AppState.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var tools = ToolManager.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var subscriptions = SubscriptionStore.shared
    @StateObject private var assistant = Assistant.shared

    var body: some Scene {
        Window("Lasso", id: "main") {
            ContentView()
                .environmentObjects()
                .preferredColorScheme(prefs.appearance.colorScheme)
                .tint(prefs.accent.color)
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Window("Player", id: "player") {
            PlayerWindowView()
                .environmentObjects()
                .preferredColorScheme(.dark)
                .tint(prefs.accent.color)
        }
        .defaultSize(width: 980, height: 600)
        .commands { PlayerCommands() }

        Settings {
            SettingsView()
                .environmentObjects()
                .preferredColorScheme(prefs.appearance.colorScheme)
                .tint(prefs.accent.color)
        }

        MenuBarExtra(isInserted: Binding(
            get: { prefs.showMenuBarExtra },
            set: { if $0 != prefs.showMenuBarExtra { prefs.showMenuBarExtra = $0 } }
        )) {
            MenuBarView()
                .environmentObjects()
                .tint(prefs.accent.color)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

extension View {
    @MainActor
    func environmentObjects() -> some View {
        self
            .environmentObject(Preferences.shared)
            .environmentObject(AppState.shared)
            .environmentObject(DownloadManager.shared)
            .environmentObject(ToolManager.shared)
            .environmentObject(LibraryStore.shared)
            .environmentObject(SubscriptionStore.shared)
            .environmentObject(Assistant.shared)
            .environmentObject(HomeModel.shared)
            .environmentObject(WindowManager.shared)
    }
}

// MARK: - Global app state / routing

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, music, search, queue, library, subscriptions
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: return "New Download"
        case .music: return "Music & Playlists"
        case .search: return "Search"
        case .queue: return "Downloads"
        case .library: return "Library"
        case .subscriptions: return "Subscriptions"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "plus.circle"
        case .music: return "music.note.list"
        case .search: return "magnifyingglass"
        case .queue: return "arrow.down.circle"
        case .library: return "books.vertical"
        case .subscriptions: return "dot.radiowaves.left.and.right"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // SwiftUI writes some of these back through bindings on every update (List selection, sheets).
    // @Published would announce identical values and can cause an endless render loop, so only real
    // changes are published.
    var selection: SidebarItem = .home {
        willSet { if newValue != selection { objectWillChange.send() } }
    }
    var clipboardSuggestion: String? {
        willSet { if newValue != clipboardSuggestion { objectWillChange.send() } }
    }
    var showOnboarding = false {
        willSet { if newValue != showOnboarding { objectWillChange.send() } }
    }
    var logTask: DownloadTask? {
        willSet { if newValue?.id != logTask?.id { objectWillChange.send() } }
    }
    var focusURLField = UUID() {
        willSet { objectWillChange.send() }
    }
    var libraryScope: LibraryScope = .all {
        willSet { if newValue != libraryScope { objectWillChange.send() } }
    }
    var openPlayerWindow: (() -> Void)?
    /// Captured from a SwiftUI view so the app delegate can reopen the main window (Dock click).
    var openMainWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var dismissedClipboard: Set<String> = []

    /// Routes a URL from the URL scheme, Services menu, drag & drop or the menu bar.
    func handleIncoming(text: String, instant: Bool = false) {
        let urls = URLTools.extractURLs(from: text) + (text.lowercased().hasPrefix("spotify:") ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : [])
        guard !urls.isEmpty else { return }
        WindowManager.shared.showMainWindow()
        if let spotify = urls.first(where: SpotifyService.isSpotify) {
            // Spotify links go to the music page (songs are matched on YouTube Music).
            selection = .music
            MusicModel.shared.load(spotify)
            return
        }
        if instant {
            DownloadManager.shared.addBatch(urls)
            selection = .queue
            ToastCenter.shared.show(String(localized: "Added \(urls.count) download(s)"), symbol: "arrow.down.circle.fill")
        } else if urls.count == 1 {
            selection = .home
            HomeModel.shared.analyze(urls[0])
        } else {
            selection = .home
            HomeModel.shared.showBatch(urls)
        }
    }

    /// Handles lasso://download?url=...&mode=instant|audio (macytdl:// still works).
    func handleScheme(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "lasso" || scheme == "macytdl" else {
            handleIncoming(text: url.absoluteString)
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let target = items.first(where: { $0.name == "url" })?.value
            ?? String(url.absoluteString.dropFirst(scheme.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let mode = items.first(where: { $0.name == "mode" })?.value ?? url.host ?? ""
        switch mode {
        case "instant", "now":
            handleIncoming(text: target, instant: true)
        case "audio":
            let urls = URLTools.extractURLs(from: target)
            DownloadManager.shared.addBatch(urls, preset: .audioMP3)
            selection = .queue
            NSApp.activate()
        default:
            handleIncoming(text: target)
        }
    }

    func downloadFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let urls = URLTools.extractURLs(from: text)
        if urls.isEmpty {
            ToastCenter.shared.show(String(localized: "No link found on the clipboard."), symbol: "doc.on.clipboard")
        } else {
            DownloadManager.shared.addBatch(urls)
            ToastCenter.shared.show(String(localized: "Added \(urls.count) download(s)"), symbol: "arrow.down.circle.fill")
        }
    }

    func checkClipboard() {
        guard Preferences.shared.watchClipboard else { clipboardSuggestion = nil; return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), text.count < 4000,
              let first = URLTools.extractURLs(from: text).first,
              !dismissedClipboard.contains(first),
              first != HomeModel.shared.urlText else { return }
        clipboardSuggestion = first
    }

    func dismissClipboardSuggestion() {
        if let s = clipboardSuggestion { dismissedClipboard.insert(s) }
        clipboardSuggestion = nil
    }

    func importLinksFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.plainText, .text, .commaSeparatedText]
            + ["webloc", "url"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK else { return }
        var text = ""
        for url in panel.urls {
            text += LinkFileReader.read(url) + "\n"
        }
        handleIncoming(text: text)
    }
}

enum LinkFileReader {
    /// Reads URLs from .txt/.csv files and from .webloc / .url shortcuts.
    static func read(_ url: URL) -> String {
        if url.pathExtension.lowercased() == "webloc",
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let link = plist["URL"] as? String {
            return link
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        MainActor.assumeIsolated {
            let prefs = Preferences.shared
            AppState.shared.showOnboarding = !prefs.onboardingDone
            DemoMode.applyIfRequested()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { WindowManager.shared.ensureMainWindowAtLaunch() }
            }
            Task { @MainActor in
                await ToolManager.shared.prepare()
                if !DemoMode.isActive {
                    DownloadManager.shared.restore()
                    SubscriptionStore.shared.startScheduler()
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if url.isFileURL {
                    AppState.shared.handleIncoming(text: LinkFileReader.read(url))
                } else {
                    AppState.shared.handleScheme(url)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { WindowManager.shared.showMainWindow() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !Preferences.shared.showMenuBarExtra }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { () -> NSApplication.TerminateReply in
            let manager = DownloadManager.shared
            if manager.activeCount > 0 && !DemoMode.isActive {
                let alert = NSAlert()
                alert.messageText = String(localized: "Downloads are still running")
                alert.informativeText = String(localized: "If you quit now, they will be paused and continue the next time you open Lasso.")
                alert.addButton(withTitle: String(localized: "Quit"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            manager.stopAllForQuit()
            LibraryStore.shared.saveNow()
            return .terminateNow
        }
    }

    // Services menu: "Download with Lasso"
    @objc(downloadURL:userData:error:)
    func downloadURL(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .URL) ?? pboard.string(forType: .string) ?? ""
        MainActor.assumeIsolated {
            AppState.shared.handleIncoming(text: text, instant: userData == "instant")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let file = response.notification.request.content.userInfo["file"] as? String {
            DispatchQueue.main.async { MainActor.assumeIsolated { Finder.reveal(file) } }
        }
        completionHandler()
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Download") {
                AppState.shared.selection = .home
                AppState.shared.focusURLField = UUID()
            }
            .keyboardShortcut("n")
            Button("Download Link from Clipboard") { AppState.shared.downloadFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Import Links from File…") { AppState.shared.importLinksFromFile() }
                .keyboardShortcut("o")
            Divider()
            Button("Minimize to Menu Bar") { WindowManager.shared.hideToMenuBar() }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
        CommandMenu("Downloads") {
            Button("Pause All") { DownloadManager.shared.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Resume All") { DownloadManager.shared.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Retry Failed") { DownloadManager.shared.retryFailed() }
            Divider()
            Button("Clear Finished") { DownloadManager.shared.clearFinished() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Open Download Folder") { Finder.openFolder(Preferences.shared.downloadFolder) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Check Subscriptions Now") { SubscriptionStore.shared.checkAll() }
            Button("Update yt-dlp") { Task { await ToolManager.shared.updateYTDLP() } }
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { AppState.shared.selection = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Supported Websites") {
                NSWorkspace.shared.open(URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!)
            }
            Button("Lasso on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/kmitulla/MacYTDL")!)
            }
            Button("Show Logs Folder") { Finder.openFolder(AppPaths.logs.path) }
        }
    }
}

struct PlayerCommands: Commands {
    var body: some Commands {
        CommandMenu("Player") {
            Button("Play/Pause") { PlayerController.shared.toggle() }
                .keyboardShortcut(.space, modifiers: .option)
            Button("Next") { PlayerController.shared.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous") { PlayerController.shared.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Forward 15 s") { PlayerController.shared.skip(15) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
            Button("Back 15 s") { PlayerController.shared.skip(-15) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
            Divider()
            Button("Shuffle") { PlayerController.shared.shuffle.toggle() }
            Button("Repeat") { PlayerController.shared.cycleRepeat() }
            Divider()
            Button("Show Player") { AppState.shared.openPlayerWindow?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Stop") { PlayerController.shared.stop() }
        }
    }
}
