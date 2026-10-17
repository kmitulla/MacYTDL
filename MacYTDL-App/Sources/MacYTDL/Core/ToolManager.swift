import Foundation
import Darwin

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ensure(base.appendingPathComponent("MacYTDL", isDirectory: true))
    }
    static var bin: URL { ensure(support.appendingPathComponent("bin", isDirectory: true)) }
    static var logs: URL { ensure(support.appendingPathComponent("Logs", isDirectory: true)) }
    static var archives: URL { ensure(support.appendingPathComponent("Archives", isDirectory: true)) }
    static var queueFile: URL { support.appendingPathComponent("queue.json") }
    static var libraryFile: URL { support.appendingPathComponent("library.json") }
    static var subscriptionsFile: URL { support.appendingPathComponent("subscriptions.json") }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum HelperTool: String, CaseIterable, Identifiable {
    case ytdlp = "yt-dlp"
    case ffmpeg
    case ffprobe
    case deno

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytdlp: return "yt-dlp"
        case .ffmpeg: return "FFmpeg"
        case .ffprobe: return "FFprobe"
        case .deno: return "Deno"
        }
    }

    var purpose: String {
        switch self {
        case .ytdlp: return String(localized: "Download engine for 1,800+ websites")
        case .ffmpeg: return String(localized: "Merges, converts and cuts media")
        case .ffprobe: return String(localized: "Analyzes media streams")
        case .deno: return String(localized: "JavaScript runtime required by YouTube")
        }
    }

    var symbol: String {
        switch self {
        case .ytdlp: return "arrow.down.app"
        case .ffmpeg: return "film.stack"
        case .ffprobe: return "waveform.badge.magnifyingglass"
        case .deno: return "curlybraces.square"
        }
    }

    var versionArguments: [String] {
        switch self {
        case .ytdlp: return ["--version"]
        case .ffmpeg, .ffprobe: return ["-version"]
        case .deno: return ["--version"]
        }
    }

    var isRequired: Bool { self != .deno }
}

struct ToolStatus: Equatable {
    var path: String?
    var version: String?
    var isManaged: Bool
}

/// Installs, locates and updates the helper programs (yt-dlp, ffmpeg, ffprobe, deno).
@MainActor
final class ToolManager: ObservableObject {
    static let shared = ToolManager()

    @Published private(set) var status: [HelperTool: ToolStatus] = [:]
    @Published private(set) var isPreparing = false
    @Published private(set) var busyTool: HelperTool?
    @Published var lastMessage: String?

    private let prefs = Preferences.shared

    var ytdlpPath: String? { path(for: .ytdlp) }
    var isReady: Bool { ytdlpPath != nil }

    var missingRequiredTools: [HelperTool] {
        HelperTool.allCases.filter { $0.isRequired && path(for: $0) == nil }
    }

    /// Environment for child processes: our tools come first in PATH so yt-dlp finds ffmpeg and deno.
    var environment: [String: String] {
        var extra = [AppPaths.bin.path]
        if let ffmpeg = path(for: .ffmpeg) { extra.append((ffmpeg as NSString).deletingLastPathComponent) }
        if let deno = path(for: .deno) { extra.append((deno as NSString).deletingLastPathComponent) }
        var seen = Set<String>()
        return ProcessRunner.defaultEnvironment(extraPath: extra.filter { seen.insert($0).inserted })
    }

    func path(for tool: HelperTool) -> String? {
        if prefs.toolSource == .system, let system = Self.systemPath(for: tool) {
            return system
        }
        let managed = AppPaths.bin.appendingPathComponent(tool.rawValue).path
        if FileManager.default.isExecutableFile(atPath: managed) { return managed }
        return Self.systemPath(for: tool)
    }

    nonisolated static func systemPath(for tool: HelperTool) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = "\(dir)/\(tool.rawValue)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Bundled tools

    nonisolated private static var bundledDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("Tools", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    nonisolated private static var bundledManifest: [String: String] {
        guard let dir = bundledDirectory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return json
    }

    nonisolated private static var installedManifestURL: URL { AppPaths.bin.appendingPathComponent("manifest.json") }

    nonisolated private static var installedManifest: [String: String] {
        get {
            guard let data = try? Data(contentsOf: installedManifestURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
            return json
        }
        set {
            if let data = try? JSONSerialization.data(withJSONObject: newValue, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: installedManifestURL, options: .atomic)
            }
        }
    }

    /// Copies the tools shipped inside the app into Application Support (writable, so yt-dlp can update
    /// itself). Runs off the main thread - the first copy moves a few hundred MB.
    func installBundledToolsIfNeeded() async {
        let errors = await Task.detached(priority: .userInitiated) { Self.copyBundledTools() }.value
        if let first = errors.first { lastMessage = first }
    }

    nonisolated private static func copyBundledTools() -> [String] {
        guard let dir = bundledDirectory else { return [] }
        let bundled = bundledManifest
        var installed = installedManifest
        var errors: [String] = []
        let fm = FileManager.default
        for tool in HelperTool.allCases {
            let source = dir.appendingPathComponent(tool.rawValue)
            guard fm.fileExists(atPath: source.path) else { continue }
            // The DMG ships Apple Silicon helpers; Intel Macs download their own (see healMissingTools).
            guard MachO.runsOnThisMac(source) else { continue }
            let destination = AppPaths.bin.appendingPathComponent(tool.rawValue)
            let bundledVersion = bundled[tool.rawValue] ?? "0"
            let installedVersion = installed[tool.rawValue]
            let exists = fm.isExecutableFile(atPath: destination.path)
            var needsCopy = !exists
            if exists, let installedVersion {
                if tool == .ytdlp {
                    // yt-dlp versions are dates (2026.08.19) - only replace with something newer.
                    needsCopy = bundledVersion.compare(installedVersion, options: .numeric) == .orderedDescending
                } else {
                    needsCopy = bundledVersion != installedVersion
                }
            } else if exists {
                needsCopy = true
            }
            guard needsCopy else { continue }
            do {
                let temp = AppPaths.bin.appendingPathComponent(".\(tool.rawValue).tmp")
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: source, to: temp)
                makeRunnable(temp)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: destination)
                }
                makeRunnable(destination)
                installed[tool.rawValue] = bundledVersion
            } catch {
                errors.append(String(localized: "Could not install \(tool.displayName): \(error.localizedDescription)"))
            }
        }
        installedManifest = installed
        return errors
    }

    nonisolated static func makeRunnable(_ url: URL) {
        chmod(url.path, 0o755)
        removexattr(url.path, "com.apple.quarantine", 0)
        removexattr(url.path, "com.apple.provenance", 0)
    }

    // MARK: Lifecycle

    func prepare() async {
        isPreparing = true
        await installBundledToolsIfNeeded()
        Self.ensureCertificateBundle()
        await refreshVersions()
        isPreparing = false
        if !DemoMode.isActive { await healMissingTools() }
        if prefs.autoUpdateYTDLP, prefs.toolSource == .managed, !DemoMode.isActive {
            let last = prefs.lastUpdateCheck ?? .distantPast
            if Date().timeIntervalSince(last) > 20 * 3600 {
                Task { await self.updateYTDLP(silent: true) }
            }
        }
    }

    func refreshVersions() async {
        var result: [HelperTool: ToolStatus] = [:]
        await withTaskGroup(of: (HelperTool, ToolStatus).self) { group in
            for tool in HelperTool.allCases {
                let path = self.path(for: tool)
                let managed = path?.hasPrefix(AppPaths.bin.path) ?? false
                let env = self.environment
                group.addTask {
                    guard let path else { return (tool, ToolStatus(path: nil, version: nil, isManaged: false)) }
                    let output = await ProcessRunner.run(path, tool.versionArguments, environment: env, timeout: 60)
                    let version = Self.parseVersion(tool: tool, output: output.stdout + "\n" + output.stderr, status: output.status)
                    return (tool, ToolStatus(path: path, version: version, isManaged: managed))
                }
            }
            for await (tool, status) in group { result[tool] = status }
        }
        status = result
    }

    nonisolated static func parseVersion(tool: HelperTool, output: String, status: Int32) -> String? {
        guard status == 0 else { return nil }
        let firstLine = output.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch tool {
        case .ytdlp:
            return firstLine.isEmpty ? nil : firstLine
        case .ffmpeg, .ffprobe:
            // "ffmpeg version 9.0.2 Copyright ..." / "ffmpeg version N-12345-gabc ..."
            let parts = firstLine.split(separator: " ")
            if let idx = parts.firstIndex(of: "version"), idx + 1 < parts.count { return String(parts[idx + 1]) }
            return firstLine.isEmpty ? nil : firstLine
        case .deno:
            // "deno 2.5.4 (stable, release, aarch64-apple-darwin)"
            let parts = firstLine.split(separator: " ")
            return parts.count > 1 ? String(parts[1]) : (firstLine.isEmpty ? nil : firstLine)
        }
    }

    /// Downloads helpers that are missing or can't run here (e.g. on Intel Macs, or after the user deleted them).
    func healMissingTools() async {
        guard prefs.toolSource == .managed else { return }
        let broken = [HelperTool.ffmpeg, .ffprobe, .deno].filter { status[$0]?.version == nil }
        guard !broken.isEmpty else { return }
        lastMessage = String(localized: "Setting up components for this Mac…")
        for tool in broken {
            await reinstall(tool)
        }
    }

    /// Static FFmpeg builds need a PEM file with root certificates (normally /etc/ssl/cert.pem).
    nonisolated static var certificateBundle: String? {
        if FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") { return "/etc/ssl/cert.pem" }
        let own = AppPaths.support.appendingPathComponent("cacert.pem").path
        return FileManager.default.fileExists(atPath: own) ? own : nil
    }

    static func ensureCertificateBundle() {
        guard certificateBundle == nil else { return }
        let target = AppPaths.support.appendingPathComponent("cacert.pem")
        Task.detached {
            let result = await ProcessRunner.run("/usr/bin/security",
                                                 ["find-certificate", "-a", "-p",
                                                  "/System/Library/Keychains/SystemRootCertificates.keychain"],
                                                 timeout: 60)
            if result.status == 0, !result.stdout.isEmpty {
                try? (result.stdout + "\n").write(to: target, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Updates

    @discardableResult
    func updateYTDLP(silent: Bool = false) async -> Bool {
        guard let path = path(for: .ytdlp), path.hasPrefix(AppPaths.bin.path) else {
            if !silent { lastMessage = String(localized: "yt-dlp is managed outside MacYTDL (e.g. Homebrew). Update it there.") }
            return false
        }
        busyTool = .ytdlp
        defer { busyTool = nil }
        let channel = prefs.useNightly ? "nightly" : "stable"
        let result = await ProcessRunner.run(path, ["--update-to", channel], environment: environment, timeout: 240)
        prefs.lastUpdateCheck = Date()
        let before = status[.ytdlp]?.version
        await refreshVersions()
        let after = status[.ytdlp]?.version
        if let after {
            var installed = Self.installedManifest
            installed[HelperTool.ytdlp.rawValue] = after
            Self.installedManifest = installed
        }
        let combined = result.stdout + "\n" + result.stderr
        if result.status == 0 {
            if before != after, let after {
                lastMessage = String(localized: "yt-dlp updated to \(after).")
            } else if !silent {
                lastMessage = String(localized: "yt-dlp is up to date (\(after ?? "?")).")
            }
            return true
        } else if !silent {
            let reason = combined.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init) ?? combined
            lastMessage = String(localized: "yt-dlp update failed: \(reason)")
        }
        return false
    }

    /// Downloads a fresh copy of ffmpeg/ffprobe/deno for this Mac's architecture.
    @discardableResult
    func reinstall(_ tool: HelperTool) async -> Bool {
        if tool == .ytdlp { return await updateYTDLP() }
        busyTool = tool
        defer { busyTool = nil }
        let arm = Self.isAppleSilicon
        var urls: [URL] = []
        switch tool {
        case .deno:
            let arch = arm ? "aarch64" : "x86_64"
            urls = [URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-\(arch)-apple-darwin.zip")!]
        case .ffmpeg, .ffprobe:
            let arch = arm ? "arm64" : "amd64"
            urls = [URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/\(tool.rawValue).zip")!]
        case .ytdlp:
            break
        }
        for url in urls {
            for attempt in 1...3 {
                do {
                    try await downloadZip(url, extracting: tool.rawValue)
                    var installed = Self.installedManifest
                    installed[tool.rawValue] = "downloaded-\(Int(Date().timeIntervalSince1970))"
                    Self.installedManifest = installed
                    await refreshVersions()
                    lastMessage = String(localized: "\(tool.displayName) was reinstalled.")
                    return true
                } catch {
                    lastMessage = String(localized: "Download of \(tool.displayName) failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }
        return false
    }

    private func downloadZip(_ url: URL, extracting name: String) async throws {
        let (tempFile, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("macytdl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zip = workDir.appendingPathComponent("tool.zip")
        try FileManager.default.moveItem(at: tempFile, to: zip)
        let unzip = await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, workDir.path], timeout: 300)
        guard unzip.status == 0 else { throw URLError(.cannotDecodeContentData) }
        guard let found = FileManager.default.enumerator(at: workDir, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == name }) else {
            throw URLError(.fileDoesNotExist)
        }
        let destination = AppPaths.bin.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: found, to: destination)
        Self.makeRunnable(destination)
    }

    nonisolated static var isAppleSilicon: Bool {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        if machine.hasPrefix("arm64") { return true }
        // Running under Rosetta?
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 { return translated == 1 }
        return false
    }
}

/// Minimal Mach-O header reader to check whether a binary contains a slice for this Mac.
enum MachO {
    static let cpuARM64: UInt32 = 0x0100_000C
    static let cpuX86_64: UInt32 = 0x0100_0007

    static func architectures(of url: URL) -> Set<UInt32> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return [] }
        let bytes = [UInt8](header)
        func be(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func le(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        let magicBE = be(0)
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF { // fat (32/64-bit offsets)
            let count = Int(be(4))
            let entrySize = magicBE == 0xCAFE_BABE ? 20 : 32
            var result = Set<UInt32>()
            for i in 0..<min(count, 16) { result.insert(be(8 + i * entrySize)) }
            return result
        }
        let magicLE = le(0)
        if magicLE == 0xFEED_FACF || magicLE == 0xFEED_FACE { return [le(4)] }
        return []
    }

    static func runsOnThisMac(_ url: URL) -> Bool {
        let archs = architectures(of: url)
        guard !archs.isEmpty else { return true } // not Mach-O (script?) - let it try
        return archs.contains(ToolManager.isAppleSilicon ? cpuARM64 : cpuX86_64)
    }
}
