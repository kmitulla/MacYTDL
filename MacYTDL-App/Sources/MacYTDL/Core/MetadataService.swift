import Foundation

struct PlaylistEntry: Identifiable, Hashable {
    var id: String
    var videoID: String = ""
    var ieKey: String?
    var index: Int
    var title: String
    var url: String
    var duration: Double?
    var thumbnail: String?
    var uploader: String?
    var viewCount: Int?
}

struct QualityOption: Identifiable, Hashable {
    var id: Int { height }
    var height: Int
    var estimatedBytes: Int64?
    var fps: Double?
    var hdr: Bool
}

/// The parts of yt-dlp's JSON that the preview needs.
struct MediaInfo: Identifiable, Hashable {
    var id: String
    var url: String
    var title: String
    var uploader: String?
    var duration: Double?
    var thumbnail: String?
    var viewCount: Int?
    var likeCount: Int?
    var uploadDate: Date?
    var description: String?
    var extractor: String?
    var isLive: Bool = false
    var isPlaylist: Bool = false
    var entries: [PlaylistEntry] = []
    var qualities: [QualityOption] = []
    var bestAudioBytes: Int64?
    var hasSubtitles: [String] = []
    var hasAutoSubtitles: Bool = false
    var chapters: Int = 0

    var maxHeight: Int? { qualities.map(\.height).max() }

    func estimatedSize(for preset: QualityPreset) -> Int64? {
        if preset.isAudio { return bestAudioBytes }
        let candidates = qualities.filter { q in
            if let max = preset.maxHeight { return q.height <= max }
            return true
        }
        guard let pick = candidates.max(by: { $0.height < $1.height }), let video = pick.estimatedBytes else { return nil }
        return video + (bestAudioBytes ?? 0)
    }

    static func parse(_ json: [String: Any], requestedURL: String) -> MediaInfo {
        let type = json["_type"] as? String
        var info = MediaInfo(
            id: json["id"] as? String ?? UUID().uuidString,
            url: json["webpage_url"] as? String ?? json["original_url"] as? String ?? requestedURL,
            title: (json["title"] as? String) ?? (json["id"] as? String) ?? requestedURL,
            uploader: json["uploader"] as? String ?? json["channel"] as? String ?? json["playlist_uploader"] as? String,
            duration: number(json["duration"]),
            thumbnail: bestThumbnail(json),
            viewCount: number(json["view_count"]).map { Int($0) },
            likeCount: number(json["like_count"]).map { Int($0) },
            uploadDate: parseDate(json["upload_date"] as? String),
            description: json["description"] as? String,
            extractor: json["extractor_key"] as? String ?? json["ie_key"] as? String,
            isLive: (json["is_live"] as? Bool) ?? false
        )
        if type == "playlist" || json["entries"] != nil {
            info.isPlaylist = true
            let entries = json["entries"] as? [[String: Any]] ?? []
            info.entries = entries.enumerated().compactMap { offset, entry in
                let id = entry["id"] as? String ?? "\(offset)"
                let url = entry["url"] as? String ?? entry["webpage_url"] as? String ?? ""
                guard !url.isEmpty || entry["id"] != nil else { return nil }
                return PlaylistEntry(
                    id: "\(offset)-\(id)",
                    videoID: id,
                    ieKey: entry["ie_key"] as? String,
                    index: (entry["playlist_index"] as? Int) ?? offset + 1,
                    title: entry["title"] as? String ?? id,
                    url: url,
                    duration: number(entry["duration"]),
                    thumbnail: bestThumbnail(entry),
                    uploader: entry["uploader"] as? String ?? entry["channel"] as? String,
                    viewCount: number(entry["view_count"]).map { Int($0) }
                )
            }
            if info.thumbnail == nil { info.thumbnail = info.entries.first?.thumbnail }
        }

        if let formats = json["formats"] as? [[String: Any]] {
            var byHeight: [Int: QualityOption] = [:]
            var bestAudio: Int64?
            let duration = info.duration
            for format in formats {
                let vcodec = format["vcodec"] as? String ?? "none"
                let acodec = format["acodec"] as? String ?? "none"
                let size = (number(format["filesize"]) ?? number(format["filesize_approx"])).map { Int64($0) }
                    ?? estimate(tbr: number(format["tbr"]), duration: duration)
                if vcodec != "none", let height = format["height"] as? Int, height > 0 {
                    let hdr = (format["dynamic_range"] as? String).map { $0 != "SDR" } ?? false
                    let existing = byHeight[height]
                    let fps = number(format["fps"])
                    if existing == nil || (size ?? 0) > (existing?.estimatedBytes ?? 0) {
                        byHeight[height] = QualityOption(height: height, estimatedBytes: size, fps: fps,
                                                         hdr: hdr || (existing?.hdr ?? false))
                    } else if hdr {
                        byHeight[height]?.hdr = true
                    }
                } else if vcodec == "none", acodec != "none" {
                    if let size, size > (bestAudio ?? 0) { bestAudio = size }
                }
            }
            info.qualities = byHeight.values.sorted { $0.height > $1.height }
            info.bestAudioBytes = bestAudio
        }

        if let subs = json["subtitles"] as? [String: Any] {
            info.hasSubtitles = subs.keys.filter { $0 != "live_chat" }.sorted()
        }
        if let auto = json["automatic_captions"] as? [String: Any] {
            info.hasAutoSubtitles = !auto.isEmpty
        }
        if let chapters = json["chapters"] as? [[String: Any]] {
            info.chapters = chapters.count
        }
        return info
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func estimate(tbr: Double?, duration: Double?) -> Int64? {
        guard let tbr, let duration, tbr > 0, duration > 0 else { return nil }
        return Int64(tbr * 1000 / 8 * duration)
    }

    private static func bestThumbnail(_ json: [String: Any]) -> String? {
        if let thumbs = json["thumbnails"] as? [[String: Any]], !thumbs.isEmpty {
            // Prefer a medium sized image (fast to load, sharp enough for cards).
            let sized = thumbs.compactMap { t -> (String, Int)? in
                guard let url = t["url"] as? String else { return nil }
                let width = (t["width"] as? Int) ?? 0
                return (url, width)
            }
            if let medium = sized.filter({ $0.1 >= 320 && $0.1 <= 1280 }).max(by: { $0.1 < $1.1 }) { return medium.0 }
            if let last = sized.last { return last.0 }
        }
        return json["thumbnail"] as? String
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, value.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value)
    }
}

enum MetadataError: LocalizedError {
    case toolMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing: return String(localized: "yt-dlp is not installed. Open Settings › Components.")
        case .failed(let message): return message
        }
    }
}

@MainActor
enum MetadataService {
    static func fetch(url: String, playlist: Bool) async throws -> MediaInfo {
        guard let ytdlp = ToolManager.shared.ytdlpPath else { throw MetadataError.toolMissing }
        let args = CommandBuilder.infoArguments(url: url, playlist: playlist, settings: .current())
        let result = await ProcessRunner.run(ytdlp, args, environment: ToolManager.shared.environment, timeout: 120)
        if result.timedOut {
            throw MetadataError.failed(String(localized: "The website did not answer in time. Please try again."))
        }
        guard let jsonLine = result.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataError.failed(ErrorAdvisor.explain(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return MediaInfo.parse(json, requestedURL: url)
    }

    static func search(_ query: String, count: Int = 24) async throws -> [PlaylistEntry] {
        guard let ytdlp = ToolManager.shared.ytdlpPath else { throw MetadataError.toolMissing }
        let args = CommandBuilder.searchArguments(query: query, count: count, settings: .current())
        let result = await ProcessRunner.run(ytdlp, args, environment: ToolManager.shared.environment, timeout: 90)
        guard let jsonLine = result.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataError.failed(ErrorAdvisor.explain(result.stderr))
        }
        return MediaInfo.parse(json, requestedURL: query).entries.map { entry in
            var e = entry
            if !e.url.hasPrefix("http") {
                e.url = "https://www.youtube.com/watch?v=\(e.videoID)"
            }
            return e
        }
    }
}

/// Turns cryptic yt-dlp errors into helpful advice.
enum ErrorAdvisor {
    static func explain(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let errorLine = text.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init)
            ?? text.split(separator: "\n").last.map(String.init) ?? ""
        let detail = errorLine.replacingOccurrences(of: "ERROR: ", with: "")

        let hint: String?
        if lower.contains("sign in to confirm") || lower.contains("not a bot") {
            hint = String(localized: "YouTube wants to verify that you're human. Choose your browser under Settings › Network › Cookies (you must be signed in to YouTube there) and try again.")
        } else if lower.contains("confirm your age") || lower.contains("age-restricted") || lower.contains("inappropriate for some users") {
            hint = String(localized: "This video is age-restricted. Use cookies from a browser in which you're signed in (Settings › Network).")
        } else if lower.contains("members-only") || lower.contains("join this channel") || lower.contains("only available for registered users") || lower.contains("login required") || lower.contains("this video is private") || lower.contains("private video") {
            hint = String(localized: "This content requires an account. Use cookies from a browser in which you're signed in (Settings › Network).")
        } else if lower.contains("unsupported url") {
            hint = String(localized: "This website isn't supported, or the link doesn't point to a video.")
        } else if lower.contains("video unavailable") || lower.contains("has been removed") || lower.contains("no longer available") {
            hint = String(localized: "The video is unavailable – it may have been deleted, set to private or blocked in your country.")
        } else if lower.contains("not available in your country") || lower.contains("geo") && lower.contains("restrict") {
            hint = String(localized: "The video is blocked in your region. A proxy/VPN may help (Settings › Network).")
        } else if lower.contains("http error 403") || lower.contains("forbidden") {
            hint = String(localized: "Access denied by the website (403). Update yt-dlp under Settings › Components; cookies may also help.")
        } else if lower.contains("http error 429") || lower.contains("too many requests") {
            hint = String(localized: "Too many requests – the website is rate limiting you. Wait a few minutes or use browser cookies.")
        } else if lower.contains("requested format is not available") {
            hint = String(localized: "The selected quality isn't available for this video. Choose “Best quality” instead.")
        } else if lower.contains("ffmpeg") && (lower.contains("not found") || lower.contains("not installed")) {
            hint = String(localized: "FFmpeg is missing. Reinstall it under Settings › Components.")
        } else if lower.contains("no space left") {
            hint = String(localized: "Your disk is full. Free up space or choose another download folder.")
        } else if lower.contains("permission denied") || lower.contains("operation not permitted") {
            hint = String(localized: "MacYTDL can't write to the download folder. Choose another folder in Settings.")
        } else if lower.contains("timed out") || lower.contains("unable to download webpage") || lower.contains("getaddrinfo") || lower.contains("network is unreachable") || lower.contains("connection reset") || lower.contains("nodename nor servname") {
            hint = String(localized: "Network problem – check your internet connection. MacYTDL retries automatically.")
        } else if lower.contains("js runtime") || lower.contains("javascript runtime") || lower.contains("n challenge") || lower.contains("signature extraction failed") {
            hint = String(localized: "YouTube changed something. Update yt-dlp under Settings › Components (try the nightly channel if it persists).")
        } else if lower.contains("is not a valid url") || lower.contains("no such file") && lower.contains("http") == false {
            hint = String(localized: "That doesn't look like a valid link.")
        } else if lower.contains("cookie") && (lower.contains("could not") || lower.contains("failed") || lower.contains("operation not permitted")) {
            hint = String(localized: "Cookies could not be read. For Safari, give MacYTDL Full Disk Access in System Settings › Privacy & Security.")
        } else {
            hint = nil
        }
        if let hint {
            return detail.isEmpty ? hint : "\(hint)\n\n\(detail)"
        }
        return detail.isEmpty ? String(localized: "Unknown error. Open the log for details.") : detail
    }

    /// Errors where an automatic retry makes sense.
    static func isTransient(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return ["timed out", "connection reset", "unable to download webpage", "temporarily unavailable",
                "http error 5", "network is unreachable", "getaddrinfo", "incomplete", "read error", "broken pipe",
                "nodename nor servname", "remote end closed"].contains { lower.contains($0) }
    }
}
