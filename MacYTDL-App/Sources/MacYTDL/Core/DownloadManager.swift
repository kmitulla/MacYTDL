import Foundation
import AppKit
import UserNotifications

/// One entry in the download queue.
@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    let id: UUID
    var request: DownloadRequest

    @Published var state: TaskState = .queued
    @Published var title: String
    @Published var thumbnail: String?
    @Published var uploader: String?
    @Published var progress: Double = 0
    @Published var speed: Double?
    @Published var eta: Int?
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64?
    @Published var detail: String = ""
    @Published var errorMessage: String?
    @Published var outputFiles: [String] = []
    @Published var playlistIndex: Int?
    @Published var playlistCount: Int?
    @Published var finishedAt: Date?

    var attempts = 0
    private(set) var logLines: [String] = []
    var commandLine = ""
    var lastErrorText = ""
    var duration: Double?
    var currentPageURL: String?

    fileprivate var runner: ProcessRunner?
    fileprivate var stopReason: TaskState?
    fileprivate var streamCount = 1
    fileprivate var finishedStreams = 0
    fileprivate var logHandle: FileHandle?
    fileprivate var retryWorkItem: DispatchWorkItem?

    var logFile: URL { AppPaths.logs.appendingPathComponent("\(id.uuidString).log") }

    var isSubscriptionCheck: Bool {
        if case .subscription = request.kind { return true }
        return false
    }

    init(request: DownloadRequest) {
        self.id = request.id
        self.request = request
        self.title = request.titleHint ?? URLTools.displayHost(request.url)
        self.thumbnail = request.thumbnailHint
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 1500 { logLines.removeFirst(logLines.count - 1500) }
        if logHandle == nil {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logFile)
            logHandle?.seekToEndOfFile()
        }
        if let data = (line + "\n").data(using: .utf8) {
            logHandle?.write(data)
        }
    }

    fileprivate func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    var fullLog: String {
        if let text = try? String(contentsOf: logFile, encoding: .utf8), !text.isEmpty { return text }
        return logLines.joined(separator: "\n")
    }

    var statusLine: String {
        switch state {
        case .downloading:
            var parts: [String] = []
            if let total = totalBytes, total > 0 {
                parts.append("\(Format.bytes(downloadedBytes)) / \(Format.bytes(total))")
            } else if downloadedBytes > 0 {
                parts.append(Format.bytes(downloadedBytes))
            }
            if let speed, speed > 0 { parts.append(Format.speed(speed)) }
            let etaText = Format.eta(eta)
            if !etaText.isEmpty { parts.append(etaText) }
            if let i = playlistIndex, let n = playlistCount, n > 1 { parts.append(String(localized: "Item \(i) of \(n)")) }
            return parts.isEmpty ? state.label : parts.joined(separator: " · ")
        case .processing, .preparing, .queued:
            return detail.isEmpty ? state.label : detail
        case .completed:
            let count = outputFiles.count
            if isSubscriptionCheck {
                return count == 0 ? String(localized: "No new videos") : String(localized: "\(count) new videos")
            }
            if count > 1 { return String(localized: "\(count) files") }
            if let file = outputFiles.first,
               let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value {
                return Format.bytes(size)
            }
            return state.label
        case .failed:
            return errorMessage?.components(separatedBy: "\n").first ?? state.label
        case .paused, .cancelled:
            return detail.isEmpty ? state.label : detail
        }
    }
}

/// Runs the queue: concurrency, retries, persistence, notifications, keep-awake, Dock badge.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var completedThisSession = 0

    private let prefs = Preferences.shared
    private let tools = ToolManager.shared
    private var activity: NSObjectProtocol?
    private var saveScheduled = false
    private var afterQueueWorkItem: DispatchWorkItem?
    private var hadWorkSinceIdle = false

    /// Set by the self-test, which runs without an app bundle (no notifications, no Dock).
    var headless = false

    var activeTasks: [DownloadTask] { tasks.filter { $0.state.isActive } }
    var activeCount: Int { activeTasks.count }
    var pendingCount: Int { tasks.filter { $0.state == .queued || $0.state.isActive }.count }
    var finishedCount: Int { tasks.filter { $0.state.isFinished }.count }

    var overallProgress: Double? {
        let running = tasks.filter { $0.state.isActive || $0.state == .queued }
        guard !running.isEmpty else { return nil }
        return running.map { $0.progress }.reduce(0, +) / Double(running.count)
    }

    var totalSpeed: Double {
        activeTasks.compactMap { $0.state == .downloading ? $0.speed : nil }.reduce(0, +)
    }

    /// Sample tasks for screenshots (see DemoMode).
    func injectDemo(_ demoTasks: [DownloadTask]) {
        tasks = demoTasks
    }

    // MARK: Adding

    @discardableResult
    func add(url: String, options: DownloadOptions, info: MediaInfo? = nil, kind: DownloadKind = .normal) -> DownloadTask {
        var request = DownloadRequest(url: url, options: options, kind: kind)
        request.titleHint = info?.title
        request.thumbnailHint = info?.thumbnail
        request.isPlaylist = (info?.isPlaylist ?? false) && options.downloadPlaylist
        let task = DownloadTask(request: request)
        task.uploader = info?.uploader
        task.duration = info?.duration
        if info?.isPlaylist == true, options.downloadPlaylist {
            task.playlistCount = options.playlistItems.isEmpty ? info?.entries.count : options.playlistItems.split(separator: ",").count
        }
        tasks.append(task)
        hadWorkSinceIdle = true
        scheduleSave()
        pump()
        return task
    }

    /// One-click download with the default settings.
    @discardableResult
    func quickDownload(_ url: String, preset: QualityPreset? = nil) -> DownloadTask {
        var options = prefs.newOptions()
        if let preset { options.preset = preset }
        return add(url: URLTools.normalize(url), options: options)
    }

    func addBatch(_ urls: [String], preset: QualityPreset? = nil) {
        for url in urls { quickDownload(url, preset: preset) }
    }

    func enqueueSubscriptionCheck(_ sub: Subscription) {
        var options = prefs.newOptions()
        options.preset = sub.preset
        options.downloadPlaylist = true
        options.playlistSubfolder = true
        var request = DownloadRequest(url: sub.url, options: options, kind: .subscription(sub.id))
        request.titleHint = sub.title
        request.thumbnailHint = sub.thumbnail
        let task = DownloadTask(request: request)
        task.detail = String(localized: "Checking for new videos…")
        tasks.append(task)
        hadWorkSinceIdle = true
        pump()
    }

    // MARK: Queue control

    func pump() {
        let limit = max(1, prefs.maxConcurrent)
        var running = activeCount
        for task in tasks where task.state == .queued && task.retryWorkItem == nil {
            guard running < limit else { break }
            start(task)
            running += 1
        }
        updateSystemState()
    }

    private func start(_ task: DownloadTask) {
        guard let ytdlp = tools.ytdlpPath else {
            task.state = .failed
            task.errorMessage = MetadataError.toolMissing.localizedDescription
            return
        }
        task.attempts += 1
        task.state = .preparing
        task.detail = String(localized: "Analyzing…")
        task.errorMessage = nil
        task.lastErrorText = ""
        task.stopReason = nil
        task.streamCount = 1
        task.finishedStreams = 0
        task.speed = nil
        task.eta = nil

        var archive: URL?
        var limit: Int?
        if case .subscription(let subID) = task.request.kind,
           let sub = SubscriptionStore.shared.subscriptions.first(where: { $0.id == subID }) {
            archive = SubscriptionStore.shared.archiveURL(for: sub)
            limit = sub.maxItems
        }
        let args = CommandBuilder.downloadArguments(for: task.request, settings: .current(), archive: archive, subscriptionLimit: limit)
        task.commandLine = CommandBuilder.displayCommand(executable: ytdlp, arguments: args)
        task.appendLog("$ " + task.commandLine)
        try? FileManager.default.createDirectory(atPath: task.request.options.folder.isEmpty ? Preferences.standardDownloadFolder : task.request.options.folder,
                                                 withIntermediateDirectories: true)

        let runner = ProcessRunner(executable: ytdlp, arguments: args, environment: tools.environment)
        runner.onLine = { [weak self, weak task] line, stream in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let task else { return }
                    self.handle(line: line, stream: stream, task: task)
                }
            }
        }
        runner.onExit = { [weak self, weak task] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let task else { return }
                    self.finished(task: task, status: status)
                }
            }
        }
        task.runner = runner
        do {
            try runner.start()
        } catch {
            task.runner = nil
            task.state = .failed
            task.errorMessage = error.localizedDescription
            task.appendLog("ERROR: \(error.localizedDescription)")
            task.closeLog()
        }
    }

    func pause(_ task: DownloadTask) {
        task.retryWorkItem?.cancel()
        task.retryWorkItem = nil
        if task.state.isActive, let runner = task.runner {
            task.stopReason = .paused
            task.detail = String(localized: "Pausing…")
            runner.stop()
        } else if task.state == .queued {
            task.state = .paused
            task.detail = ""
        }
        scheduleSave()
    }

    func resume(_ task: DownloadTask) {
        guard task.state == .paused || task.state == .failed || task.state == .cancelled else { return }
        task.retryWorkItem?.cancel()
        task.retryWorkItem = nil
        task.state = .queued
        task.detail = ""
        task.errorMessage = nil
        hadWorkSinceIdle = true
        scheduleSave()
        pump()
    }

    func retry(_ task: DownloadTask) {
        task.attempts = 0
        resume(task)
    }

    func cancel(_ task: DownloadTask) {
        task.retryWorkItem?.cancel()
        task.retryWorkItem = nil
        if task.state.isActive, let runner = task.runner {
            task.stopReason = .cancelled
            task.detail = String(localized: "Cancelling…")
            runner.stop()
        } else if !task.state.isFinished {
            task.state = .cancelled
            task.detail = ""
            if case .subscription(let id) = task.request.kind {
                SubscriptionStore.shared.didFinishCheck(id: id, newItems: 0, error: nil)
            }
        }
        scheduleSave()
        pump()
    }

    func remove(_ task: DownloadTask) {
        if task.state.isActive { cancel(task) }
        tasks.removeAll { $0.id == task.id }
        try? FileManager.default.removeItem(at: task.logFile)
        scheduleSave()
    }

    func prioritize(_ task: DownloadTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let item = tasks.remove(at: idx)
        let firstWaiting = tasks.firstIndex(where: { !$0.state.isActive && !$0.state.isFinished }) ?? tasks.count
        tasks.insert(item, at: firstWaiting)
        scheduleSave()
    }

    func clearFinished() {
        let finished = tasks.filter { $0.state == .completed || $0.state == .cancelled }
        for task in finished { try? FileManager.default.removeItem(at: task.logFile) }
        tasks.removeAll { $0.state == .completed || $0.state == .cancelled }
        scheduleSave()
    }

    func pauseAll() {
        for task in tasks where task.state.isActive || task.state == .queued { pause(task) }
    }

    func resumeAll() {
        for task in tasks where task.state == .paused { resume(task) }
    }

    func retryFailed() {
        for task in tasks where task.state == .failed { retry(task) }
    }

    /// Stops all processes (keeping partial files) - used when quitting.
    func stopAllForQuit() {
        for task in tasks where task.state.isActive {
            task.stopReason = .paused
            task.runner?.signal(SIGINT)
        }
        saveNow(markActiveAsPaused: true)
    }

    // MARK: Output handling

    private func handle(line: String, stream: ProcessRunner.Stream, task: DownloadTask) {
        if line.hasPrefix(CommandBuilder.progressPrefix) {
            handleProgress(String(line.dropFirst(CommandBuilder.progressPrefix.count)), task: task)
            return
        }
        if line.hasPrefix(CommandBuilder.postprocessPrefix) {
            let parts = line.dropFirst(CommandBuilder.postprocessPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 2, parts[0] == "started", task.stopReason == nil {
                let name = String(parts[1])
                if name != "MoveFiles" {
                    task.state = .processing
                    task.detail = Self.describePostprocessor(name)
                }
                task.appendLog("[\(name)] …")
            }
            return
        }
        if line.hasPrefix(CommandBuilder.infoPrefix) {
            let fields = line.dropFirst(CommandBuilder.infoPrefix.count)
                .components(separatedBy: CommandBuilder.fieldSeparator)
            if fields.count >= 9 {
                task.streamCount = max(1, fields[1].split(separator: "+").count)
                task.finishedStreams = 0
                if let d = Double(fields[2]) { task.duration = d }
                if let i = Int(fields[3]) { task.playlistIndex = i }
                if let n = Int(fields[4]), n > 0 { task.playlistCount = n }
                if !fields[5].isEmpty { task.thumbnail = fields[5] }
                if !fields[6].isEmpty { task.uploader = fields[6] }
                task.currentPageURL = fields[7].isEmpty ? nil : fields[7]
                let title = fields[8...].joined(separator: " ")
                if !title.isEmpty && !task.isSubscriptionCheck { task.title = title }
                if task.isSubscriptionCheck { task.detail = title }
                if task.state == .preparing { task.state = .downloading }
            }
            task.appendLog(line)
            return
        }
        if line.hasPrefix(CommandBuilder.filePrefix) {
            let path = String(line.dropFirst(CommandBuilder.filePrefix.count))
            if !task.outputFiles.contains(path) { task.outputFiles.append(path) }
            task.appendLog("✓ " + path)
            registerInLibrary(path: path, task: task)
            return
        }
        task.appendLog(line)
        if stream == .stderr || line.hasPrefix("ERROR") {
            if line.contains("ERROR") {
                task.lastErrorText += line + "\n"
            } else if line.hasPrefix("WARNING") == false && task.lastErrorText.count < 4000 {
                // Python tracebacks etc.
                if line.contains("Error") || line.contains("Traceback") { task.lastErrorText += line + "\n" }
            }
        }
        if line.hasPrefix("[download]") && line.contains("has already been downloaded") {
            task.detail = String(localized: "Already downloaded")
        }
    }

    private func handleProgress(_ payload: String, task: DownloadTask) {
        guard task.stopReason == nil else { return }
        let f = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 11 else { return }
        let status = f[0]
        let downloaded = Double(f[1]).map { Int64($0) }
        let total = Double(f[2]).map { Int64($0) } ?? Double(f[3]).map { Int64($0) }
        let speed = Double(f[4])
        let eta = Double(f[5]).map { Int($0) }
        let fragIndex = Double(f[6])
        let fragCount = Double(f[7])
        if let i = Int(f[8]) { task.playlistIndex = i }
        if let n = Int(f[9]), n > 0 { task.playlistCount = n }

        var fraction: Double?
        if let downloaded, let total, total > 0 {
            fraction = min(1, Double(downloaded) / Double(total))
        } else if let fragIndex, let fragCount, fragCount > 0 {
            fraction = min(1, fragIndex / fragCount)
        }

        if status == "finished" {
            task.finishedStreams = min(task.streamCount, task.finishedStreams + 1)
            fraction = 0
        }
        task.state = .downloading
        task.detail = ""
        task.downloadedBytes = downloaded ?? task.downloadedBytes
        task.totalBytes = total
        task.speed = speed
        task.eta = eta

        let streams = Double(max(1, task.streamCount))
        let itemFraction = min(1, (Double(task.finishedStreams) + (fraction ?? 0)) / streams)
        if let index = task.playlistIndex, let count = task.playlistCount, count > 1 {
            // Playlist indices can be sparse (selected items), so use the position among the downloads.
            let position = min(Double(count), Double(max(1, min(index, count))))
            task.progress = min(1, ((position - 1) + itemFraction) / Double(count))
        } else {
            task.progress = itemFraction
        }
        updateDockProgress()
    }

    static func describePostprocessor(_ name: String) -> String {
        switch name {
        case "Merger": return String(localized: "Merging video and audio…")
        case "ExtractAudio": return String(localized: "Converting audio…")
        case "EmbedThumbnail": return String(localized: "Embedding cover art…")
        case "FFmpegMetadata", "Metadata": return String(localized: "Writing metadata…")
        case "EmbedSubtitle": return String(localized: "Embedding subtitles…")
        case "SponsorBlock", "ModifyChapters": return String(localized: "Removing sponsor segments…")
        case "VideoRemuxer", "VideoConvertor": return String(localized: "Converting video…")
        case "FixupM3u8", "FixupM4a", "FixupTimestamp", "FixupDuplicateMoov", "FixupStretched": return String(localized: "Repairing file…")
        case "SubtitlesConvertor": return String(localized: "Converting subtitles…")
        case "ThumbnailsConvertor": return String(localized: "Converting thumbnail…")
        default: return String(localized: "Processing…")
        }
    }

    private func registerInLibrary(path: String, task: DownloadTask) {
        let lower = path.lowercased()
        let audioExtensions = ["mp3", "m4a", "opus", "flac", "wav", "ogg", "aac", "mka"]
        guard !lower.hasSuffix(".srt"), !lower.hasSuffix(".vtt"), !lower.hasSuffix(".jpg"), !lower.hasSuffix(".description") else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        let item = LibraryItem(url: task.currentPageURL ?? task.request.url,
                               title: (path as NSString).lastPathComponent.replacingOccurrences(of: ".\(ext)", with: ""),
                               filePath: path,
                               thumbnail: task.thumbnail,
                               uploader: task.uploader,
                               duration: task.duration,
                               isAudio: audioExtensions.contains(ext) || task.request.options.preset.isAudio,
                               fileSize: size)
        LibraryStore.shared.add(item)
    }

    private func finished(task: DownloadTask, status: Int32) {
        task.runner = nil
        task.speed = nil
        task.eta = nil
        let reason = task.stopReason
        task.stopReason = nil
        task.appendLog("— exit status \(status)")

        let isSubscription = task.isSubscriptionCheck
        // 101 = stopped by --break-on-existing / --max-downloads (expected for subscriptions).
        let success = status == 0 || (isSubscription && status == 101)

        if reason == .paused {
            task.state = .paused
            task.detail = String(localized: "Paused – resumes where it stopped")
        } else if reason == .cancelled {
            task.state = .cancelled
            task.detail = ""
            if case .subscription(let id) = task.request.kind {
                SubscriptionStore.shared.didFinishCheck(id: id, newItems: task.outputFiles.count, error: nil)
            }
        } else if success {
            task.state = .completed
            task.progress = 1
            task.detail = ""
            task.finishedAt = Date()
            completedThisSession += 1
            if case .subscription(let id) = task.request.kind {
                SubscriptionStore.shared.didFinishCheck(id: id, newItems: task.outputFiles.count, error: nil)
                if !task.outputFiles.isEmpty { notify(task: task, success: true) }
            } else {
                notify(task: task, success: true)
            }
        } else {
            let raw = task.lastErrorText.isEmpty ? task.logLines.suffix(5).joined(separator: "\n") : task.lastErrorText
            let explanation = ErrorAdvisor.explain(raw)
            if ErrorAdvisor.isTransient(raw) && task.attempts <= prefs.autoRetry {
                let delay = Double(task.attempts) * 5
                task.state = .queued
                task.detail = String(localized: "Network problem – retrying in \(Int(delay)) s…")
                let work = DispatchWorkItem { [weak self, weak task] in
                    MainActor.assumeIsolated {
                        guard let self, let task else { return }
                        task.retryWorkItem = nil
                        self.pump()
                    }
                }
                task.retryWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            } else {
                task.state = .failed
                task.errorMessage = explanation
                task.finishedAt = Date()
                if case .subscription(let id) = task.request.kind {
                    SubscriptionStore.shared.didFinishCheck(id: id, newItems: task.outputFiles.count, error: explanation)
                }
                notify(task: task, success: false)
            }
        }
        task.closeLog()
        scheduleSave()
        pump()
    }

    // MARK: System integration

    private func updateSystemState() {
        let busy = tasks.contains { $0.state.isActive || ($0.state == .queued) }
        if busy && prefs.keepAwake {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "MacYTDL downloads in progress")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        updateDockProgress()
        if !busy && hadWorkSinceIdle {
            hadWorkSinceIdle = false
            queueBecameIdle()
        } else if busy {
            afterQueueWorkItem?.cancel()
            afterQueueWorkItem = nil
        }
    }

    private func queueBecameIdle() {
        guard !headless, prefs.afterQueue != .nothing, completedThisSession > 0 else { return }
        let action = prefs.afterQueue
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingCount == 0 else { return }
                switch action {
                case .nothing: break
                case .sleep:
                    Task { _ = await ProcessRunner.run("/usr/bin/pmset", ["sleepnow"], timeout: 10) }
                case .quit:
                    NSApp.terminate(nil)
                }
            }
        }
        afterQueueWorkItem = work
        ToastCenter.shared.show(String(localized: "All downloads finished – \(action.title.lowercased()) in 30 s."), symbol: "moon.zzz")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private var lastDockUpdate = Date.distantPast

    private func updateDockProgress() {
        guard !headless else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDockUpdate) > 0.5 || overallProgress == nil else { return }
        lastDockUpdate = now
        DockProgress.shared.update(progress: overallProgress, badge: pendingCount)
    }

    private func notify(task: DownloadTask, success: Bool) {
        guard !headless else { return }
        if prefs.playSound {
            NSSound(named: success ? "Glass" : "Basso")?.play()
        }
        guard prefs.notifyOnFinish, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let title = success ? String(localized: "Download finished") : String(localized: "Download failed")
        var body = task.title
        if !success, let message = task.errorMessage?.components(separatedBy: "\n").first { body += "\n" + message }
        let file = task.outputFiles.last
        let identifier = task.id.uuidString
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let file { content.userInfo = ["file": file] }
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    // MARK: Persistence

    private struct SavedTask: Codable {
        var request: DownloadRequest
        var state: TaskState
        var title: String
        var thumbnail: String?
        var progress: Double
        var outputFiles: [String]
        var errorMessage: String?
    }

    func restore() {
        guard let saved = JSONStore.load([SavedTask].self, from: AppPaths.queueFile) else { return }
        for item in saved {
            if case .subscription = item.request.kind { continue }
            let task = DownloadTask(request: item.request)
            task.title = item.title
            task.thumbnail = item.thumbnail
            task.progress = item.progress
            task.outputFiles = item.outputFiles
            task.errorMessage = item.errorMessage
            switch item.state {
            case .completed, .failed, .cancelled:
                task.state = item.state
            default:
                task.state = prefs.autoResumeQueue ? .queued : .paused
                task.detail = prefs.autoResumeQueue ? "" : String(localized: "Restored from last session")
            }
            tasks.append(task)
        }
        if tasks.contains(where: { $0.state == .queued }) { hadWorkSinceIdle = true }
        pump()
    }

    private func scheduleSave() {
        guard !saveScheduled, !headless, !DemoMode.isActive else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.saveNow(markActiveAsPaused: false)
            }
        }
    }

    func saveNow(markActiveAsPaused: Bool) {
        guard !headless, !DemoMode.isActive else { return }
        let saved = tasks.filter { !$0.isSubscriptionCheck }.suffix(300).map { task -> SavedTask in
            var state = task.state
            if markActiveAsPaused && state.isActive { state = .paused }
            return SavedTask(request: task.request, state: state, title: task.title, thumbnail: task.thumbnail,
                             progress: task.progress, outputFiles: task.outputFiles, errorMessage: task.errorMessage)
        }
        JSONStore.save(Array(saved), to: AppPaths.queueFile)
    }
}

/// Dock icon with a progress bar and badge.
@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private var view: DockProgressView?

    func update(progress: Double?, badge: Int) {
        let tile = NSApp.dockTile
        if let progress {
            if view == nil {
                let v = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
                view = v
                tile.contentView = v
            }
            view?.progress = progress
        } else if view != nil {
            tile.contentView = nil
            view = nil
        }
        tile.badgeLabel = badge > 0 ? "\(badge)" : nil
        tile.display()
    }
}

final class DockProgressView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let barHeight = bounds.height * 0.11
        let inset = bounds.width * 0.14
        let barRect = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: barHeight)
        let track = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        track.fill()
        let inner = barRect.insetBy(dx: 2, dy: 2)
        var fillRect = inner
        fillRect.size.width = max(inner.height, inner.width * CGFloat(max(0, min(1, progress))))
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: inner.height / 2, yRadius: inner.height / 2)
        NSColor.white.setFill()
        fill.fill()
    }
}
