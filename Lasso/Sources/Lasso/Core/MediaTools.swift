import Foundation

struct MediaTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var trackCount: Int?
    var year: String?
}

/// Writes tags into media files with FFmpeg (stream copy - no re-encoding, cover art is kept).
enum TagWriter {
    @discardableResult
    static func write(_ tags: MediaTags, to path: String, ffmpeg: String) async -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let temp = url.deletingLastPathComponent().appendingPathComponent(".lasso-tags-\(UUID().uuidString.prefix(8)).\(ext)")
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", path, "-map", "0", "-c", "copy", "-map_metadata", "0"]
        func meta(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            args += ["-metadata", "\(key)=\(value)"]
        }
        meta("title", tags.title)
        meta("artist", tags.artist)
        meta("album", tags.album)
        meta("album_artist", tags.albumArtist)
        if let n = tags.trackNumber { meta("track", tags.trackCount.map { "\(n)/\($0)" } ?? "\(n)") }
        meta("date", tags.year)
        if ext.lowercased() == "mp3" { args += ["-id3v2_version", "3"] }
        if ["m4a", "mp4", "m4v", "mov"].contains(ext.lowercased()) { args += ["-movflags", "+faststart"] }
        args.append(temp.path)
        let result = await ProcessRunner.run(ffmpeg, args, timeout: 300)
        guard result.status == 0, FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }
}

struct FileMetadata {
    var duration: Double?
    var tags = MediaTags()
    var hasVideo = false
    var hasAudio = false
}

/// Reads metadata with ffprobe (works for every format, unlike AVFoundation).
enum MetadataReader {
    static func read(_ path: String, ffprobe: String) async -> FileMetadata? {
        let result = await ProcessRunner.run(ffprobe, ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path], timeout: 60)
        guard result.status == 0, let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var meta = FileMetadata()
        let format = json["format"] as? [String: Any] ?? [:]
        meta.duration = (format["duration"] as? String).flatMap(Double.init)
        let raw = format["tags"] as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        for (k, v) in raw { if let s = v as? String { tags[k.lowercased()] = s } }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            let attached = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            if type == "video" && !attached { meta.hasVideo = true }
            if type == "audio" { meta.hasAudio = true }
            // Ogg/Opus keep their tags on the stream.
            for (k, v) in stream["tags"] as? [String: Any] ?? [:] where tags[k.lowercased()] == nil {
                if let s = v as? String { tags[k.lowercased()] = s }
            }
        }
        meta.tags.title = tags["title"]
        meta.tags.artist = tags["artist"]
        meta.tags.album = tags["album"]
        meta.tags.albumArtist = tags["album_artist"]
        if let track = tags["track"] {
            let parts = track.split(separator: "/")
            meta.tags.trackNumber = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count > 1 { meta.tags.trackCount = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
        }
        meta.tags.year = (tags["date"] ?? tags["year"]).map { String($0.prefix(4)) }
        return meta
    }
}

/// Creates thumbnails for imported files (cover art or a frame from the video).
enum ThumbnailMaker {
    static var folder: URL { AppPaths.ensure(AppPaths.support.appendingPathComponent("Thumbnails", isDirectory: true)) }

    static func make(for path: String, id: UUID, duration: Double?, ffmpeg: String) async -> String? {
        let out = folder.appendingPathComponent("\(id.uuidString).jpg")
        let seek = max(0, (duration ?? 0) * 0.1)
        // First try embedded cover art, then a video frame.
        let cover = await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", path, "-an", "-map", "0:v:0",
                                                      "-frames:v", "1", "-vf", "scale=480:-2", out.path], timeout: 60)
        if cover.status == 0, FileManager.default.fileExists(atPath: out.path) { return out.absoluteString }
        let frame = await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.1f", seek), "-i", path,
                                                      "-frames:v", "1", "-vf", "scale=480:-2", out.path], timeout: 60)
        return frame.status == 0 && FileManager.default.fileExists(atPath: out.path) ? out.absoluteString : nil
    }
}

/// Sorts files into folders like "Artist/Album/01 - Title.mp3".
enum LibraryOrganizer {
    enum Pattern: String, CaseIterable, Identifiable {
        case artistAlbum, artist, album, source, type
        var id: String { rawValue }
        var title: String {
            switch self {
            case .artistAlbum: return String(localized: "Artist / Album / Title")
            case .artist: return String(localized: "Artist / Title")
            case .album: return String(localized: "Album / Title")
            case .source: return String(localized: "Website / Title")
            case .type: return String(localized: "Videos & Music / Title")
            }
        }
    }

    struct Move: Identifiable {
        var id: UUID { item.id }
        var item: LibraryItem
        var destination: String
    }

    static func plan(_ items: [LibraryItem], pattern: Pattern, root: String) -> [Move] {
        var used = Set<String>()
        return items.filter(\.fileExists).compactMap { item in
            let unknownArtist = String(localized: "Unknown artist")
            let unknownAlbum = String(localized: "Unknown album")
            var parts: [String] = []
            switch pattern {
            case .artistAlbum:
                parts = [item.artist ?? item.uploader ?? unknownArtist, item.album ?? unknownAlbum]
            case .artist:
                parts = [item.artist ?? item.uploader ?? unknownArtist]
            case .album:
                parts = [item.album ?? unknownAlbum]
            case .source:
                parts = [item.source ?? URLTools.displayHost(item.url)]
            case .type:
                parts = [item.isAudio ? String(localized: "Music") : String(localized: "Videos")]
            }
            var dir = root
            for part in parts { dir = (dir as NSString).appendingPathComponent(MusicNaming.sanitize(part)) }
            let fileName = (item.filePath as NSString).lastPathComponent
            var dest = (dir as NSString).appendingPathComponent(fileName)
            var counter = 2
            while (used.contains(dest) || FileManager.default.fileExists(atPath: dest)) && dest != item.filePath {
                let base = (fileName as NSString).deletingPathExtension
                dest = (dir as NSString).appendingPathComponent("\(base) (\(counter)).\(item.fileExtension)")
                counter += 1
            }
            used.insert(dest)
            return dest == item.filePath ? nil : Move(item: item, destination: dest)
        }
    }

    /// Performs the moves; returns the updated items.
    static func perform(_ moves: [Move]) -> [LibraryItem] {
        var updated: [LibraryItem] = []
        for move in moves {
            let dir = (move.destination as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: move.item.filePath, toPath: move.destination)
                var item = move.item
                item.filePath = move.destination
                updated.append(item)
            } catch {
                continue
            }
        }
        return updated
    }
}

enum DuplicateFinder {
    struct Group: Identifiable {
        var id: String
        var items: [LibraryItem]
    }

    static func find(_ items: [LibraryItem]) -> [Group] {
        func key(_ item: LibraryItem) -> String {
            let title = item.title.lowercased().filter { $0.isLetter || $0.isNumber }
            let seconds = Int(((item.duration ?? 0) / 3).rounded())
            return "\(title)|\(seconds)|\(item.isAudio)"
        }
        var byURL: [String: [LibraryItem]] = [:]
        var byKey: [String: [LibraryItem]] = [:]
        for item in items where item.fileExists {
            if !item.url.isEmpty { byURL[item.url + "|\(item.isAudio)", default: []].append(item) }
            byKey[key(item), default: []].append(item)
        }
        var seen = Set<UUID>()
        var groups: [Group] = []
        for (k, list) in byURL.merging(byKey, uniquingKeysWith: { $0 + $1 }) where list.count > 1 {
            let unique = list.filter { seen.insert($0.id).inserted }
            if unique.count > 1 { groups.append(Group(id: k, items: unique.sorted { $0.date > $1.date })) }
        }
        return groups.sorted { $0.items.count > $1.items.count }
    }
}

/// One-time migration from MacYTDL 2030 (settings, library, queue, helpers).
enum Migration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromMacYTDL") else { return }
        defer { defaults.set(true, forKey: "migratedFromMacYTDL") }
        if let old = UserDefaults(suiteName: "io.github.kmitulla.macytdl") {
            for key in Preferences.migratedKeys where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let oldDir = base.appendingPathComponent("MacYTDL")
        let newDir = base.appendingPathComponent("Lasso")
        if FileManager.default.fileExists(atPath: oldDir.path) && !FileManager.default.fileExists(atPath: newDir.path) {
            try? FileManager.default.moveItem(at: oldDir, to: newDir)
        }
    }
}
