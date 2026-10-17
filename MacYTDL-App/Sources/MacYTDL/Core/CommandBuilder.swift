import Foundation

/// Global (per-app) network & behaviour settings captured when a download starts.
struct EngineSettings {
    var cookieBrowser: CookieBrowser = .none
    var rateLimit: String = ""
    var proxy: String = ""
    var concurrentFragments: Int = 4
    var forceIPv4: Bool = false
    var restrictFilenames: Bool = false
    var trimFilenames: Int = 120
    var customArguments: String = ""
    var ffmpegPath: String?

    @MainActor
    static func current() -> EngineSettings {
        let p = Preferences.shared
        return EngineSettings(cookieBrowser: p.cookieBrowser, rateLimit: p.rateLimit, proxy: p.proxy,
                              concurrentFragments: p.concurrentFragments, forceIPv4: p.forceIPv4,
                              restrictFilenames: p.restrictFilenames, trimFilenames: p.trimFilenames,
                              customArguments: p.customArguments,
                              ffmpegPath: ToolManager.shared.path(for: .ffmpeg))
    }
}

enum CommandBuilder {
    static let progressPrefix = "MYTDL|"
    static let postprocessPrefix = "MYTDLPP|"
    static let infoPrefix = "MYTDLINFO|"
    static let filePrefix = "MYTDLFILE|"
    /// Free-text fields (titles, channel names) may contain "|", so info lines use the ASCII unit separator.
    static let fieldSeparator = "\u{1F}"
    static let infoFields = ["%(id)s", "%(format_id|)s", "%(duration|)s", "%(playlist_index|)s", "%(n_entries|)s",
                             "%(thumbnail|)s", "%(uploader,channel|)s", "%(webpage_url|)s", "%(title)s"]

    /// Arguments shared by downloads and metadata queries.
    static func commonArguments(_ settings: EngineSettings) -> [String] {
        var args: [String] = ["--no-colors", "--ignore-config"]
        if settings.cookieBrowser != .none {
            args += ["--cookies-from-browser", settings.cookieBrowser.rawValue]
        }
        let proxy = settings.proxy.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty { args += ["--proxy", proxy] }
        if settings.forceIPv4 { args.append("--force-ipv4") }
        if let ffmpeg = settings.ffmpegPath {
            args += ["--ffmpeg-location", ffmpeg]
        }
        return args
    }

    static func downloadArguments(for request: DownloadRequest, settings: EngineSettings,
                                  archive: URL? = nil, subscriptionLimit: Int? = nil) -> [String] {
        let o = request.options
        var args = commonArguments(settings)

        // Machine readable progress + final file names.
        args += [
            "--newline", "--no-quiet", "--progress", "--progress-delta", "0.4",
            "--progress-template",
            "download:\(progressPrefix)%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.fragment_index)s|%(progress.fragment_count)s|%(info.playlist_index)s|%(info.n_entries)s",
            "--progress-template",
            "postprocess:\(postprocessPrefix)%(progress.status)s|%(progress.postprocessor)s",
            "--print",
            "video:" + infoPrefix + infoFields.joined(separator: fieldSeparator),
            "--print", "after_move:\(filePrefix)%(filepath)s",
        ]

        // Robustness.
        args += ["--retries", "10", "--fragment-retries", "10", "--extractor-retries", "3",
                 "--retry-sleep", "fragment:exp=1:20", "--continue", "--no-mtime",
                 "--trim-filenames", String(max(40, settings.trimFilenames))]
        if settings.concurrentFragments > 1 {
            args += ["--concurrent-fragments", String(settings.concurrentFragments)]
        }
        let rate = settings.rateLimit.trimmingCharacters(in: .whitespaces)
        if !rate.isEmpty { args += ["--limit-rate", rate] }
        if settings.restrictFilenames { args.append("--restrict-filenames") }

        // Format selection.
        args += formatArguments(o)

        // Extras.
        if o.embedMetadata { args.append("--embed-metadata") }
        if o.embedChapters { args.append("--embed-chapters") }
        // WebM and WAV cannot carry cover art.
        let canEmbedThumbnail = o.preset.isAudio ? o.preset != .audioWAV : o.container != .webm
        if o.embedThumbnail && canEmbedThumbnail { args.append("--embed-thumbnail") }
        if o.writeThumbnailFile { args += ["--write-thumbnail", "--convert-thumbnails", "jpg"] }
        if o.writeDescription { args.append("--write-description") }
        if o.subtitles {
            args.append("--write-subs")
            if o.autoSubtitles { args.append("--write-auto-subs") }
            let langs = o.subtitleLanguages.replacingOccurrences(of: " ", with: "")
            args += ["--sub-langs", langs.isEmpty ? "all,-live_chat" : langs]
            if o.embedSubtitles && !o.preset.isAudio {
                args.append("--embed-subs")
            } else {
                args += ["--convert-subs", "srt"]
            }
        }
        switch o.sponsorBlock {
        case .off: break
        case .mark: args += ["--sponsorblock-mark", "all"]
        case .remove: args += ["--sponsorblock-remove", "sponsor,selfpromo,interaction,intro,outro,preview,music_offtopic"]
        }
        if o.hasClip {
            let start = o.clipStart.trimmingCharacters(in: .whitespaces)
            let end = o.clipEnd.trimmingCharacters(in: .whitespaces)
            args += ["--download-sections", "*\(start.isEmpty ? "0" : start)-\(end.isEmpty ? "inf" : end)",
                     "--force-keyframes-at-cuts"]
        }

        // Playlist handling.
        if case .subscription = request.kind {
            args.append("--yes-playlist")
            if let archive { args += ["--download-archive", archive.path, "--break-on-existing"] }
            if let subscriptionLimit { args += ["--playlist-end", String(subscriptionLimit)] }
            args += ["--match-filter", "!is_live & live_status!=is_upcoming"]
        } else if o.downloadPlaylist || request.isPlaylist {
            args.append("--yes-playlist")
            let items = o.playlistItems.trimmingCharacters(in: .whitespaces)
            if !items.isEmpty { args += ["--playlist-items", items] }
        } else {
            args.append("--no-playlist")
        }

        // Output location.
        let folder = o.folder.isEmpty ? Preferences.standardDownloadFolder : o.folder
        args += ["--paths", folder]
        var template = o.filenameStyle.template(custom: o.customTemplate)
        let isPlaylistDownload: Bool = {
            if case .subscription = request.kind { return true }
            return o.downloadPlaylist || request.isPlaylist
        }()
        if isPlaylistDownload && o.playlistSubfolder {
            template = "%(playlist_title,playlist|Playlist)s/%(playlist_index|0)03d - " + template
        }
        if o.hasClip {
            template = template.replacingOccurrences(of: ".%(ext)s", with: " (\(clipLabel(o))).%(ext)s")
        }
        args += ["--output", template]

        args += splitArguments(settings.customArguments)
        args += ["--", request.url]
        return args
    }

    static func formatArguments(_ o: DownloadOptions) -> [String] {
        if let audio = o.preset.audioFormat {
            var args = ["--format", "bestaudio/best", "--extract-audio", "--audio-format", audio]
            if audio != "best" && audio != "flac" && audio != "wav" {
                args += ["--audio-quality", "0"]
            }
            return args
        }
        var args: [String] = []
        let container = o.container.rawValue
        switch o.preset {
        case .appleCompatible:
            args += ["--format", "bv*[vcodec^=avc]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b",
                     "--format-sort", "vcodec:h264,res,acodec:aac"]
            args += ["--merge-output-format", "mp4", "--remux-video", "mp4"]
            return args
        default:
            if let height = o.preset.maxHeight {
                args += ["--format", "bv*[height<=\(height)]+ba/b[height<=\(height)]/bv*+ba/b"]
            } else {
                args += ["--format", "bv*+ba/b"]
            }
        }
        if o.container == .mp4 || o.container == .mov {
            // Prefer codecs that QuickTime can play when quality is equal.
            args += ["--format-sort", "res,fps,vcodec:h265,acodec:aac"]
        }
        args += ["--merge-output-format", container]
        if o.container == .mov { args += ["--remux-video", "mov"] }
        return args
    }

    static func clipLabel(_ o: DownloadOptions) -> String {
        let start = o.clipStart.isEmpty ? "0" : o.clipStart
        let end = o.clipEnd.isEmpty ? "end" : o.clipEnd
        return "\(start)-\(end)".replacingOccurrences(of: ":", with: ".")
    }

    /// Metadata query used by the preview card.
    static func infoArguments(url: String, playlist: Bool, settings: EngineSettings) -> [String] {
        var args = commonArguments(settings)
        args += ["--dump-single-json", "--flat-playlist", "--no-warnings", "--skip-download"]
        args.append(playlist ? "--yes-playlist" : "--no-playlist")
        args += ["--", url]
        return args
    }

    static func searchArguments(query: String, count: Int, settings: EngineSettings) -> [String] {
        var args = commonArguments(settings)
        args += ["--dump-single-json", "--flat-playlist", "--no-warnings", "--skip-download",
                 "--", "ytsearch\(count):\(query)"]
        return args
    }

    /// Shell-like splitting that honours single and double quotes.
    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        var escaping = false
        for ch in text {
            if escaping { current.append(ch); escaping = false; hasToken = true; continue }
            if ch == "\\" && quote != "'" { escaping = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; hasToken = true; continue }
            if ch.isWhitespace {
                if hasToken || !current.isEmpty { result.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken || !current.isEmpty { result.append(current) }
        return result
    }

    /// Human readable command (for "Copy command" in the log viewer).
    static func displayCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map { arg in
            if arg.rangeOfCharacter(from: CharacterSet(charactersIn: " \"'$|&;()<>*?[]#~%")) != nil {
                return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return arg
        }.joined(separator: " ")
    }
}
