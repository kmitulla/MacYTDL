import Foundation
import AVFoundation

/// Headless end-to-end test used by CI: `Lasso --selftest <folder>`.
/// Runs real downloads through the same engine the app uses.
@MainActor
enum SelfTest {
    nonisolated static func run(outputFolder: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let ok = await runAll(outputFolder: outputFolder)
            print(ok ? "SELFTEST PASSED" : "SELFTEST FAILED")
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    private static var failures: [String] = []
    private static var warnings: [String] = []

    private static func check(_ condition: Bool, _ message: String) {
        print((condition ? "  ✓ " : "  ✗ ") + message)
        if !condition { failures.append(message) }
    }

    private static func warn(_ message: String) {
        print("  ! " + message)
        warnings.append(message)
    }

    static func runAll(outputFolder: String) async -> Bool {
        print("== Lasso self-test")
        print("bundle: \(Bundle.main.bundlePath)")
        let manager = DownloadManager.shared
        manager.headless = true
        try? FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)

        unitTests()

        print("== Components")
        let tools = ToolManager.shared
        await tools.installBundledToolsIfNeeded()
        await tools.refreshVersions()
        for tool in HelperTool.allCases {
            let status = tools.status[tool]
            check(status?.version != nil, "\(tool.displayName): \(status?.version ?? "missing") @ \(status?.path ?? "-")")
        }
        if let ytdlp = tools.ytdlpPath {
            check(MachO.runsOnThisMac(URL(fileURLWithPath: ytdlp)), "Mach-O check accepts yt-dlp for this Mac")
            let verbose = await ProcessRunner.run(ytdlp, ["-v", "--ignore-config", "--simulate", "--no-warnings",
                                                          "--ffmpeg-location", tools.path(for: .ffmpeg) ?? "ffmpeg",
                                                          "https://example.invalid/"],
                                                  environment: tools.environment, timeout: 60)
            let lines = (verbose.stdout + "\n" + verbose.stderr).split(separator: "\n")
            for line in lines where line.contains("JS runtimes") || line.contains("exe versions") {
                print("  \(line)")
            }
            let runtimes = lines.first(where: { $0.contains("JS runtimes") }) ?? ""
            check(runtimes.lowercased().contains("deno"), "yt-dlp detects the bundled deno runtime")
        }
        print("  certificates: \(ToolManager.certificateBundle ?? "none")")
        check(ToolManager.certificateBundle != nil, "CA certificate bundle available for FFmpeg")

        print("== Metadata")
        // Small public test videos *with* an audio track (needed for the audio test).
        let sampleURLs = [
            "https://www.w3schools.com/html/mov_bbb.mp4",
            "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4",
            "https://download.samplelib.com/mp4/sample-5s.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
        ]
        var sample: String?
        for url in sampleURLs {
            do {
                let info = try await MetadataService.fetch(url: url, playlist: false)
                print("  info: \(info.title) (\(info.extractor ?? "?"))")
                sample = url
                break
            } catch {
                warn("metadata for \(url) failed: \(error.localizedDescription)")
            }
        }
        check(sample != nil, "metadata extraction works for a direct video link")

        if let sample {
            print("== Video download (Apple compatible MP4)")
            var options = DownloadOptions()
            options.folder = (outputFolder as NSString).appendingPathComponent("video")
            options.preset = .appleCompatible
            options.embedThumbnail = false
            let video = await download(sample, options: options)
            check(video.state == .completed, "video download completed (\(video.state.rawValue)) \(video.errorMessage ?? "")")
            check(video.outputFiles.contains { fileSize($0) > 10_000 }, "video file written: \(video.outputFiles)")
            check(video.progress >= 0.99, "progress reached 100 % (\(video.progress))")
            check(LibraryStore.shared.items.contains { video.outputFiles.contains($0.filePath) }, "file registered in library")

            print("== Audio extraction (MP3 via ffmpeg/ffprobe)")
            var audioOptions = DownloadOptions()
            audioOptions.folder = (outputFolder as NSString).appendingPathComponent("audio")
            audioOptions.preset = .audioMP3
            audioOptions.embedThumbnail = false
            let audio = await download(sample, options: audioOptions)
            check(audio.state == .completed, "audio download completed (\(audio.state.rawValue)) \(audio.errorMessage ?? "")")
            check(audio.outputFiles.contains { $0.lowercased().hasSuffix(".mp3") && fileSize($0) > 1_000 }, "mp3 written: \(audio.outputFiles)")

            print("== Clip (5 s section via ffmpeg)")
            var clipOptions = DownloadOptions()
            clipOptions.folder = (outputFolder as NSString).appendingPathComponent("clip")
            clipOptions.preset = .best
            clipOptions.clipStart = "0:02"
            clipOptions.clipEnd = "0:07"
            clipOptions.embedThumbnail = false
            let clip = await download(sample, options: clipOptions)
            check(clip.state == .completed, "clip download completed (\(clip.state.rawValue)) \(clip.errorMessage ?? "")")
            check(clip.outputFiles.contains { fileSize($0) > 1_000 }, "clip written: \(clip.outputFiles)")

            print("== Pause / resume / cancel")
            var pauseOptions = DownloadOptions()
            pauseOptions.folder = (outputFolder as NSString).appendingPathComponent("pause")
            Preferences.shared.rateLimit = "250K"
            let pauseTask = manager.add(url: sample, options: pauseOptions)
            Preferences.shared.rateLimit = ""
            await waitUntil(timeout: 60) { pauseTask.state == .downloading || pauseTask.state.isFinished }
            manager.pause(pauseTask)
            await waitUntil(timeout: 30) { pauseTask.state == .paused || pauseTask.state.isFinished }
            check(pauseTask.state == .paused || pauseTask.state == .completed, "pause works (\(pauseTask.state.rawValue))")
            manager.resume(pauseTask)
            await waitUntil(timeout: 300) { pauseTask.state.isFinished }
            check(pauseTask.state == .completed, "resume completes (\(pauseTask.state.rawValue)) \(pauseTask.errorMessage ?? "")")
        }

        if let sample {
            await mediaToolTests(sample: sample, outputFolder: outputFolder)
        }

        print("== HLS stream clip (informational)")
        var hlsOptions = DownloadOptions()
        hlsOptions.folder = (outputFolder as NSString).appendingPathComponent("hls")
        hlsOptions.preset = .sd480
        hlsOptions.clipStart = "0:00"
        hlsOptions.clipEnd = "0:06"
        hlsOptions.embedThumbnail = false
        let hls = await download("https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8",
                                 options: hlsOptions, timeout: 180)
        if hls.state == .completed {
            print("  ✓ HLS clip: \(hls.outputFiles)")
        } else {
            warn("HLS clip: \(hls.errorMessage ?? hls.state.rawValue)")
        }

        print("== Error handling")
        var badOptions = DownloadOptions()
        badOptions.folder = (outputFolder as NSString).appendingPathComponent("bad")
        let bad = await download("https://example.invalid/definitely-not-a-video", options: badOptions)
        check(bad.state == .failed, "invalid link fails cleanly (\(bad.state.rawValue))")
        print("  advice: \(bad.errorMessage?.replacingOccurrences(of: "\n", with: " ") ?? "-")")

        print("== YouTube (informational – CI IPs are often blocked by YouTube)")
        do {
            let info = try await MetadataService.fetch(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", playlist: false)
            print("  ✓ YouTube metadata: \(info.title) – \(info.qualities.count) qualities, max \(info.maxHeight ?? 0)p")
            var ytOptions = DownloadOptions()
            ytOptions.folder = (outputFolder as NSString).appendingPathComponent("youtube")
            ytOptions.preset = .audioM4A
            let yt = await download("https://www.youtube.com/watch?v=jNQXAC9IVRw", options: ytOptions, timeout: 240)
            if yt.state == .completed {
                print("  ✓ YouTube download: \(yt.outputFiles)")
            } else {
                warn("YouTube download: \(yt.errorMessage ?? yt.state.rawValue)")
            }
        } catch {
            warn("YouTube metadata: \(error.localizedDescription)")
        }

        await spotifyTests(outputFolder: outputFolder)

        print("== Summary")
        print("warnings: \(warnings.count)")
        for failure in failures { print("FAILED: \(failure)") }
        return failures.isEmpty
    }

    private static func download(_ url: String, options: DownloadOptions, timeout: TimeInterval = 300) async -> DownloadTask {
        let task = DownloadManager.shared.add(url: url, options: options)
        await waitUntil(timeout: timeout) { task.state.isFinished }
        if !task.state.isFinished { DownloadManager.shared.cancel(task) }
        if task.state != .completed {
            print("  --- log tail ---")
            for line in task.logLines.suffix(25) { print("  | \(line)") }
        }
        return task
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Tags, metadata, conversion and numbered playlist downloads with .m3u8.
    private static func mediaToolTests(sample: String, outputFolder: String) async {
        let tools = ToolManager.shared
        guard let ffmpeg = tools.path(for: .ffmpeg), let ffprobe = tools.path(for: .ffprobe) else {
            check(false, "ffmpeg/ffprobe available for media tools")
            return
        }
        print("== Tags (write + read back)")
        let mp3 = LibraryStore.shared.items.first { $0.filePath.lowercased().hasSuffix(".mp3") }?.filePath
        if let mp3 {
            let tags = MediaTags(title: "Lasso Test", artist: "CI Artist", album: "Self-Test Album", albumArtist: "CI",
                                 trackNumber: 3, trackCount: 9, year: "2026")
            let written = await TagWriter.write(tags, to: mp3, ffmpeg: ffmpeg)
            check(written, "tags written into \((mp3 as NSString).lastPathComponent)")
            let meta = await MetadataReader.read(mp3, ffprobe: ffprobe)
            check(meta?.tags.title == "Lasso Test" && meta?.tags.artist == "CI Artist" && meta?.tags.album == "Self-Test Album"
                  && meta?.tags.trackNumber == 3, "tags read back: \(String(describing: meta?.tags))")
            check((meta?.duration ?? 0) > 1, "duration read with ffprobe: \(meta?.duration ?? 0)")
        } else {
            check(false, "an mp3 from the audio test exists for tagging")
        }

        print("== Converter")
        if let video = LibraryStore.shared.items.first(where: { $0.filePath.lowercased().hasSuffix(".mp4") })?.filePath {
            let m4a = await MediaConverter.convert(video, to: .m4a, ffmpeg: ffmpeg)
            check(m4a != nil && fileSize(m4a ?? "") > 1_000, "mp4 → m4a: \(m4a ?? "failed")")
            if let m4a {
                let playable = (try? await AVURLAsset(url: URL(fileURLWithPath: m4a)).load(.isPlayable)) ?? false
                check(playable, "converted file is playable by AVFoundation")
            }
        }

        print("== Numbered playlist download + .m3u8")
        var options = DownloadOptions()
        options.folder = (outputFolder as NSString).appendingPathComponent("playlist")
        options.preset = .audioM4A
        options.embedThumbnail = false
        options.createM3U = true
        options.skipExisting = true
        let collection = MusicCollection(id: "selftest", kind: .playlist, name: "Lasso Test Playlist", owner: nil, coverURL: nil,
                                         sourceURL: "https://example.com/lasso-selftest-\(UUID().uuidString)", tracks: [])
        let manager = DownloadManager.shared
        let before = manager.tasks.count
        manager.addPlaylistItems(collection, items: [(sample, "Sample A", nil), (sample + "?copy=2", "Sample B", nil)],
                                 options: options, ownFolder: true)
        let added = Array(manager.tasks.dropFirst(before))
        await waitUntil(timeout: 300) { added.allSatisfy { $0.state.isFinished } }
        let files = added.compactMap { $0.outputFiles.last }
        check(added.allSatisfy { $0.state == .completed }, "playlist items completed: \(added.map { $0.state.rawValue })")
        check(files.contains { ($0 as NSString).lastPathComponent.hasPrefix("01 - ") }, "files are numbered: \(files.map { ($0 as NSString).lastPathComponent })")
        let m3u = ((options.folder as NSString).appendingPathComponent("Lasso Test Playlist") as NSString).appendingPathComponent("Lasso Test Playlist.m3u8")
        let playlist = (try? String(contentsOfFile: m3u, encoding: .utf8)) ?? ""
        check(playlist.contains("#EXTM3U") && playlist.contains("01 - "), "m3u8 written: \(playlist.split(separator: "\n").count) lines")
    }

    private static func spotifyTests(outputFolder: String) async {
        print("== Spotify (parsing offline)")
        let parsed = [
            SpotifyService.parse("https://open.spotify.com/intl-de/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc"),
            SpotifyService.parse("spotify:album:4aawyAB9vmqN3uQ7FjRGTy"),
            SpotifyService.parse("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"),
        ]
        check(parsed[0]?.kind == "playlist" && parsed[0]?.id == "37i9dQZF1DXcBWIGoYBM5M", "parse intl playlist link")
        check(parsed[1]?.kind == "album" && parsed[1]?.id == "4aawyAB9vmqN3uQ7FjRGTy", "parse spotify: URI")
        check(parsed[2]?.kind == "track", "parse track link")
        let fixture = """
        <html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"album","name":"Test Album","subtitle":"Artist A","visualIdentity":{"image":[{"url":"https://example.com/a.jpg","maxWidth":300}]},"trackList":[{"uri":"spotify:track:1","title":"Song One","subtitle":"Artist A,\u00a0Artist B","duration":185000,"isExplicit":false},{"uri":"spotify:track:2","title":"Song Two","subtitle":"Artist A","duration":200000,"isExplicit":true}]}}}}}}</script></html>
        """
        if let album = try? SpotifyService.parseEmbed(html: fixture, kind: .album, id: "x") {
            check(album.tracks.count == 2 && album.tracks[0].artists == ["Artist A", "Artist B"] && album.tracks[1].trackNumber == 2
                  && album.tracks[0].album == "Test Album", "embed JSON parsed (artists, album, track numbers)")
            check(MusicNaming.baseName(for: album.tracks[0], number: 1, total: 12) == "01 - Artist A - Song One", "music file naming")
        } else {
            check(false, "embed JSON parsed")
        }

        print("== Spotify live (informational)")
        do {
            let track = try await SpotifyService.fetch("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
            print("  ✓ Spotify track: \(track.tracks.first?.artistLine ?? "?") – \(track.name) (\(track.tracks.first?.durationMs ?? 0) ms)")
            let album = try await SpotifyService.fetch("https://open.spotify.com/album/4aawyAB9vmqN3uQ7FjRGTy")
            print("  ✓ Spotify album: \(album.name) – \(album.tracks.count) songs, cover: \(album.coverURL != nil)")
            var options = DownloadOptions()
            options.folder = (outputFolder as NSString).appendingPathComponent("spotify")
            options.preset = .audioM4A
            let manager = DownloadManager.shared
            let before = manager.tasks.count
            manager.addMusic(track, tracks: track.tracks, options: options, ownFolder: false)
            let added = Array(manager.tasks.dropFirst(before))
            await waitUntil(timeout: 300) { added.allSatisfy { $0.state.isFinished } }
            if let task = added.first, task.state == .completed {
                print("  ✓ matched on YouTube Music and downloaded: \(task.outputFiles)")
            } else {
                warn("Spotify song download (YouTube blocks CI servers): \(added.first?.errorMessage ?? "?")")
            }
        } catch {
            warn("Spotify live: \(error.localizedDescription)")
        }
    }

    private static func unitTests() {
        print("== Unit checks")
        let s1 = RuleParser.parse("nur audio als mp3 von 1:20 bis 3:00 ohne werbung")
        check(s1.preset == .audioMP3 && s1.clipStart == "1:20" && s1.clipEnd == "3:00" && s1.sponsorBlock == .remove,
              "rule parser (de): \(s1.summary)")
        let s2 = RuleParser.parse("1080p with english subtitles, whole playlist")
        check(s2.preset == .fhd1080 && s2.subtitles == true && s2.subtitleLanguages == "en" && s2.downloadPlaylist == true,
              "rule parser (en): \(s2.summary)")
        let s3 = RuleParser.parse("für iPhone, die ersten 2 minuten")
        check(s3.preset == .appleCompatible && s3.clipStart == "0:00" && s3.clipEnd == "2:00", "rule parser (clip): \(s3.summary)")
        check(CommandBuilder.splitArguments(#"--foo "a b" 'c d' e\ f"#) == ["--foo", "a b", "c d", "e f"], "argument splitting")
        let urls = URLTools.extractURLs(from: "see https://youtu.be/abc and\nhttps://vimeo.com/123 and https://youtu.be/abc")
        check(urls == ["https://youtu.be/abc", "https://vimeo.com/123"], "URL extraction: \(urls)")
        check(URLTools.normalize("youtube.com/@BlenderStudio") == "https://www.youtube.com/@BlenderStudio/videos", "channel URL normalisation")
        check(URLTools.hasVideoAndPlaylist("https://www.youtube.com/watch?v=x&list=y"), "video+playlist detection")
        check(ErrorAdvisor.explain("ERROR: [youtube] x: Sign in to confirm you’re not a bot").contains("Cookies") ||
              ErrorAdvisor.explain("ERROR: [youtube] x: Sign in to confirm you’re not a bot").lowercased().contains("cookie"),
              "error advisor recognises bot check")
        check(Format.parseTimecode("1:02:03") == 3723, "timecode parsing")
        let args = CommandBuilder.downloadArguments(for: DownloadRequest(url: "https://example.com/v", options: DownloadOptions()),
                                                    settings: EngineSettings())
        check(args.last == "https://example.com/v" && args.contains("--no-playlist"), "command builder basics")
    }
}
