import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            DownloadSettings()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            MusicSettings()
                .tabItem { Label("Music", systemImage: "music.note.list") }
            PlayerSettings()
                .tabItem { Label("Player", systemImage: "play.rectangle") }
            NetworkSettings()
                .tabItem { Label("Network", systemImage: "network") }
            ComponentsSettings()
                .tabItem { Label("Components", systemImage: "shippingbox") }
            IntegrationSettings()
                .tabItem { Label("Integration", systemImage: "puzzlepiece.extension") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 760, height: 580)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show icon in the menu bar", isOn: $prefs.showMenuBarExtra)
                    .onChange(of: prefs.showMenuBarExtra) { _, _ in WindowManager.shared.applyMinimizeBehaviour() }
                Toggle("Minimize to the menu bar (yellow button and closing hide the Dock icon)", isOn: $prefs.minimizeToMenuBar)
                    .disabled(!prefs.showMenuBarExtra)
                    .onChange(of: prefs.minimizeToMenuBar) { _, _ in WindowManager.shared.applyMinimizeBehaviour() }
                Toggle("Show download progress in percent next to the icon", isOn: $prefs.menuBarShowsPercent)
                    .disabled(!prefs.showMenuBarExtra)
            }
            Section("Behaviour") {
                Toggle("Suggest links from the clipboard", isOn: $prefs.watchClipboard)
                Toggle("Analyze links automatically when pasted", isOn: $prefs.autoAnalyze)
                Toggle("Smart commands with Apple Intelligence (if available)", isOn: $prefs.assistantEnabled)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Notifications") {
                Toggle("Notify when a download finishes", isOn: $prefs.notifyOnFinish)
                Toggle("Play a sound", isOn: $prefs.playSound)
                Toggle("Keep the Mac awake while downloading", isOn: $prefs.keepAwake)
                Picker("When the queue is finished", selection: $prefs.afterQueue) {
                    ForEach(AfterQueueAction.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DownloadSettings: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Download folder") {
                    HStack {
                        Text((prefs.downloadFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") {
                            if let folder = Finder.chooseFolder(startingAt: prefs.downloadFolder) { prefs.downloadFolder = folder }
                        }
                        Button {
                            Finder.openFolder(prefs.downloadFolder)
                        } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("Default quality") {
                Picker("Preset", selection: $prefs.defaultOptions.preset) {
                    Section("Video") { ForEach(QualityPreset.videoPresets) { Text($0.title).tag($0) } }
                    Section("Audio") { ForEach(QualityPreset.audioPresets) { Text($0.title).tag($0) } }
                }
                Text(prefs.defaultOptions.preset.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Section("Default options") {
                DownloadOptionsForm(options: $prefs.defaultOptions, showFolder: false)
            }
            Section("Queue") {
                Stepper("Parallel downloads: \(prefs.maxConcurrent)", value: $prefs.maxConcurrent, in: 1...8)
                Stepper("Automatic retries on network errors: \(prefs.autoRetry)", value: $prefs.autoRetry, in: 0...5)
                Toggle("Resume unfinished downloads on launch", isOn: $prefs.autoResumeQueue)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NetworkSettings: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Use cookies from", selection: $prefs.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Cookies")
            } footer: {
                Text("Needed for age-restricted or members-only videos and when YouTube asks “Sign in to confirm you're not a bot”. You must be signed in to the site in that browser. Safari requires Full Disk Access for Lasso (System Settings › Privacy & Security).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Speed") {
                LabeledContent("Speed limit") {
                    TextField("unlimited, e.g. 5M or 800K", text: $prefs.rateLimit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Stepper("Parallel fragments (Turbo for HLS/DASH): \(prefs.concurrentFragments)", value: $prefs.concurrentFragments, in: 1...16)
            }
            Section("Connection") {
                LabeledContent("Proxy") {
                    TextField("e.g. socks5://127.0.0.1:1080", text: $prefs.proxy)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Toggle("Force IPv4", isOn: $prefs.forceIPv4)
            }
        }
        .formStyle(.grouped)
    }
}

struct ComponentsSettings: View {
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        Form {
            Section {
                ForEach(HelperTool.allCases) { tool in
                    ComponentRow(tool: tool)
                }
            } header: {
                Text("Installed components")
            } footer: {
                Text("All components ship inside Lasso and are installed into ~/Library/Application Support/Lasso. Nothing is installed system-wide and no administrator password is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Update yt-dlp automatically (daily)", isOn: $prefs.autoUpdateYTDLP)
                Toggle("Use the nightly channel (fixes for site changes arrive faster)", isOn: $prefs.useNightly)
                HStack {
                    Button {
                        Task { await tools.updateYTDLP() }
                    } label: {
                        Label("Update yt-dlp now", systemImage: "arrow.down.circle")
                    }
                    .disabled(tools.busyTool != nil)
                    Button {
                        Task { await tools.refreshVersions() }
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    if tools.busyTool != nil { ProgressView().controlSize(.small) }
                }
                if let last = prefs.lastUpdateCheck {
                    Text("Last checked: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Source") {
                Picker("Use components", selection: $prefs.toolSource) {
                    ForEach(ToolSource.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: prefs.toolSource) { _, _ in Task { await tools.refreshVersions() } }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ComponentRow: View {
    let tool: HelperTool
    @EnvironmentObject private var tools: ToolManager

    var body: some View {
        let status = tools.status[tool]
        HStack(spacing: 12) {
            Image(systemName: tool.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tool.displayName).font(.headline)
                    if let version = status?.version {
                        Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                if let path = status?.path {
                    Text((path as NSString).abbreviatingWithTildeInPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if tools.busyTool == tool {
                ProgressView().controlSize(.small)
            } else if status?.version != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: tool.isRequired ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tool.isRequired ? Color.red : Color.orange)
            }
            Button(tool == .ytdlp ? "Update" : "Reinstall") {
                Task { await tools.reinstall(tool) }
            }
            .disabled(tools.busyTool != nil)
        }
        .padding(.vertical, 2)
    }
}

private struct IntegrationSettings: View {
    private let bookmarklet = "javascript:location.href='lasso://download?url='+encodeURIComponent(location.href)"
    private let bookmarkletInstant = "javascript:location.href='lasso://download?mode=instant&url='+encodeURIComponent(location.href)"

    var body: some View {
        Form {
            Section {
                bookmarkletRow(title: "Open in Lasso", code: bookmarklet)
                bookmarkletRow(title: "Download immediately", code: bookmarkletInstant)
            } header: {
                Text("Browser bookmarklets")
            } footer: {
                Text("Create a bookmark in Safari, Chrome, Edge or Firefox and paste the code as its address. One click on the bookmark sends the current page to Lasso.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Services menu") {
                    Text("Select a link in any app › right-click › Services › “Download with Lasso”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Keyboard") {
                    Text("⇧⌘V downloads every link on the clipboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("URL scheme") {
                    Text("lasso://download?url=…  (mode=instant | audio)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Shortcuts / Terminal") {
                    Text("open \"lasso://download?mode=instant&url=https://…\"")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Other ways to add links")
            }
        }
        .formStyle(.grouped)
    }

    private func bookmarkletRow(title: LocalizedStringKey, code: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(code)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Copy") {
                    Finder.copy(code)
                    ToastCenter.shared.show(String(localized: "Bookmarklet copied"), symbol: "doc.on.doc")
                }
            }
        }
    }
}

private struct AdvancedSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var library: LibraryStore
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                TextField("e.g. --write-comments --no-mtime", text: $prefs.customArguments, axis: .vertical)
                    .font(.callout.monospaced())
                    .lineLimit(2...4)
            } header: {
                Text("Additional yt-dlp arguments")
            } footer: {
                Text("Passed to every download. See the yt-dlp documentation for all options.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("File names") {
                Toggle("Only ASCII characters, no spaces", isOn: $prefs.restrictFilenames)
                Stepper("Maximum file name length: \(prefs.trimFilenames)", value: $prefs.trimFilenames, in: 40...200, step: 10)
            }
            Section("Maintenance") {
                HStack {
                    Button("Open logs folder") { Finder.openFolder(AppPaths.logs.path) }
                    Button("Delete logs") {
                        if let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.logs, includingPropertiesForKeys: nil) {
                            for file in files { try? FileManager.default.removeItem(at: file) }
                        }
                        ToastCenter.shared.show(String(localized: "Logs deleted"), symbol: "trash")
                    }
                    Button("Open support folder") { Finder.openFolder(AppPaths.support.path) }
                }
                Button("Reset all settings…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { prefs.resetToDefaults() }
                    }
            }
            Section("About") {
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))")
                }
                Text("Lasso is a native SwiftUI app based on MacYTDL by section83. Powered by yt-dlp, FFmpeg and Deno.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Mode", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent colour") {
                    HStack(spacing: 10) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                prefs.accent = choice
                            } label: {
                                Circle()
                                    .fill(choice.color ?? Color(nsColor: .controlAccentColor))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(prefs.accent == choice ? 0.9 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(choice.title)
                        }
                    }
                }
                Picker("Surfaces", selection: $prefs.glassStyle) {
                    ForEach(GlassStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Background glow") {
                    Slider(value: $prefs.ambientIntensity, in: 0...1.5) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "circle.slash")
                    } maximumValueLabel: {
                        Image(systemName: "sun.max")
                    }
                    .frame(width: 260)
                }
            }
            Section("Layout") {
                Toggle("Compact layout (more on screen)", isOn: $prefs.compactMode)
                Toggle("Show thumbnails in lists", isOn: $prefs.showThumbnails)
            }
            Section {
                Toggle("Music & Playlists", isOn: $prefs.showMusicPage)
                Toggle("Search", isOn: $prefs.showSearchPage)
                Toggle("Subscriptions", isOn: $prefs.showSubscriptionsPage)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Hide pages you don't use. New Download, Downloads and Library are always shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MusicSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var secret = Keychain.read("spotify-client-secret") ?? ""
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("Music downloads") {
                Picker("Default format", selection: $prefs.musicPreset) {
                    ForEach(QualityPreset.audioPresets) { Text($0.title).tag($0) }
                }
                Toggle("Put albums and playlists in their own folder", isOn: $prefs.musicFolderPerCollection)
            }
            Section {
                TextField("Client ID", text: $prefs.spotifyClientID)
                SecureField("Client secret", text: $secret)
                    .onSubmit { Keychain.write("spotify-client-secret", secret) }
                HStack {
                    Button("Save & test") {
                        Keychain.write("spotify-client-secret", secret)
                        testResult = String(localized: "Testing…")
                        Task {
                            if let credentials = SpotifyAPI.credentials, (try? await SpotifyAPI.token(credentials)) != nil {
                                testResult = String(localized: "✓ Works – long playlists are loaded completely.")
                            } else {
                                testResult = String(localized: "✗ Not accepted – check ID and secret.")
                            }
                        }
                    }
                    Link("Create a free key…", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Spotify API (optional)")
            } footer: {
                Text("Without a key Lasso reads up to 100 songs per playlist from Spotify's public page. With your own free key (developer.spotify.com › Create app) it loads playlists of any length plus album and year for every song. The secret is stored in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("How it works") {
                Text("Spotify streams are DRM-protected and can't be downloaded. Lasso reads the song list from Spotify, finds every song on YouTube Music (checking the length), downloads the audio and writes Spotify's title, artists, album, track number and a square cover into the file.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { Keychain.write("spotify-client-secret", secret) }
    }
}

private struct PlayerSettings: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Play in Lasso (double-click in the library)", isOn: $prefs.playInApp)
                Toggle("Continue with the next item automatically", isOn: $prefs.autoplayNext)
                Toggle("Remember the position of long videos", isOn: $prefs.rememberPosition)
            }
            Section("Good to know") {
                Label("Media keys, Control Center and AirPods controls work while Lasso plays.", systemImage: "playpause")
                Label("Videos open in their own window with Picture in Picture and full screen.", systemImage: "pip")
                Label("WebM, MKV and Opus can't be played by macOS – Lasso converts them to MP4/M4A with one click.", systemImage: "arrow.triangle.2.circlepath")
                Label("Shortcuts: ⌥Space play/pause · ⌥⌘← → previous/next · ⇧⌘P player window", systemImage: "keyboard")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
