import SwiftUI
import AppKit

/// Sample content for screenshots (`-LassoDemo <page> -LassoSnapshot <file.png>`).
/// Nothing is saved while demo mode is active.
@MainActor
enum DemoMode {
    static var page: String? { UserDefaults.standard.string(forKey: "LassoDemo") }
    static var isActive: Bool { page != nil }
    static var snapshotPath: String? { UserDefaults.standard.string(forKey: "LassoSnapshot") }

    private static let thumbs = [
        "https://i.ytimg.com/vi/aqz-KE-bpKQ/mqdefault.jpg",
        "https://i.ytimg.com/vi/jNQXAC9IVRw/mqdefault.jpg",
        "https://i.ytimg.com/vi/eRsGyueVLvQ/mqdefault.jpg",
        "https://i.ytimg.com/vi/YE7VzlLtp-4/mqdefault.jpg",
        "https://i.ytimg.com/vi/TLkA0RELQ1g/mqdefault.jpg",
        "https://i.ytimg.com/vi/R6MlUcmOul8/mqdefault.jpg",
    ]

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("demo: \(message)\n".utf8))
    }

    /// Set by `-LassoTraceRenders YES`: views log why they re-render (diagnoses update loops).
    static var traceRenders: Bool { UserDefaults.standard.bool(forKey: "LassoTraceRenders") }

    static func applyIfRequested() {
        guard let page else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        log("page \(page), windows: \(NSApp.windows.count)")
        let appState = AppState.shared
        appState.showOnboarding = page == "onboarding"
        fillQueue()
        let library = fillLibrary()
        let defaults = UserDefaults.standard
        defaults.set(page == "albums" ? LibraryGrouping.album.rawValue : LibraryGrouping.none.rawValue, forKey: "libraryGrouping")
        defaults.set(page == "albums" ? LibrarySort.album.rawValue : LibrarySort.date.rawValue, forKey: "librarySort")
        defaults.set(page != "albums", forKey: "libraryGrid")
        switch page {
        case "queue": appState.selection = .queue
        case "library", "albums": appState.selection = .library
        case "collection":
            appState.selection = .library
            if let collection = LibraryStore.shared.collections.first { appState.libraryScope = .collection(collection.id) }
        case "player", "playerwindow":
            appState.selection = .library
            let songs = library.filter(\.isAudio)
            PlayerController.shared.injectDemo(songs, index: 1, time: 83, duration: songs[1].duration ?? 200)
            if page == "playerwindow" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated { AppState.shared.openPlayerWindow?() }
                }
            }
        case "music":
            appState.selection = .music
            fillMusic()
        case "search":
            appState.selection = .search
            let search = SearchModel.shared
            search.query = "Blender open movies"
            search.results = (0..<6).map { i in
                PlaylistEntry(id: "s\(i)", videoID: "s\(i)", ieKey: "Youtube", index: i + 1,
                              title: ["Big Buck Bunny 4K", "Sintel – Open Movie", "Tears of Steel", "Spring – Blender Open Movie", "Cosmos Laundromat", "Agent 327"][i],
                              url: "https://www.youtube.com/watch?v=s\(i)", duration: Double(600 + i * 97),
                              thumbnail: thumbs[i], uploader: "Blender Studio", viewCount: 1_200_000 / (i + 1))
            }
        case "subscriptions":
            appState.selection = .subscriptions
            let store = SubscriptionStore.shared
            store.subscriptions = [
                Subscription(url: "https://www.youtube.com/@BlenderStudio/videos", title: "Blender Studio", thumbnail: thumbs[0],
                             preset: .fhd1080, intervalHours: 6, lastChecked: Date().addingTimeInterval(-1800), lastNewCount: 2, totalDownloaded: 14),
                Subscription(url: "https://www.youtube.com/playlist?list=PL-demo", title: "Lo-fi beats to study to", thumbnail: thumbs[3],
                             preset: .audioM4A, intervalHours: 24, lastChecked: Date().addingTimeInterval(-7200), totalDownloaded: 42),
            ]
        case "preview":
            appState.selection = .home
            let home = HomeModel.shared
            home.urlText = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
            home.smartCommand = "nur 1080p, deutsche Untertitel, ohne Sponsoren"
            home.info = MediaInfo(id: "aqz-KE-bpKQ", url: home.urlText, title: "Big Buck Bunny 60fps 4K – Official Blender Foundation Short Film",
                                  uploader: "Blender", duration: 635, thumbnail: thumbs[0], viewCount: 18_400_000, likeCount: 120_000,
                                  uploadDate: Date().addingTimeInterval(-86400 * 900), description: nil, extractor: "Youtube",
                                  qualities: [QualityOption(height: 2160, estimatedBytes: 1_450_000_000, fps: 60, hdr: false),
                                              QualityOption(height: 1440, estimatedBytes: 690_000_000, fps: 60, hdr: false),
                                              QualityOption(height: 1080, estimatedBytes: 320_000_000, fps: 60, hdr: false),
                                              QualityOption(height: 720, estimatedBytes: 160_000_000, fps: 60, hdr: false),
                                              QualityOption(height: 480, estimatedBytes: 70_000_000, fps: 30, hdr: false)],
                                  bestAudioBytes: 10_200_000, hasSubtitles: ["de", "en", "fr"], chapters: 6)
            var suggestion = RuleParser.parse(home.smartCommand)
            suggestion.apply(to: &home.options)
            home.smartSummary = suggestion.summary
            suggestion.usedOnDeviceModel = false
        default:
            appState.selection = .home
        }
        if page == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    if let open = AppState.shared.openSettingsWindow {
                        open()
                    } else {
                        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
            }
        }
        if let path = snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                MainActor.assumeIsolated { snapshot(to: path) }
            }
        }
    }

    private static func fillQueue() {
        func task(_ title: String, _ state: TaskState, _ progress: Double, thumb: Int, preset: QualityPreset = .best,
                  speed: Double? = nil, eta: Int? = nil, total: Int64? = nil, detail: String = "") -> DownloadTask {
            var options = Preferences.shared.newOptions()
            options.preset = preset
            let t = DownloadTask(request: DownloadRequest(url: "https://www.youtube.com/watch?v=demo\(thumb)", options: options))
            t.title = title
            t.state = state
            t.progress = progress
            t.thumbnail = thumbs[thumb]
            t.uploader = "Blender Studio"
            t.speed = speed
            t.eta = eta
            t.totalBytes = total
            t.downloadedBytes = Int64(Double(total ?? 0) * progress)
            t.detail = detail
            if state == .failed {
                t.errorMessage = ErrorAdvisor.explain("ERROR: [youtube] demo: Sign in to confirm you’re not a bot")
            }
            return t
        }
        DownloadManager.shared.injectDemo([
            task("Cosmos Laundromat – First Cycle", .completed, 1, thumb: 4),
            task("Agent 327: Operation Barbershop", .failed, 0.12, thumb: 5),
            task("Tears of Steel", .processing, 0.99, thumb: 2, detail: String(localized: "Merging video and audio…")),
            task("Lo-fi Session #12", .downloading, 0.38, thumb: 3, preset: .audioMP3, speed: 2_400_000, eta: 41, total: 96_000_000),
            task("Big Buck Bunny 60fps 4K", .downloading, 0.64, thumb: 0, preset: .uhd2160, speed: 18_700_000, eta: 52, total: 1_450_000_000),
            task("Sintel – Open Movie", .queued, 0, thumb: 1),
        ])
    }

    @discardableResult
    private static func fillLibrary() -> [LibraryItem] {
        func video(_ i: Int, _ title: String, _ uploader: String, minutes: Double, plays: Int = 0, favorite: Bool = false) -> LibraryItem {
            LibraryItem(url: "https://www.youtube.com/watch?v=demo\(i)", title: title, filePath: "/tmp/lasso-demo/\(title).mp4",
                        thumbnail: thumbs[i % thumbs.count], uploader: uploader, duration: minutes * 60, isAudio: false,
                        fileSize: Int64(minutes * 38_000_000), date: Date().addingTimeInterval(Double(-3600 * i * 7)),
                        favorite: favorite, playCount: plays, source: "YouTube")
        }
        func song(_ i: Int, _ title: String, _ artist: String, album: String, track: Int, seconds: Double, thumb: Int,
                  plays: Int = 0, favorite: Bool = false) -> LibraryItem {
            LibraryItem(url: "https://open.spotify.com/track/demo\(i)", title: title, filePath: "/tmp/lasso-demo/\(title).mp3",
                        thumbnail: thumbs[thumb], uploader: artist, duration: seconds, isAudio: true,
                        fileSize: Int64(seconds * 40_000), date: Date().addingTimeInterval(Double(-3600 * i * 3)),
                        artist: artist, album: album, trackNumber: track, favorite: favorite, playCount: plays,
                        lastPlayed: plays > 0 ? Date().addingTimeInterval(Double(-600 * i)) : nil, source: "Spotify")
        }
        let items = [
            video(0, "Big Buck Bunny 60fps 4K", "Blender Studio", minutes: 10.6, plays: 4, favorite: true),
            song(1, "Main Theme", "Jan Morgenstern", album: "Open Movie Soundtracks", track: 1, seconds: 214, thumb: 0, plays: 12, favorite: true),
            song(2, "Sintel – End Credits", "Jan Morgenstern", album: "Open Movie Soundtracks", track: 2, seconds: 246, thumb: 1, plays: 7),
            song(3, "Elephants Dream Suite", "Jan Morgenstern", album: "Open Movie Soundtracks", track: 3, seconds: 302, thumb: 2),
            video(4, "Sintel – Open Movie", "Blender Studio", minutes: 14.8, plays: 1),
            song(5, "Rainy Window", "Nightdrive Collective", album: "Lo-fi Sessions", track: 1, seconds: 168, thumb: 3, plays: 21, favorite: true),
            song(6, "Late Night Coding", "Nightdrive Collective", album: "Lo-fi Sessions", track: 2, seconds: 192, thumb: 3, plays: 9),
            song(7, "Lo-fi Session #12", "Nightdrive Collective", album: "Lo-fi Sessions", track: 3, seconds: 1_820, thumb: 3),
            video(8, "Cosmos Laundromat", "Blender Studio", minutes: 12.2),
            video(9, "Agent 327: Operation Barbershop", "Blender Studio", minutes: 3.9, favorite: true),
            video(10, "Me at the zoo", "jawed", minutes: 0.3, plays: 2),
            video(11, "Tears of Steel", "Blender Studio", minutes: 12.1),
        ]
        let roadtrip = LibraryCollection(name: "Roadtrip 2030", itemIDs: [items[5].id, items[1].id, items[6].id, items[2].id, items[7].id])
        let watchLater = LibraryCollection(name: String(localized: "Watch later"), itemIDs: [items[8].id, items[11].id])
        LibraryStore.shared.replaceAll(items, collections: [roadtrip, watchLater])
        // Empty placeholder files, so cards don't show "File missing".
        try? FileManager.default.createDirectory(atPath: "/tmp/lasso-demo", withIntermediateDirectories: true)
        for item in items where !item.fileExists { FileManager.default.createFile(atPath: item.filePath, contents: Data()) }
        return items
    }

    private static func fillMusic() {
        let music = MusicModel.shared
        let songs: [(String, Int)] = [("Main Theme", 214), ("Sintel – End Credits", 246), ("Elephants Dream Suite", 302),
                                      ("Tears of Steel – Overture", 188), ("Cosmos Laundromat", 233), ("Spring", 207),
                                      ("Caminandes Llama Drama", 161), ("Agent 327 – Barbershop", 179), ("Hero", 254)]
        let tracks = songs.enumerated().map { i, song in
            MusicTrack(title: song.0, artists: i == 5 ? ["Jan Morgenstern", "Blender Studio Orchestra"] : ["Jan Morgenstern"],
                       album: "Open Movie Soundtracks", albumArtist: "Jan Morgenstern", trackNumber: i + 1, trackCount: songs.count,
                       durationMs: song.1 * 1000, releaseYear: "2024", coverURL: thumbs[0], sourceURL: "https://open.spotify.com/track/demo\(i)",
                       explicit: false)
        }
        let collection = MusicCollection(id: "demo", kind: .album, name: "Open Movie Soundtracks", owner: "Jan Morgenstern",
                                         coverURL: thumbs[0], sourceURL: "https://open.spotify.com/album/demo", tracks: tracks)
        music.urlText = collection.sourceURL
        music.collection = collection
        music.isSpotify = true
        music.rows = tracks.enumerated().map { MusicRow(track: $0.element, directURL: nil, thumbnail: thumbs[0], originalIndex: $0.offset) }
        music.selected = Set(music.rows.dropLast(2).map(\.id))
    }

    /// Renders the key window into a PNG (no screen-recording permission needed), then quits.
    static func snapshot(to path: String) {
        log("snapshot – windows: \(NSApp.windows.map { "\($0.title) \(Int($0.frame.width))x\(Int($0.frame.height)) visible=\($0.isVisible)" })")
        let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }
        let window = page == "settings" || page == "playerwindow"
            ? (candidates.first { $0.title != "Lasso" } ?? NSApp.keyWindow)
            : (candidates.first { $0.title == "Lasso" } ?? NSApp.keyWindow ?? candidates.first)
        if let window, let view = window.contentView?.superview ?? window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            try? "\(window.windowNumber)".write(toFile: path + ".wid", atomically: true, encoding: .utf8)
            log("wrote \(path)")
        } else {
            log("no window to capture")
            try? "0".write(toFile: path + ".wid", atomically: true, encoding: .utf8)
        }
        // Give an external `screencapture -l` a moment, then quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }
}
