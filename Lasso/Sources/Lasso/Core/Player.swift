import Foundation
import AVFoundation
import MediaPlayer
import AppKit
import SwiftUI

/// The in-app player: queue, shuffle/repeat, resume position, media keys and Now Playing.
@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()

    enum RepeatMode: String, CaseIterable {
        case off, all, one
        var symbol: String {
            switch self {
            case .off, .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
    }

    let player = AVPlayer()
    @Published private(set) var queue: [LibraryItem] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var error: String?
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double { didSet { player.volume = Float(volume); Preferences.shared.playerVolume = volume } }
    @Published var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }

    var current: LibraryItem? { queue.indices.contains(index) ? queue[index] : nil }
    var isVideo: Bool { current.map { !$0.isAudio } ?? false }
    var hasNext: Bool { index + 1 < queue.count || repeatMode == .all || shuffle }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var history: [Int] = []
    private var lastNowPlayingUpdate = Date.distantPast

    init() {
        volume = Preferences.shared.playerVolume
        player.volume = Float(Preferences.shared.playerVolume)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        setupRemoteCommands()
    }

    // MARK: Queue

    func play(_ items: [LibraryItem], startAt item: LibraryItem? = nil) {
        let playable = items.filter(\.fileExists)
        guard !playable.isEmpty else {
            error = String(localized: "The file no longer exists.")
            return
        }
        queue = playable
        history = []
        let start = item.flatMap { target in playable.firstIndex { $0.id == target.id } } ?? 0
        load(start, autoplay: true)
    }

    /// Screenshot state without touching AVPlayer (see DemoMode).
    func injectDemo(_ items: [LibraryItem], index: Int, time: Double, duration: Double) {
        queue = items
        self.index = index
        currentTime = time
        self.duration = duration
        isPlaying = true
    }

    func playNext(_ items: [LibraryItem]) {
        let playable = items.filter(\.fileExists)
        guard !playable.isEmpty else { return }
        if queue.isEmpty { play(playable); return }
        queue.insert(contentsOf: playable, at: min(index + 1, queue.count))
    }

    func enqueue(_ items: [LibraryItem]) {
        let playable = items.filter(\.fileExists)
        guard !playable.isEmpty else { return }
        if queue.isEmpty { play(playable); return }
        queue.append(contentsOf: playable)
    }

    func jump(to i: Int) { load(i, autoplay: true) }

    func removeFromQueue(at offsets: IndexSet) {
        let removingCurrent = offsets.contains(index)
        let before = offsets.filter { $0 < index }.count
        queue.remove(atOffsets: offsets)
        if queue.isEmpty { stop(); return }
        if removingCurrent {
            load(min(index - before, queue.count - 1), autoplay: isPlaying)
        } else {
            index -= before
        }
    }

    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        guard let currentID = current?.id else { queue.move(fromOffsets: offsets, toOffset: destination); return }
        queue.move(fromOffsets: offsets, toOffset: destination)
        index = queue.firstIndex { $0.id == currentID } ?? 0
    }

    // MARK: Transport

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard player.currentItem != nil else {
            if !queue.isEmpty { load(index, autoplay: true) }
            return
        }
        if duration > 0 && currentTime >= duration - 0.5 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying(force: true)
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePosition()
        updateNowPlaying(force: true)
    }

    func next() {
        guard !queue.isEmpty else { return }
        if shuffle && queue.count > 1 {
            history.append(index)
            var candidate = index
            while candidate == index { candidate = Int.random(in: 0..<queue.count) }
            load(candidate, autoplay: true)
        } else if index + 1 < queue.count {
            load(index + 1, autoplay: true)
        } else if repeatMode == .all {
            load(0, autoplay: true)
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        if shuffle, let last = history.popLast() { load(last, autoplay: true); return }
        if index > 0 { load(index - 1, autoplay: true) } else { seek(to: 0) }
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        updateNowPlaying(force: true)
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    func stop() {
        savePosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        queue = []
        index = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func clearError() { error = nil }

    // MARK: Loading

    private func load(_ i: Int, autoplay: Bool) {
        savePosition()
        guard queue.indices.contains(i) else { stop(); return }
        index = i
        error = nil
        let item = queue[i]
        let avItem = AVPlayerItem(url: item.fileURL)
        statusObservation = avItem.observe(\.status, options: [.new]) { observed, _ in
            let failed = observed.status == .failed
            let message = observed.error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard failed else { return }
                    PlayerController.shared.playbackFailed(message)
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main) { _ in
            MainActor.assumeIsolated { PlayerController.shared.itemEnded() }
        }
        player.replaceCurrentItem(with: avItem)
        duration = item.duration ?? 0
        currentTime = 0
        if Preferences.shared.rememberPosition, let position = item.resumePosition, position > 5,
           position < (item.duration ?? .infinity) - 10 {
            seek(to: position)
        }
        if autoplay {
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
        LibraryStore.shared.markPlayed(item.id)
        loadArtwork(item)
        updateNowPlaying(force: true)
        if !item.isAudio { AppState.shared.openPlayerWindow?() }
    }

    private func playbackFailed(_ message: String?) {
        let ext = current?.fileExtension.uppercased() ?? ""
        error = String(localized: "This file (\(ext)) can't be played by macOS. Convert it to MP4/M4A or open it in another player.")
        isPlaying = false
        _ = message
    }

    private func itemEnded() {
        if let item = current { LibraryStore.shared.savePosition(item.id, nil) }
        if repeatMode == .one {
            seek(to: 0)
            player.playImmediately(atRate: rate)
        } else if Preferences.shared.autoplayNext {
            next()
        } else {
            isPlaying = false
            updateNowPlaying(force: true)
        }
    }

    private func savePosition() {
        guard Preferences.shared.rememberPosition, let item = current, duration > 120 else { return }
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        LibraryStore.shared.savePosition(item.id, position > 5 && position < duration - 10 ? position : nil)
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { currentTime = seconds }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 { duration = d }
        updateNowPlaying(force: false)
    }

    private func loadArtwork(_ item: LibraryItem) {
        artwork = nil
        guard let string = item.thumbnail, let url = URL(string: string) else { return }
        let id = item.id
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            if self.current?.id == id {
                self.artwork = image
                self.updateNowPlaying(force: true)
            }
        }
    }

    // MARK: Now Playing & media keys

    private func updateNowPlaying(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastNowPlayingUpdate) > 5 else { return }
        lastNowPlayingUpdate = now
        guard let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.displayArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyMediaType: item.isAudio ? MPNowPlayingInfoMediaType.audio.rawValue : MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork {
            let image = artwork
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PlayerController.shared.resume() } }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PlayerController.shared.pause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PlayerController.shared.toggle() } }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PlayerController.shared.next() } }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PlayerController.shared.previous() } }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            DispatchQueue.main.async { MainActor.assumeIsolated { PlayerController.shared.seek(to: position) } }
            return .success
        }
    }

    /// Demo state for screenshots.
    func injectDemo(_ items: [LibraryItem], time: Double, playing: Bool) {
        queue = items
        index = 0
        duration = items.first?.duration ?? 0
        currentTime = time
        isPlaying = playing
    }
}

/// Converts files that macOS can't play (WebM, MKV, Opus, …) into MP4/M4A/MP3.
enum MediaConverter {
    enum Target: String, CaseIterable, Identifiable {
        case mp4, m4a, mp3
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mp4: return String(localized: "MP4 video (H.264/AAC)")
            case .m4a: return String(localized: "M4A audio (AAC)")
            case .mp3: return String(localized: "MP3 audio")
            }
        }
    }

    /// Returns the path of the new file.
    static func convert(_ path: String, to target: Target, ffmpeg: String) async -> String? {
        let source = URL(fileURLWithPath: path)
        var output = source.deletingPathExtension().appendingPathExtension(target.rawValue)
        if output.path == path || FileManager.default.fileExists(atPath: output.path) {
            output = source.deletingLastPathComponent()
                .appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (\(target.rawValue.uppercased())).\(target.rawValue)")
        }
        let base = ["-hide_banner", "-loglevel", "error", "-y", "-i", path, "-map_metadata", "0"]
        var attempts: [[String]] = []
        switch target {
        case .mp4:
            let tail = ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path]
            attempts = [
                ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy", "-tag:v", "avc1"] + tail,          // already H.264
                ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "h264_videotoolbox", "-b:v", "8M"] + tail,  // hardware encoder
                ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20"] + tail,
            ]
        case .m4a:
            attempts = [["-vn", "-c:a", "aac", "-b:a", "256k", output.path]]
        case .mp3:
            attempts = [["-vn", "-c:a", "libmp3lame", "-q:a", "0", output.path]]
        }
        for extra in attempts {
            let result = await ProcessRunner.run(ffmpeg, base + extra, timeout: 3600)
            if result.status == 0, FileManager.default.fileExists(atPath: output.path) {
                // Make sure the copy actually plays (a copied VP9 stream would not).
                if target == .mp4, extra.contains("copy") {
                    let asset = AVURLAsset(url: output)
                    let playable = (try? await asset.load(.isPlayable)) ?? false
                    if !playable { try? FileManager.default.removeItem(at: output); continue }
                }
                return output.path
            }
            try? FileManager.default.removeItem(at: output)
        }
        return nil
    }

    static func isPlayableByAVFoundation(_ item: LibraryItem) -> Bool {
        ["mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav", "aiff", "aif", "flac", "caf"].contains(item.fileExtension)
    }
}
