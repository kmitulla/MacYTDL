import SwiftUI

/// State of the "New Download" page (kept alive while switching sections).
@MainActor
final class HomeModel: ObservableObject {
    static let shared = HomeModel()

    @Published var urlText = ""
    @Published var info: MediaInfo?
    @Published var isAnalyzing = false
    @Published var error: String?
    @Published var options = Preferences.shared.newOptions()
    @Published var selectedEntries: Set<String> = []
    @Published var smartCommand = ""
    @Published var smartSummary: String?
    @Published var isInterpreting = false
    @Published var aiSummary: String?
    @Published var batchURLs: [String] = []
    @Published var batchPreset: QualityPreset = Preferences.shared.defaultOptions.preset

    private var analysisTask: Task<Void, Never>?

    var hasVideoAndPlaylist: Bool { URLTools.hasVideoAndPlaylist(urlText) }

    func analyze(_ raw: String? = nil, playlist: Bool? = nil) {
        if let raw { urlText = raw }
        let urls = URLTools.extractURLs(from: urlText)
        if urls.count > 1 {
            showBatch(urls)
            return
        }
        let url = URLTools.normalize(urls.first ?? urlText)
        guard URLTools.isLikelyMediaURL(url) else {
            error = String(localized: "Please paste a valid link (https://…).")
            info = nil
            return
        }
        urlText = url
        batchURLs = []
        error = nil
        aiSummary = nil
        smartSummary = nil
        isAnalyzing = true
        let keepOptions = info != nil && playlist != nil
        if !keepOptions { options = Preferences.shared.newOptions() }
        let wantsPlaylist = playlist ?? !URLTools.hasVideoAndPlaylist(url)
        options.downloadPlaylist = wantsPlaylist
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                let result = try await MetadataService.fetch(url: url, playlist: wantsPlaylist)
                guard !Task.isCancelled else { return }
                self.info = result
                self.selectedEntries = Set(result.entries.map(\.id))
                if result.isPlaylist { self.options.downloadPlaylist = true }
                // Don't offer more than the video has.
                if let maxHeight = result.maxHeight, let presetHeight = self.options.preset.maxHeight, presetHeight > maxHeight {
                    self.options.preset = .best
                }
                self.isAnalyzing = false
                if !self.smartCommand.isEmpty { await self.applySmartCommand() }
                if Assistant.shared.onDeviceModelAvailable, Preferences.shared.assistantEnabled,
                   let description = result.description, description.count > 200 {
                    self.aiSummary = await Assistant.shared.summarize(title: result.title, description: description)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.info = nil
                self.error = error.localizedDescription
                self.isAnalyzing = false
            }
        }
    }

    func showBatch(_ urls: [String]) {
        info = nil
        error = nil
        batchURLs = urls
        urlText = ""
    }

    func applySmartCommand() async {
        let text = smartCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isInterpreting = true
        let suggestion = await Assistant.shared.interpret(text)
        isInterpreting = false
        if suggestion.isEmpty {
            smartSummary = String(localized: "I didn't understand that. Try e.g. “only audio as mp3” or “1080p from 1:00 to 2:30”.")
            return
        }
        suggestion.apply(to: &options)
        smartSummary = (suggestion.usedOnDeviceModel ? "✦ " : "") + suggestion.summary
        if suggestion.downloadPlaylist != nil, info != nil, hasVideoAndPlaylist,
           suggestion.downloadPlaylist != info?.isPlaylist {
            analyze(urlText, playlist: suggestion.downloadPlaylist)
        }
    }

    func startDownload() {
        guard let info else { return }
        var opts = options
        if info.isPlaylist {
            opts.downloadPlaylist = true
            if selectedEntries.count < info.entries.count {
                let indices = info.entries.filter { selectedEntries.contains($0.id) }.map { String($0.index) }
                opts.playlistItems = indices.joined(separator: ",")
            } else {
                opts.playlistItems = ""
            }
        } else {
            opts.downloadPlaylist = false
        }
        DownloadManager.shared.add(url: urlText, options: opts, info: info)
        ToastCenter.shared.show(String(localized: "“\(info.title)” added to downloads"), symbol: "arrow.down.circle.fill")
        reset()
    }

    func startBatch() {
        DownloadManager.shared.addBatch(batchURLs, preset: batchPreset)
        ToastCenter.shared.show(String(localized: "Added \(batchURLs.count) download(s)"), symbol: "arrow.down.circle.fill")
        batchURLs = []
    }

    func reset() {
        analysisTask?.cancel()
        info = nil
        error = nil
        urlText = ""
        smartCommand = ""
        smartSummary = nil
        aiSummary = nil
        isAnalyzing = false
        options = Preferences.shared.newOptions()
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: HomeModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                URLBar()
                SmartCommandBar()
                if let suggestion = appState.clipboardSuggestion, model.info == nil, !model.isAnalyzing {
                    ClipboardChip(url: suggestion)
                }
                if !tools.isPreparing && !tools.isReady {
                    MissingToolsCard()
                }
                if model.isAnalyzing {
                    AnalyzingCard()
                } else if let error = model.error {
                    ErrorCard(message: error) { model.analyze() }
                } else if !model.batchURLs.isEmpty {
                    BatchCard()
                } else if let info = model.info {
                    PreviewCard(info: info)
                } else {
                    TipsGrid()
                }
                if !downloads.activeTasks.isEmpty {
                    ActiveMiniList()
                }
                if model.info == nil && !library.items.isEmpty {
                    RecentStrip()
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: model.info)
        .animation(.easeInOut(duration: 0.25), value: model.isAnalyzing)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [Color.primary, Color.accentColor], startPoint: .leading, endPoint: .trailing)
                )
            Text("Paste a link from YouTube, Vimeo, TikTok, Instagram, SoundCloud, ARD, ZDF and 1,800+ other sites.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: LocalizedStringKey {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning! What would you like to save?"
        case 12..<18: return "Hello! What would you like to save?"
        default: return "Good evening! What would you like to save?"
        }
    }
}

// MARK: - URL bar

private struct URLBar: View {
    @EnvironmentObject private var model: HomeModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var prefs: Preferences
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Paste or drop a link…", text: $model.urlText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { model.analyze() }
                .onChange(of: model.urlText) { old, new in
                    // Auto-analyze when a link was pasted (big jump in length).
                    if prefs.autoAnalyze, !model.isAnalyzing, new.count - old.count > 8, URLTools.isLikelyMediaURL(new) {
                        model.analyze()
                    }
                }
            if !model.urlText.isEmpty {
                Button {
                    model.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Button {
                if let text = NSPasteboard.general.string(forType: .string) {
                    model.analyze(text)
                }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .glassButtonStyle()
            .controlSize(.large)

            Button {
                model.analyze()
            } label: {
                Label("Analyze", systemImage: "sparkle.magnifyingglass")
                    .fontWeight(.semibold)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.urlText.trimmingCharacters(in: .whitespaces).isEmpty || model.isAnalyzing)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassCapsule(interactive: true)
        .shadow(color: Color.accentColor.opacity(focused ? 0.25 : 0.08), radius: focused ? 18 : 10, y: 4)
        .onAppear { focused = model.info == nil }
        .onChange(of: appState.focusURLField) { _, _ in focused = true }
    }
}

private struct SmartCommandBar: View {
    @EnvironmentObject private var model: HomeModel
    @EnvironmentObject private var assistant: Assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(
                        LinearGradient(colors: [.pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                TextField("Describe what you want, e.g. “only audio as MP3 from 1:20 to 3:00 without sponsors”",
                          text: $model.smartCommand)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.applySmartCommand() } }
                if model.isInterpreting {
                    ProgressView().controlSize(.small)
                } else if !model.smartCommand.isEmpty {
                    Button("Apply") { Task { await model.applySmartCommand() } }
                        .glassButtonStyle()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassCapsule(interactive: true)

            HStack(spacing: 6) {
                if let summary = model.smartSummary {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(summary)
                } else if assistant.onDeviceModelAvailable {
                    Image(systemName: "apple.intelligence")
                    Text("Powered by Apple Intelligence – on-device and private.")
                } else {
                    Image(systemName: "text.bubble")
                    Text("Understands German and English – works offline.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
        }
    }
}

private struct ClipboardChip: View {
    var url: String
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeModel
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Link on the clipboard")
                    .font(.callout.weight(.semibold))
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Preview") {
                model.analyze(url)
                appState.clipboardSuggestion = nil
            }
            .glassButtonStyle()
            Button("Download now") {
                downloads.quickDownload(url)
                appState.dismissClipboardSuggestion()
                ToastCenter.shared.show(String(localized: "Added to downloads"), symbol: "arrow.down.circle.fill")
            }
            .glassButtonStyle(prominent: true)
            Button {
                appState.dismissClipboardSuggestion()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16, tint: .accentColor)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - States

private struct AnalyzingCard: View {
    @EnvironmentObject private var model: HomeModel

    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 280, height: 158)
                .overlay(ProgressView().controlSize(.large))
            VStack(alignment: .leading, spacing: 12) {
                Text("Analyzing link…")
                    .font(.title3.weight(.semibold))
                Text(model.urlText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                SlimProgressBar(value: 0, indeterminate: true)
                    .frame(maxWidth: 320)
                Text("Fetching title, qualities and file sizes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .card(cornerRadius: 22, padding: 18)
    }
}

private struct ErrorCard: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("That didn't work")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Try again", action: retry).glassButtonStyle(prominent: true)
                    SettingsLink { Text("Open Settings") }.glassButtonStyle()
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .card(cornerRadius: 20, padding: 18)
    }
}

private struct MissingToolsCard: View {
    @EnvironmentObject private var tools: ToolManager

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill").font(.title).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Components missing").font(.headline)
                Text("MacYTDL needs yt-dlp and FFmpeg. They are normally included – reinstall them under Settings › Components.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Text("Components…") }.glassButtonStyle(prominent: true)
        }
        .card(cornerRadius: 20)
    }
}

private struct BatchCard: View {
    @EnvironmentObject private var model: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "\(model.batchURLs.count) links detected", subtitle: "Download them all at once", symbol: "square.stack.3d.down.right")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.batchURLs, id: \.self) { url in
                        HStack {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            Text(url).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                model.batchURLs.removeAll { $0 == url }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                Picker("Quality", selection: $model.batchPreset) {
                    Section("Video") { ForEach(QualityPreset.videoPresets) { Text($0.title).tag($0) } }
                    Section("Audio") { ForEach(QualityPreset.audioPresets) { Text($0.title).tag($0) } }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button("Cancel") { model.batchURLs = [] }.glassButtonStyle()
                Button {
                    model.startBatch()
                } label: {
                    Label("Download all", systemImage: "arrow.down.circle.fill").fontWeight(.semibold)
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.large)
            }
        }
        .card(cornerRadius: 22, padding: 20)
    }
}

// MARK: - Preview

private struct PreviewCard: View {
    let info: MediaInfo
    @EnvironmentObject private var model: HomeModel
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showMore = false
    @State private var mediaKind: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.hasVideoAndPlaylist {
                playlistChoice
            }
            Divider().opacity(0.5)
            formatPicker
            optionsSection
            if info.isPlaylist && !info.entries.isEmpty {
                PlaylistPicker(info: info)
            }
            footer
        }
        .card(cornerRadius: 24, padding: 22)
        .onAppear { mediaKind = model.options.preset.isAudio ? 1 : 0 }
        .onChange(of: model.options.preset) { _, preset in mediaKind = preset.isAudio ? 1 : 0 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            Thumbnail(url: info.thumbnail, cornerRadius: 16, symbol: info.isPlaylist ? "list.and.film" : "play.rectangle.fill")
                .frame(width: 300, height: 169)
                .overlay(alignment: .bottomTrailing) {
                    if info.isPlaylist {
                        Pill(text: String(localized: "\(info.entries.count) videos"), symbol: "list.bullet", color: .white)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(8)
                    } else if let duration = info.duration {
                        Text(Format.duration(duration))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if let uploader = info.uploader {
                        Label(uploader, systemImage: "person.crop.circle").lineLimit(1)
                    }
                    if let views = info.viewCount {
                        Text("·")
                        Text("\(Format.count(views)) views")
                    }
                    if let date = info.uploadDate {
                        Text("·")
                        Text(date, style: .date)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                FlowRow {
                    if let extractor = info.extractor {
                        Pill(text: extractor, symbol: "globe")
                    }
                    if let maxHeight = info.maxHeight {
                        Pill(text: maxHeight >= 2160 ? "4K" : "\(maxHeight)p", symbol: "sparkles.tv", color: .accentColor)
                    }
                    if info.qualities.contains(where: \.hdr) {
                        Pill(text: "HDR", symbol: "sun.max", color: .orange)
                    }
                    if info.chapters > 0 {
                        Pill(text: String(localized: "\(info.chapters) chapters"), symbol: "list.bullet.rectangle")
                    }
                    if !info.hasSubtitles.isEmpty {
                        Pill(text: String(localized: "Subtitles: \(info.hasSubtitles.prefix(4).joined(separator: ", "))"), symbol: "captions.bubble")
                    } else if info.hasAutoSubtitles {
                        Pill(text: String(localized: "Auto subtitles"), symbol: "captions.bubble")
                    }
                    if info.isLive {
                        Pill(text: "LIVE", symbol: "dot.radiowaves.left.and.right", color: .red)
                    }
                }
                if let summary = model.aiSummary {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var playlistChoice: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle.portrait").foregroundStyle(.tint)
            Text("This link belongs to a playlist.")
                .font(.callout)
            Spacer()
            Picker("", selection: Binding(
                get: { info.isPlaylist },
                set: { model.analyze(model.urlText, playlist: $0) }
            )) {
                Text("Only this video").tag(false)
                Text("Whole playlist").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Format").font(.headline)
                Spacer()
                Picker("", selection: $mediaKind) {
                    Label("Video", systemImage: "film").tag(0)
                    Label("Audio", systemImage: "music.note").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: mediaKind) { _, kind in
                    if kind == 1 && !model.options.preset.isAudio { model.options.preset = .audioMP3 }
                    if kind == 0 && model.options.preset.isAudio { model.options.preset = .best }
                }
            }
            let presets = mediaKind == 1 ? QualityPreset.audioPresets : availableVideoPresets
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(presets) { preset in
                    PresetChip(preset: preset, size: info.isPlaylist ? nil : info.estimatedSize(for: preset),
                               selected: model.options.preset == preset) {
                        model.options.preset = preset
                    }
                }
            }
        }
    }

    private var availableVideoPresets: [QualityPreset] {
        guard let maxHeight = info.maxHeight else { return QualityPreset.videoPresets }
        return QualityPreset.videoPresets.filter { preset in
            guard let h = preset.maxHeight else { return true }
            // Keep the preset if it's at most one step above what's available.
            return h <= maxHeight || h == QualityPreset.forHeight(maxHeight).maxHeight
        }.filter { preset in
            guard let h = preset.maxHeight else { return true }
            return h <= max(maxHeight, 480)
        }
    }

    private var optionsSection: some View {
        DisclosureGroup(isExpanded: $showMore) {
            DownloadOptionsForm(options: $model.options, isPlaylist: info.isPlaylist, duration: info.duration)
                .padding(.top, 10)
        } label: {
            HStack {
                Text("More options").font(.headline)
                Text(optionsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { showMore.toggle() } }
        }
    }

    private var optionsSummary: String {
        let o = model.options
        var parts: [String] = []
        if !o.preset.isAudio { parts.append(o.container.title) }
        if o.subtitles { parts.append(String(localized: "Subtitles")) }
        if o.sponsorBlock != .off { parts.append(o.sponsorBlock.title) }
        if o.hasClip { parts.append(String(localized: "Clip \(o.clipStart.isEmpty ? "0:00" : o.clipStart)–\(o.clipEnd.isEmpty ? "…" : o.clipEnd)")) }
        parts.append((o.folder as NSString).abbreviatingWithTildeInPath)
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let size = info.estimatedSize(for: model.options.preset), !info.isPlaylist {
                Label("≈ \(Format.bytes(model.options.hasClip ? clipSize(size) : size))", systemImage: "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let free = Finder.freeDiskSpace {
                Text("\(Format.bytes(free)) free")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if info.isPlaylist || info.extractor?.lowercased().contains("tab") == true {
                Button {
                    subscriptions.add(url: model.urlText, info: info, preset: model.options.preset, onlyNew: true)
                    ToastCenter.shared.show(String(localized: "Subscribed – new videos will be downloaded automatically."), symbol: "dot.radiowaves.left.and.right")
                } label: {
                    Label("Subscribe", systemImage: "bell.badge")
                }
                .glassButtonStyle()
                .controlSize(.large)
                .help("Check this channel/playlist regularly and download new videos automatically")
            }
            Button {
                model.startDownload()
            } label: {
                Label(info.isPlaylist ? String(localized: "Download \(model.selectedEntries.count) videos") : String(localized: "Download"),
                      systemImage: "arrow.down.circle.fill")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(info.isPlaylist && model.selectedEntries.isEmpty)
        }
    }

    private func clipSize(_ size: Int64) -> Int64 {
        guard let duration = info.duration, duration > 0 else { return size }
        let start = Format.parseTimecode(model.options.clipStart) ?? 0
        let end = Format.parseTimecode(model.options.clipEnd) ?? duration
        let fraction = max(0.01, min(1, (end - start) / duration))
        return Int64(Double(size) * fraction)
    }
}

private struct PresetChip: View {
    let preset: QualityPreset
    let size: Int64?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: preset.symbol)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.title).font(.callout.weight(.semibold))
                    Text(size.map { "≈ " + Format.bytes($0) } ?? preset.subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.08 : 0.04)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08))
            }
            .scaleEffect(hovering && !selected ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .animation(.easeOut(duration: 0.2), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preset.subtitle)
    }
}

private struct PlaylistPicker: View {
    let info: MediaInfo
    @EnvironmentObject private var model: HomeModel
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Videos in this playlist").font(.headline)
                Text("\(model.selectedEntries.count) of \(info.entries.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button("All") { model.selectedEntries = Set(info.entries.map(\.id)) }
                Button("None") { model.selectedEntries = [] }
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { entry in
                        PlaylistEntryRow(entry: entry, selected: model.selectedEntries.contains(entry.id)) {
                            if model.selectedEntries.contains(entry.id) {
                                model.selectedEntries.remove(entry.id)
                            } else {
                                model.selectedEntries.insert(entry.id)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private var filtered: [PlaylistEntry] {
        guard !filter.isEmpty else { return info.entries }
        return info.entries.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }
}

private struct PlaylistEntryRow: View {
    let entry: PlaylistEntry
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text("\(entry.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Thumbnail(url: entry.thumbnail, cornerRadius: 6)
                    .frame(width: 64, height: 36)
                Text(entry.title).lineLimit(1)
                Spacer()
                if let duration = entry.duration {
                    Text(Format.duration(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The detailed options (used in the preview and in Settings › Downloads as defaults).
struct DownloadOptionsForm: View {
    @Binding var options: DownloadOptions
    var isPlaylist: Bool = false
    var duration: Double? = nil
    var showFolder: Bool = true

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
            if !options.preset.isAudio {
                GridRow {
                    Text("Container").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $options.container) {
                        ForEach(VideoContainer.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
            }
            GridRow {
                Text("Subtitles").foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Toggle("Download", isOn: $options.subtitles)
                    TextField("de,en", text: $options.subtitleLanguages)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .disabled(!options.subtitles)
                        .help("Language codes, comma separated. “all” for every language.")
                    Toggle("Auto-generated", isOn: $options.autoSubtitles).disabled(!options.subtitles)
                    if !options.preset.isAudio {
                        Toggle("Embed", isOn: $options.embedSubtitles).disabled(!options.subtitles)
                    }
                }
            }
            GridRow {
                Text("Embed").foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Toggle("Cover art", isOn: $options.embedThumbnail)
                    Toggle("Metadata", isOn: $options.embedMetadata)
                    Toggle("Chapters", isOn: $options.embedChapters)
                }
            }
            GridRow {
                Text("SponsorBlock").foregroundStyle(.secondary)
                Picker("", selection: $options.sponsorBlock) {
                    ForEach(SponsorBlockMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            if !isPlaylist {
                GridRow {
                    Text("Clip").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Start (0:00)", text: $options.clipStart)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Text("–")
                        TextField(duration.map { Format.duration($0) } ?? String(localized: "End"), text: $options.clipEnd)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Text("Only download this part (e.g. 1:30 – 2:45)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if isPlaylist {
                GridRow {
                    Text("Playlist").foregroundStyle(.secondary)
                    Toggle("Save in its own folder with numbering", isOn: $options.playlistSubfolder)
                }
            }
            GridRow {
                Text("Extras").foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Toggle("Description (.description)", isOn: $options.writeDescription)
                    Toggle("Thumbnail as JPG", isOn: $options.writeThumbnailFile)
                }
            }
            GridRow {
                Text("File name").foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: $options.filenameStyle) {
                        ForEach(FilenameStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    if options.filenameStyle == .custom {
                        TextField("%(title)s.%(ext)s", text: $options.customTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }
                }
            }
            if showFolder {
                GridRow {
                    Text("Save to").foregroundStyle(.secondary)
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        Text((options.folder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") {
                            if let folder = Finder.chooseFolder(startingAt: options.folder) { options.folder = folder }
                        }
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Empty state & recents

private struct TipsGrid: View {
    @EnvironmentObject private var appState: AppState

    private let tips: [(String, LocalizedStringKey, LocalizedStringKey, SidebarItem?)] = [
        ("hand.draw", "Drag & drop", "Drop links, .webloc or text files anywhere in the window.", nil),
        ("doc.on.clipboard", "Instant from clipboard", "⇧⌘V downloads every link on the clipboard immediately.", nil),
        ("magnifyingglass", "Search YouTube", "Find videos without opening a browser.", .search),
        ("dot.radiowaves.left.and.right", "Subscriptions", "New videos from channels download automatically.", .subscriptions),
        ("sparkles", "Smart commands", "Say what you want – MacYTDL sets the options.", nil),
        ("safari", "Browser button", "Bookmarklet and Services menu send pages straight to MacYTDL.", nil),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
            ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                Button {
                    if let target = tip.3 { appState.selection = target }
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: tip.0)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tip.1).font(.headline)
                            Text(tip.2).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(cornerRadius: 18, padding: 14)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ActiveMiniList: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Running now").font(.headline)
                Spacer()
                Button("Show all") { appState.selection = .queue }
                    .buttonStyle(.link)
            }
            ForEach(downloads.activeTasks.prefix(3)) { task in
                MiniTaskRow(task: task)
            }
        }
        .card(cornerRadius: 20)
    }
}

struct MiniTaskRow: View {
    @ObservedObject var task: DownloadTask

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: task.thumbnail, cornerRadius: 6)
                .frame(width: 56, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.callout.weight(.medium)).lineLimit(1)
                SlimProgressBar(value: task.progress, indeterminate: task.state == .preparing || task.state == .processing)
                Text(task.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(verbatim: "\(Int(task.progress * 100)) %")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct RecentStrip: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recently downloaded").font(.headline)
                Spacer()
                Button("Library") { appState.selection = .library }.buttonStyle(.link)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(library.items.prefix(10)) { item in
                        Button {
                            if item.fileExists { Finder.open(item.filePath) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Thumbnail(url: item.thumbnail, cornerRadius: 10, symbol: item.isAudio ? "music.note" : "play.rectangle.fill")
                                    .frame(width: 180, height: 101)
                                Text(item.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .frame(width: 180, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { LibraryItemMenu(item: item) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Simple wrapping layout for pills.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            width = max(width, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
