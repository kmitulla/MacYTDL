import Foundation
import Security

/// An album, playlist or single song that Lasso can download track by track.
struct MusicCollection: Identifiable, Hashable {
    enum Kind: String { case track, album, playlist, artist }

    var id: String
    var kind: Kind
    var name: String
    var owner: String?
    var coverURL: String?
    var sourceURL: String
    var tracks: [MusicTrack]
    /// The embed page only returns the first 100 songs of long playlists.
    var possiblyTruncated = false

    var totalDuration: Double { tracks.compactMap(\.durationSeconds).reduce(0, +) }
}

enum SpotifyError: LocalizedError {
    case notSpotify
    case unsupported(String)
    case parse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notSpotify: return String(localized: "That isn't a Spotify link.")
        case .unsupported(let kind): return String(localized: "Spotify \(kind) links aren't supported – use songs, albums, playlists or artists.")
        case .parse: return String(localized: "Spotify answered unexpectedly. Please try again later.")
        case .http(let code): return String(localized: "Spotify returned error \(code).")
        }
    }
}

/// Reads song lists from Spotify. Audio itself is DRM-protected, so Lasso finds each song on YouTube Music
/// and tags the file with Spotify's metadata (the same approach as spotDL).
enum SpotifyService {
    static func isSpotify(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("spotify:") || t.contains("open.spotify.com/") || t.contains("spotify.link/") || t.contains("play.spotify.com/")
    }

    /// Accepts open.spotify.com/(intl-xx/)<kind>/<id>, spotify:<kind>:<id> and embed links.
    static func parse(_ text: String) -> (kind: String, id: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("spotify:") {
            let parts = t.split(separator: ":").map(String.init)
            if parts.count >= 3 { return (parts[parts.count - 2].lowercased(), parts[parts.count - 1]) }
            return nil
        }
        guard let url = URL(string: t) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") && $0 != "embed" }
        let kinds = ["track", "album", "playlist", "artist", "episode", "show"]
        guard let idx = parts.firstIndex(where: { kinds.contains($0.lowercased()) }), idx + 1 < parts.count else { return nil }
        return (parts[idx].lowercased(), parts[idx + 1])
    }

    static func fetch(_ text: String) async throws -> MusicCollection {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.lowercased().contains("spotify.link/"), let resolved = await resolveShortLink(link) {
            link = resolved
        }
        guard let (kindName, id) = parse(link) else { throw SpotifyError.notSpotify }
        guard let kind = MusicCollection.Kind(rawValue: kindName) else { throw SpotifyError.unsupported(kindName) }
        if let credentials = SpotifyAPI.credentials {
            if let collection = try? await SpotifyAPI.fetch(kind: kind, id: id, credentials: credentials) {
                return collection
            }
        }
        return try await fetchEmbed(kind: kind, id: id)
    }

    static func resolveShortLink(_ link: String) async -> String? {
        guard let url = URL(string: link.hasPrefix("http") ? link : "https://" + link) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return response.url?.absoluteString
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetchEmbed(kind: MusicCollection.Kind, id: String) async throws -> MusicCollection {
        let url = URL(string: "https://open.spotify.com/embed/\(kind.rawValue)/\(id)")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw SpotifyError.http(http.statusCode) }
        let html = String(decoding: data, as: UTF8.self)
        return try parseEmbed(html: html, kind: kind, id: id)
    }

    static func parseEmbed(html: String, kind: MusicCollection.Kind, id: String) throws -> MusicCollection {
        guard let start = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let props = json["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let dataObj = state["data"] as? [String: Any],
              let entity = dataObj["entity"] as? [String: Any] else {
            throw SpotifyError.parse
        }
        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify"
        let subtitle = entity["subtitle"] as? String
        let cover = coverURL(entity)
        let source = "https://open.spotify.com/\(kind.rawValue)/\(id)"

        if kind == .track {
            let artists = (entity["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? splitArtists(subtitle)
            let year = ((entity["releaseDate"] as? [String: Any])?["isoString"] as? String).map { String($0.prefix(4)) }
            let track = MusicTrack(title: name, artists: artists, album: nil, albumArtist: nil, trackNumber: nil, trackCount: nil,
                                   durationMs: entity["duration"] as? Int, releaseYear: year, coverURL: cover,
                                   sourceURL: source, explicit: entity["isExplicit"] as? Bool)
            return MusicCollection(id: id, kind: .track, name: name, owner: artists.joined(separator: ", "),
                                   coverURL: cover, sourceURL: source, tracks: [track])
        }

        let list = entity["trackList"] as? [[String: Any]] ?? []
        let tracks: [MusicTrack] = list.enumerated().compactMap { offset, item in
            guard let title = item["title"] as? String else { return nil }
            let trackID = (item["uri"] as? String)?.split(separator: ":").last.map(String.init)
            return MusicTrack(title: title,
                              artists: splitArtists(item["subtitle"] as? String),
                              album: kind == .album ? name : nil,
                              albumArtist: kind == .album ? subtitle : nil,
                              trackNumber: kind == .album ? offset + 1 : nil,
                              trackCount: kind == .album ? list.count : nil,
                              durationMs: item["duration"] as? Int,
                              releaseYear: nil,
                              coverURL: kind == .album ? cover : nil,
                              sourceURL: trackID.map { "https://open.spotify.com/track/\($0)" },
                              explicit: item["isExplicit"] as? Bool)
        }
        var collection = MusicCollection(id: id, kind: kind, name: kind == .artist ? String(localized: "\(name) – Top songs") : name,
                                         owner: kind == .artist ? name : subtitle, coverURL: cover, sourceURL: source, tracks: tracks)
        collection.possiblyTruncated = kind == .playlist && tracks.count >= 100
        return collection
    }

    static func splitArtists(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{00A0}"))) }
            .filter { !$0.isEmpty }
    }

    private static func coverURL(_ entity: [String: Any]) -> String? {
        var candidates: [(String, Int)] = []
        if let sources = (entity["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]] {
            for s in sources { if let u = s["url"] as? String { candidates.append((u, (s["width"] as? Int) ?? 300)) } }
        }
        if let images = (entity["visualIdentity"] as? [String: Any])?["image"] as? [[String: Any]] {
            for i in images { if let u = i["url"] as? String { candidates.append((u, (i["maxWidth"] as? Int) ?? 0)) } }
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }
}

/// Optional: the official Spotify Web API (own client ID/secret) for playlists with more than 100 songs.
enum SpotifyAPI {
    struct Credentials { var id: String; var secret: String }

    static var credentials: Credentials? {
        let id = Preferences.shared.spotifyClientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let secret = Keychain.read("spotify-client-secret"), !secret.isEmpty else { return nil }
        return Credentials(id: id, secret: secret)
    }

    static func token(_ c: Credentials) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(c.id):\(c.secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw SpotifyError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { throw SpotifyError.parse }
        return token
    }

    private static func get(_ path: String, token: String) async throws -> [String: Any] {
        let url = path.hasPrefix("http") ? URL(string: path)! : URL(string: "https://api.spotify.com/v1/" + path)!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw SpotifyError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SpotifyError.parse }
        return json
    }

    static func fetch(kind: MusicCollection.Kind, id: String, credentials: Credentials) async throws -> MusicCollection {
        let token = try await token(credentials)
        let source = "https://open.spotify.com/\(kind.rawValue)/\(id)"
        switch kind {
        case .track:
            let t = try await get("tracks/\(id)", token: token)
            let track = makeTrack(t, album: t["album"] as? [String: Any])
            return MusicCollection(id: id, kind: .track, name: track.title, owner: track.artistLine,
                                   coverURL: track.coverURL, sourceURL: source, tracks: [track])
        case .album:
            let a = try await get("albums/\(id)", token: token)
            var items = ((a["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            var next = (a["tracks"] as? [String: Any])?["next"] as? String
            while let page = next {
                let p = try await get(page, token: token)
                items += (p["items"] as? [[String: Any]]) ?? []
                next = p["next"] as? String
            }
            let tracks = items.map { makeTrack($0, album: a, count: items.count) }
            return MusicCollection(id: id, kind: .album, name: a["name"] as? String ?? "Album",
                                   owner: artistNames(a["artists"]).joined(separator: ", "),
                                   coverURL: image(a["images"]), sourceURL: source, tracks: tracks)
        case .playlist:
            let p = try await get("playlists/\(id)?fields=name,owner(display_name),images", token: token)
            var tracks: [MusicTrack] = []
            var next: String? = "playlists/\(id)/tracks?limit=100"
            while let page = next {
                let r = try await get(page, token: token)
                for item in (r["items"] as? [[String: Any]]) ?? [] {
                    if let t = item["track"] as? [String: Any], t["type"] as? String != "episode" {
                        tracks.append(makeTrack(t, album: t["album"] as? [String: Any]))
                    }
                }
                next = r["next"] as? String
            }
            return MusicCollection(id: id, kind: .playlist, name: p["name"] as? String ?? "Playlist",
                                   owner: (p["owner"] as? [String: Any])?["display_name"] as? String,
                                   coverURL: image(p["images"]), sourceURL: source, tracks: tracks)
        case .artist:
            let a = try await get("artists/\(id)", token: token)
            let market = Locale.current.region?.identifier ?? "US"
            let r = try await get("artists/\(id)/top-tracks?market=\(market)", token: token)
            let tracks = ((r["tracks"] as? [[String: Any]]) ?? []).map { makeTrack($0, album: $0["album"] as? [String: Any]) }
            let name = a["name"] as? String ?? "Artist"
            return MusicCollection(id: id, kind: .artist, name: String(localized: "\(name) – Top songs"), owner: name,
                                   coverURL: image(a["images"]), sourceURL: source, tracks: tracks)
        }
    }

    private static func makeTrack(_ t: [String: Any], album: [String: Any]?, count: Int? = nil) -> MusicTrack {
        let albumArtists = artistNames(album?["artists"])
        return MusicTrack(title: t["name"] as? String ?? "?",
                          artists: artistNames(t["artists"]),
                          album: album?["name"] as? String,
                          albumArtist: albumArtists.first,
                          trackNumber: t["track_number"] as? Int,
                          trackCount: count ?? album?["total_tracks"] as? Int,
                          durationMs: t["duration_ms"] as? Int,
                          releaseYear: (album?["release_date"] as? String).map { String($0.prefix(4)) },
                          coverURL: image(album?["images"]),
                          sourceURL: (t["external_urls"] as? [String: Any])?["spotify"] as? String,
                          explicit: t["explicit"] as? Bool)
    }

    private static func artistNames(_ value: Any?) -> [String] {
        ((value as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    private static func image(_ value: Any?) -> String? {
        ((value as? [[String: Any]]) ?? []).max(by: { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) })?["url"] as? String
    }
}

/// Minimal Keychain wrapper for the optional Spotify client secret.
enum Keychain {
    private static let service = "io.github.kmitulla.lasso"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// File and folder names for music downloads.
enum MusicNaming {
    static func sanitize(_ text: String) -> String {
        var s = text
        for ch in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] { s = s.replacingOccurrences(of: ch, with: ch == ":" ? " -" : "-") }
        s = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 150 { s = String(s.prefix(150)) }
        return s.isEmpty ? "Untitled" : s
    }

    /// "03 - Artist - Title" (without extension).
    static func baseName(for track: MusicTrack, number: Int?, total: Int?) -> String {
        var name = "\(track.mainArtist.isEmpty ? "" : track.mainArtist + " - ")\(track.title)"
        if let number {
            let digits = max(2, String(total ?? number).count)
            name = String(format: "%0\(digits)ld - ", number) + name
        }
        return sanitize(name)
    }

    static let audioExtensions = ["mp3", "m4a", "aac", "opus", "ogg", "flac", "wav", "mka", "alac"]
    static let videoExtensions = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "ts"]

    /// Finds an existing download of this song (any audio format).
    static func existingFile(folder: String, baseName: String) -> String? {
        for ext in audioExtensions {
            let path = (folder as NSString).appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }
}

/// Writes .m3u8 playlist files.
enum PlaylistWriter {
    struct Entry { var path: String; var title: String; var duration: Double? }

    static func write(name: String, folder: String, entries: [Entry]) {
        guard !entries.isEmpty else { return }
        var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
        for e in entries {
            lines.append("#EXTINF:\(Int((e.duration ?? -1).rounded())),\(e.title)")
            let dir = (folder as NSString).standardizingPath + "/"
            lines.append(e.path.hasPrefix(dir) ? String(e.path.dropFirst(dir.count)) : e.path)
        }
        let file = (folder as NSString).appendingPathComponent(MusicNaming.sanitize(name) + ".m3u8")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}
