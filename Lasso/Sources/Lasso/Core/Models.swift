import Foundation
import SwiftUI

// MARK: - Quality presets

enum QualityPreset: String, CaseIterable, Codable, Identifiable, Hashable {
    case best
    case uhd2160
    case qhd1440
    case fhd1080
    case hd720
    case sd480
    case appleCompatible
    case audioBest
    case audioMP3
    case audioM4A
    case audioOpus
    case audioFLAC
    case audioWAV

    var id: String { rawValue }

    static var videoPresets: [QualityPreset] { [.best, .uhd2160, .qhd1440, .fhd1080, .hd720, .sd480, .appleCompatible] }
    static var audioPresets: [QualityPreset] { [.audioBest, .audioMP3, .audioM4A, .audioOpus, .audioFLAC, .audioWAV] }

    var isAudio: Bool { Self.audioPresets.contains(self) }

    var title: String {
        switch self {
        case .best: return String(localized: "Best quality")
        case .uhd2160: return "4K"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        case .appleCompatible: return String(localized: "Apple compatible")
        case .audioBest: return String(localized: "Audio (original)")
        case .audioMP3: return "MP3"
        case .audioM4A: return "M4A / AAC"
        case .audioOpus: return "Opus"
        case .audioFLAC: return "FLAC"
        case .audioWAV: return "WAV"
        }
    }

    var subtitle: String {
        switch self {
        case .best: return String(localized: "Highest resolution and bitrate")
        case .uhd2160: return String(localized: "Up to 2160p")
        case .qhd1440: return String(localized: "Up to 1440p")
        case .fhd1080: return String(localized: "Up to 1080p")
        case .hd720: return String(localized: "Up to 720p, small files")
        case .sd480: return String(localized: "Up to 480p, tiny files")
        case .appleCompatible: return String(localized: "H.264 + AAC, plays everywhere")
        case .audioBest: return String(localized: "Best audio, no re-encoding")
        case .audioMP3: return String(localized: "Universal, VBR best quality")
        case .audioM4A: return String(localized: "Ideal for Apple Music")
        case .audioOpus: return String(localized: "Efficient and modern")
        case .audioFLAC: return String(localized: "Lossless container")
        case .audioWAV: return String(localized: "Uncompressed")
        }
    }

    var symbol: String {
        switch self {
        case .best: return "sparkles.tv"
        case .uhd2160: return "4k.tv"
        case .qhd1440, .fhd1080: return "tv"
        case .hd720, .sd480: return "rectangle.compress.vertical"
        case .appleCompatible: return "apple.logo"
        case .audioBest: return "waveform"
        case .audioMP3, .audioM4A, .audioOpus: return "music.note"
        case .audioFLAC, .audioWAV: return "hifispeaker"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .uhd2160: return 2160
        case .qhd1440: return 1440
        case .fhd1080: return 1080
        case .hd720: return 720
        case .sd480: return 480
        default: return nil
        }
    }

    var audioFormat: String? {
        switch self {
        case .audioBest: return "best"
        case .audioMP3: return "mp3"
        case .audioM4A: return "m4a"
        case .audioOpus: return "opus"
        case .audioFLAC: return "flac"
        case .audioWAV: return "wav"
        default: return nil
        }
    }

    /// Closest preset for a given maximum height (used by the assistant and the preview chips).
    static func forHeight(_ height: Int) -> QualityPreset {
        switch height {
        case 2000...: return .uhd2160
        case 1300...: return .qhd1440
        case 1000...: return .fhd1080
        case 700...: return .hd720
        case 1...: return .sd480
        default: return .best
        }
    }
}

enum VideoContainer: String, CaseIterable, Codable, Identifiable {
    case mp4, mkv, webm, mov
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum SponsorBlockMode: String, CaseIterable, Codable, Identifiable {
    case off, mark, remove
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .mark: return String(localized: "Mark as chapters")
        case .remove: return String(localized: "Cut out sponsors")
        }
    }
}

enum FilenameStyle: String, CaseIterable, Codable, Identifiable {
    case title
    case titleID
    case channelTitle
    case dateTitle
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return String(localized: "Title")
        case .titleID: return String(localized: "Title [ID]")
        case .channelTitle: return String(localized: "Channel/Title")
        case .dateTitle: return String(localized: "Date – Title")
        case .custom: return String(localized: "Custom template")
        }
    }

    func template(custom: String) -> String {
        switch self {
        case .title: return "%(title)s.%(ext)s"
        case .titleID: return "%(title)s [%(id)s].%(ext)s"
        case .channelTitle: return "%(uploader,channel,extractor_key|Unknown)s/%(title)s.%(ext)s"
        case .dateTitle: return "%(upload_date>%Y-%m-%d,release_date>%Y-%m-%d|0000-00-00)s – %(title)s.%(ext)s"
        case .custom: return custom.isEmpty ? "%(title)s.%(ext)s" : custom
        }
    }
}

enum CookieBrowser: String, CaseIterable, Codable, Identifiable {
    case none, safari, chrome, firefox, edge, brave, opera, vivaldi, chromium
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return String(localized: "Don't use cookies")
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .chromium: return "Chromium"
        }
    }
}

// MARK: - Download options

/// Everything that describes *what* to download. Stored with every queue item so retries are identical.
struct DownloadOptions: Codable, Hashable {
    var preset: QualityPreset = .best
    var container: VideoContainer = .mp4
    var subtitles: Bool = false
    var subtitleLanguages: String = "de,en"
    var autoSubtitles: Bool = false
    var embedSubtitles: Bool = true
    var embedThumbnail: Bool = true
    var embedMetadata: Bool = true
    var embedChapters: Bool = true
    var sponsorBlock: SponsorBlockMode = .off
    var clipStart: String = ""
    var clipEnd: String = ""
    var downloadPlaylist: Bool = false
    var playlistItems: String = ""
    var playlistSubfolder: Bool = true
    var writeDescription: Bool = false
    var writeThumbnailFile: Bool = false
    var folder: String = ""
    var filenameStyle: FilenameStyle = .title
    var customTemplate: String = ""
    /// Playlists: write an .m3u8 playlist file next to the downloads.
    var createM3U: Bool = true
    /// Playlists: remember what was downloaded and only fetch new items next time.
    var skipExisting: Bool = true
    /// Music: prefix file names with the track number.
    var numberTracks: Bool = true

    var hasClip: Bool {
        !clipStart.trimmingCharacters(in: .whitespaces).isEmpty || !clipEnd.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {}

    // Tolerant decoding so that older saved queues keep working when options are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DownloadOptions.defaultValues
        preset = (try? c.decode(QualityPreset.self, forKey: .preset)) ?? d.preset
        container = (try? c.decode(VideoContainer.self, forKey: .container)) ?? d.container
        subtitles = (try? c.decode(Bool.self, forKey: .subtitles)) ?? d.subtitles
        subtitleLanguages = (try? c.decode(String.self, forKey: .subtitleLanguages)) ?? d.subtitleLanguages
        autoSubtitles = (try? c.decode(Bool.self, forKey: .autoSubtitles)) ?? d.autoSubtitles
        embedSubtitles = (try? c.decode(Bool.self, forKey: .embedSubtitles)) ?? d.embedSubtitles
        embedThumbnail = (try? c.decode(Bool.self, forKey: .embedThumbnail)) ?? d.embedThumbnail
        embedMetadata = (try? c.decode(Bool.self, forKey: .embedMetadata)) ?? d.embedMetadata
        embedChapters = (try? c.decode(Bool.self, forKey: .embedChapters)) ?? d.embedChapters
        sponsorBlock = (try? c.decode(SponsorBlockMode.self, forKey: .sponsorBlock)) ?? d.sponsorBlock
        clipStart = (try? c.decode(String.self, forKey: .clipStart)) ?? d.clipStart
        clipEnd = (try? c.decode(String.self, forKey: .clipEnd)) ?? d.clipEnd
        downloadPlaylist = (try? c.decode(Bool.self, forKey: .downloadPlaylist)) ?? d.downloadPlaylist
        playlistItems = (try? c.decode(String.self, forKey: .playlistItems)) ?? d.playlistItems
        playlistSubfolder = (try? c.decode(Bool.self, forKey: .playlistSubfolder)) ?? d.playlistSubfolder
        writeDescription = (try? c.decode(Bool.self, forKey: .writeDescription)) ?? d.writeDescription
        writeThumbnailFile = (try? c.decode(Bool.self, forKey: .writeThumbnailFile)) ?? d.writeThumbnailFile
        folder = (try? c.decode(String.self, forKey: .folder)) ?? d.folder
        filenameStyle = (try? c.decode(FilenameStyle.self, forKey: .filenameStyle)) ?? d.filenameStyle
        customTemplate = (try? c.decode(String.self, forKey: .customTemplate)) ?? d.customTemplate
        createM3U = (try? c.decode(Bool.self, forKey: .createM3U)) ?? d.createM3U
        skipExisting = (try? c.decode(Bool.self, forKey: .skipExisting)) ?? d.skipExisting
        numberTracks = (try? c.decode(Bool.self, forKey: .numberTracks)) ?? d.numberTracks
    }

    private static let defaultValues = DownloadOptions()
}

// MARK: - Download request / task state

enum DownloadKind: Codable, Hashable {
    case normal
    case subscription(UUID)
}

struct DownloadRequest: Codable, Hashable, Identifiable {
    var id = UUID()
    var url: String
    var options: DownloadOptions
    var kind: DownloadKind = .normal
    var titleHint: String?
    var thumbnailHint: String?
    var isPlaylist: Bool = false
    var createdAt = Date()
    /// Set for songs from Spotify & co: Lasso finds the song on YouTube Music and tags it.
    var music: MusicTrack?
    /// Set when the download belongs to a collection (album/playlist) - used for numbering and .m3u8.
    var group: DownloadGroup?
}

struct MusicTrack: Codable, Hashable {
    var title: String
    var artists: [String]
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var trackCount: Int?
    var durationMs: Int?
    var releaseYear: String?
    var coverURL: String?
    var sourceURL: String?
    var explicit: Bool?

    var artistLine: String { artists.joined(separator: ", ") }
    var mainArtist: String { artists.first ?? "" }
    var durationSeconds: Double? { durationMs.map { Double($0) / 1000 } }
    var searchQuery: String { "\(artists.prefix(2).joined(separator: " ")) \(title)" }
}

struct DownloadGroup: Codable, Hashable {
    var id: UUID
    var name: String
    var index: Int
    var total: Int
    var folder: String
    var createM3U: Bool
    /// Link of the whole playlist (used for the "skip already downloaded" archive).
    var sourceURL: String?
}

enum TaskState: String, Codable {
    case queued, preparing, downloading, processing, paused, completed, failed, cancelled

    var isActive: Bool { self == .preparing || self == .downloading || self == .processing }
    var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }

    var label: String {
        switch self {
        case .queued: return String(localized: "Waiting")
        case .preparing: return String(localized: "Analyzing…")
        case .downloading: return String(localized: "Downloading")
        case .processing: return String(localized: "Processing…")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    var color: Color {
        switch self {
        case .queued, .paused: return .secondary
        case .preparing, .downloading, .processing: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .preparing: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .processing: return "gearshape.2"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}

// MARK: - Library / subscriptions

struct LibraryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var filePath: String
    var thumbnail: String?
    var uploader: String?
    var duration: Double?
    var isAudio: Bool
    var fileSize: Int64?
    var date: Date = Date()
    // Added in Lasso 1.0 - optional so older libraries keep decoding.
    var artist: String?
    var album: String?
    var trackNumber: Int?
    var favorite: Bool?
    var playCount: Int?
    var lastPlayed: Date?
    var source: String?
    var resumePosition: Double?

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: filePath) }
    var isFavorite: Bool { favorite ?? false }
    var displayArtist: String { artist ?? uploader ?? URLTools.displayHost(url) }
    var displayAlbum: String? { album }
    var fileExtension: String { (filePath as NSString).pathExtension.lowercased() }
}

/// A user-made collection ("Sammlung") with its own order.
struct LibraryCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var itemIDs: [UUID] = []
    var created = Date()
}

struct Subscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var thumbnail: String?
    var preset: QualityPreset = .best
    var intervalHours: Int = 6
    var maxItems: Int = 10
    var enabled: Bool = true
    var lastChecked: Date?
    var lastNewCount: Int = 0
    var totalDownloaded: Int = 0
    var lastError: String?
}

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "–" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func eta(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        if seconds < 60 { return String(localized: "\(seconds) s left") }
        let minutes = seconds / 60
        if minutes < 60 { return String(localized: "\(minutes) min left") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min left")
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.notation(.compactName))
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return String(localized: "never") }
        return date.formatted(.relative(presentation: .named))
    }

    /// Accepts "90", "1:30", "01:02:03" and returns seconds.
    static func parseTimecode(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

// MARK: - URL helpers

enum URLTools {
    /// Extracts all http(s) URLs from arbitrary text (one per line, separated by spaces, ...).
    static func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result: [String] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            let string = url.absoluteString
            if !result.contains(string) { result.append(string) }
        }
        return result
    }

    static func isLikelyMediaURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return false }
        return true
    }

    /// YouTube channel URLs without a tab return nested playlists - point them at the videos tab.
    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("www.") || s.hasPrefix("youtube.com") || s.hasPrefix("youtu.be") || s.hasPrefix("m.youtube.com") {
            s = "https://" + s
        }
        if let url = URL(string: s), let host = url.host?.lowercased(), host.hasSuffix("youtube.com") {
            let path = url.path
            let components = path.split(separator: "/")
            if components.count == 1, let first = components.first, first.hasPrefix("@") {
                return "https://www.youtube.com/\(first)/videos"
            }
        }
        return s
    }

    /// True for URLs like youtube.com/watch?v=X&list=Y that point at a video *and* a playlist.
    static func hasVideoAndPlaylist(_ text: String) -> Bool {
        guard let comps = URLComponents(string: text) else { return false }
        let names = Set((comps.queryItems ?? []).map(\.name))
        return names.contains("v") && names.contains("list")
    }

    static func displayHost(_ text: String) -> String {
        guard let host = URL(string: text)?.host else { return text }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}
