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
        MacYTDLApp.main()
    }
}

struct MacYTDLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var prefs = Preferences.shared
    @StateObject private var appState = AppState.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var tools = ToolManager.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var subscriptions = SubscriptionStore.shared
    @StateObject private var assistant = Assistant.shared

    var body: some Scene {
        Window("MacYTDL", id: "main") {
            ContentView()
                .environmentObjects()
                .preferredColorScheme(prefs.appearance.colorScheme)
                .tint(prefs.accent.color)
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environmentObjects()
                .preferredColorScheme(prefs.appearance.colorScheme)
                .tint(prefs.accent.color)
        }

        MenuBarExtra(isInserted: $prefs.showMenuBarExtra) {
            MenuBarView()
                .environmentObjects()
                .tint(prefs.accent.color)
        } label: {
            Image(systemName: downloads.activeCount > 0 ? "arrow.down.circle.dotted" : "arrow.down.circle")
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
    }
}

// MARK: - Global app state / routing

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, search, queue, library, subscriptions
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: return "New Download"
        case .search: return "Search"
        case .queue: return "Downloads"
        case .library: return "Library"
        case .subscriptions: return "Subscriptions"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "plus.circle"
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

    @Published var selection: SidebarItem = .home
    @Published var clipboardSuggestion: String?
    @Published var showOnboarding = false
    @Published var logTask: DownloadTask?
    @Published var focusURLField = UUID()
    /// Captured from a SwiftUI view so the app delegate can reopen the main window (Dock click).
    var openMainWindow: (() -> Void)?

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var dismissedClipboard: Set<String> = []

    /// Routes a URL from the URL scheme, Services menu, drag & drop or the menu bar.
    func handleIncoming(text: String, instant: Bool = false) {
        let urls = URLTools.extractURLs(from: text)
        guard !urls.isEmpty else { return }
        NSApp.activate()
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

    /// Handles macytdl://download?url=...&mode=instant|audio
    func handleScheme(_ url: URL) {
        guard url.scheme?.lowercased() == "macytdl" else {
            handleIncoming(text: url.absoluteString)
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let target = items.first(where: { $0.name == "url" })?.value
            ?? String(url.absoluteString.dropFirst("macytdl:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
            MainActor.assumeIsolated { AppState.shared.openMainWindow?() }
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
                alert.informativeText = String(localized: "If you quit now, they will be paused and continue the next time you open MacYTDL.")
                alert.addButton(withTitle: String(localized: "Quit"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            manager.stopAllForQuit()
            LibraryStore.shared.saveNow()
            return .terminateNow
        }
    }

    // Services menu: "Download with MacYTDL"
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
            Button("MacYTDL on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/kmitulla/MacYTDL")!)
            }
            Button("Show Logs Folder") { Finder.openFolder(AppPaths.logs.path) }
        }
    }
}
