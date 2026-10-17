import Foundation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "Automatic")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system, ocean, violet, magenta, sunset, mint, graphite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .ocean: return String(localized: "Ocean")
        case .violet: return String(localized: "Violet")
        case .magenta: return String(localized: "Magenta")
        case .sunset: return String(localized: "Sunset")
        case .mint: return String(localized: "Mint")
        case .graphite: return String(localized: "Graphite")
        }
    }
    var color: Color? {
        switch self {
        case .system: return nil
        case .ocean: return Color(red: 0.16, green: 0.47, blue: 1.0)
        case .violet: return Color(red: 0.45, green: 0.33, blue: 0.98)
        case .magenta: return Color(red: 0.88, green: 0.22, blue: 0.62)
        case .sunset: return Color(red: 1.0, green: 0.45, blue: 0.2)
        case .mint: return Color(red: 0.1, green: 0.7, blue: 0.55)
        case .graphite: return Color(red: 0.45, green: 0.47, blue: 0.52)
        }
    }
    /// Second colour of the ambient background gradient.
    var companion: Color {
        switch self {
        case .system, .ocean: return Color(red: 0.55, green: 0.3, blue: 0.95)
        case .violet: return Color(red: 0.95, green: 0.35, blue: 0.6)
        case .magenta: return Color(red: 1.0, green: 0.55, blue: 0.25)
        case .sunset: return Color(red: 0.95, green: 0.25, blue: 0.45)
        case .mint: return Color(red: 0.2, green: 0.55, blue: 0.95)
        case .graphite: return Color(red: 0.35, green: 0.4, blue: 0.55)
        }
    }
}

enum AfterQueueAction: String, CaseIterable, Identifiable {
    case nothing, sleep, quit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nothing: return String(localized: "Do nothing")
        case .sleep: return String(localized: "Put Mac to sleep")
        case .quit: return String(localized: "Quit MacYTDL")
        }
    }
}

enum ToolSource: String, CaseIterable, Identifiable {
    case managed, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .managed: return String(localized: "Built-in (recommended)")
        case .system: return String(localized: "System / Homebrew")
        }
    }
}

/// All user settings, persisted in UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    @Published var downloadFolder: String { didSet { save(downloadFolder, "downloadFolder") } }
    @Published var defaultOptions: DownloadOptions { didSet { saveCodable(defaultOptions, "defaultOptions") } }
    @Published var maxConcurrent: Int { didSet { save(maxConcurrent, "maxConcurrent") } }
    @Published var autoRetry: Int { didSet { save(autoRetry, "autoRetry") } }
    @Published var cookieBrowser: CookieBrowser { didSet { save(cookieBrowser.rawValue, "cookieBrowser") } }
    @Published var rateLimit: String { didSet { save(rateLimit, "rateLimit") } }
    @Published var proxy: String { didSet { save(proxy, "proxy") } }
    @Published var concurrentFragments: Int { didSet { save(concurrentFragments, "concurrentFragments") } }
    @Published var forceIPv4: Bool { didSet { save(forceIPv4, "forceIPv4") } }
    @Published var restrictFilenames: Bool { didSet { save(restrictFilenames, "restrictFilenames") } }
    @Published var trimFilenames: Int { didSet { save(trimFilenames, "trimFilenames") } }
    @Published var customArguments: String { didSet { save(customArguments, "customArguments") } }
    @Published var autoUpdateYTDLP: Bool { didSet { save(autoUpdateYTDLP, "autoUpdateYTDLP") } }
    @Published var useNightly: Bool { didSet { save(useNightly, "useNightly") } }
    @Published var toolSource: ToolSource { didSet { save(toolSource.rawValue, "toolSource") } }
    @Published var showMenuBarExtra: Bool { didSet { save(showMenuBarExtra, "showMenuBarExtra") } }
    @Published var watchClipboard: Bool { didSet { save(watchClipboard, "watchClipboard") } }
    @Published var autoAnalyze: Bool { didSet { save(autoAnalyze, "autoAnalyze") } }
    @Published var notifyOnFinish: Bool { didSet { save(notifyOnFinish, "notifyOnFinish") } }
    @Published var playSound: Bool { didSet { save(playSound, "playSound") } }
    @Published var keepAwake: Bool { didSet { save(keepAwake, "keepAwake") } }
    @Published var afterQueue: AfterQueueAction { didSet { save(afterQueue.rawValue, "afterQueue") } }
    @Published var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }
    @Published var accent: AccentChoice { didSet { save(accent.rawValue, "accent") } }
    @Published var autoResumeQueue: Bool { didSet { save(autoResumeQueue, "autoResumeQueue") } }
    @Published var assistantEnabled: Bool { didSet { save(assistantEnabled, "assistantEnabled") } }
    @Published var onboardingDone: Bool { didSet { save(onboardingDone, "onboardingDone") } }
    @Published var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }

    static var standardDownloadFolder: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("MacYTDL").path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        downloadFolder = defaults.string(forKey: "downloadFolder") ?? Preferences.standardDownloadFolder
        if let data = defaults.data(forKey: "defaultOptions"),
           let options = try? JSONDecoder().decode(DownloadOptions.self, from: data) {
            defaultOptions = options
        } else {
            defaultOptions = DownloadOptions()
        }
        maxConcurrent = Self.number(defaults, "maxConcurrent", 3)
        autoRetry = Self.number(defaults, "autoRetry", 2)
        cookieBrowser = CookieBrowser(rawValue: defaults.string(forKey: "cookieBrowser") ?? "") ?? .none
        rateLimit = defaults.string(forKey: "rateLimit") ?? ""
        proxy = defaults.string(forKey: "proxy") ?? ""
        concurrentFragments = Self.number(defaults, "concurrentFragments", 4)
        forceIPv4 = defaults.bool(forKey: "forceIPv4")
        restrictFilenames = defaults.bool(forKey: "restrictFilenames")
        trimFilenames = Self.number(defaults, "trimFilenames", 120)
        customArguments = defaults.string(forKey: "customArguments") ?? ""
        autoUpdateYTDLP = Self.flag(defaults, "autoUpdateYTDLP", true)
        useNightly = defaults.bool(forKey: "useNightly")
        toolSource = ToolSource(rawValue: defaults.string(forKey: "toolSource") ?? "") ?? .managed
        showMenuBarExtra = Self.flag(defaults, "showMenuBarExtra", true)
        watchClipboard = Self.flag(defaults, "watchClipboard", true)
        autoAnalyze = Self.flag(defaults, "autoAnalyze", true)
        notifyOnFinish = Self.flag(defaults, "notifyOnFinish", true)
        playSound = Self.flag(defaults, "playSound", true)
        keepAwake = Self.flag(defaults, "keepAwake", true)
        afterQueue = AfterQueueAction(rawValue: defaults.string(forKey: "afterQueue") ?? "") ?? .nothing
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        accent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .ocean
        autoResumeQueue = Self.flag(defaults, "autoResumeQueue", true)
        assistantEnabled = Self.flag(defaults, "assistantEnabled", true)
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
    }

    /// Options for a new download: the saved defaults plus the current download folder.
    func newOptions() -> DownloadOptions {
        var options = defaultOptions
        options.folder = downloadFolder
        options.clipStart = ""
        options.clipEnd = ""
        options.playlistItems = ""
        options.downloadPlaylist = false
        return options
    }

    func resetToDefaults() {
        let fresh = Preferences(defaults: UserDefaults(suiteName: "MacYTDL.reset.\(UUID().uuidString)")!)
        downloadFolder = fresh.downloadFolder
        defaultOptions = fresh.defaultOptions
        maxConcurrent = fresh.maxConcurrent
        autoRetry = fresh.autoRetry
        cookieBrowser = fresh.cookieBrowser
        rateLimit = fresh.rateLimit
        proxy = fresh.proxy
        concurrentFragments = fresh.concurrentFragments
        forceIPv4 = fresh.forceIPv4
        restrictFilenames = fresh.restrictFilenames
        trimFilenames = fresh.trimFilenames
        customArguments = fresh.customArguments
        autoUpdateYTDLP = fresh.autoUpdateYTDLP
        useNightly = fresh.useNightly
        toolSource = fresh.toolSource
        showMenuBarExtra = fresh.showMenuBarExtra
        watchClipboard = fresh.watchClipboard
        autoAnalyze = fresh.autoAnalyze
        notifyOnFinish = fresh.notifyOnFinish
        playSound = fresh.playSound
        keepAwake = fresh.keepAwake
        afterQueue = fresh.afterQueue
        appearance = fresh.appearance
        accent = fresh.accent
        autoResumeQueue = fresh.autoResumeQueue
        assistantEnabled = fresh.assistantEnabled
    }

    /// Reads a flag that may also come from the command line (`-key YES`), where it is a string.
    private static func flag(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func number(_ defaults: UserDefaults, _ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
