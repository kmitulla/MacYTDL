import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Result of interpreting a natural-language request such as
/// "only the audio as mp3 from 1:20 to 3:00 without sponsors".
struct AssistantSuggestion: Equatable {
    var preset: QualityPreset?
    var container: VideoContainer?
    var subtitles: Bool?
    var subtitleLanguages: String?
    var autoSubtitles: Bool?
    var clipStart: String?
    var clipEnd: String?
    var sponsorBlock: SponsorBlockMode?
    var downloadPlaylist: Bool?
    var usedOnDeviceModel = false

    var isEmpty: Bool {
        preset == nil && container == nil && subtitles == nil && clipStart == nil && clipEnd == nil
            && sponsorBlock == nil && downloadPlaylist == nil
    }

    func apply(to options: inout DownloadOptions) {
        if let preset { options.preset = preset }
        if let container { options.container = container }
        if let subtitles { options.subtitles = subtitles }
        if let subtitleLanguages, !subtitleLanguages.isEmpty { options.subtitleLanguages = subtitleLanguages }
        if let autoSubtitles { options.autoSubtitles = autoSubtitles }
        if let clipStart { options.clipStart = clipStart }
        if let clipEnd { options.clipEnd = clipEnd }
        if let sponsorBlock { options.sponsorBlock = sponsorBlock }
        if let downloadPlaylist { options.downloadPlaylist = downloadPlaylist }
    }

    /// Short human readable confirmation ("MP3 · 1:20–3:00 · without sponsors").
    var summary: String {
        var parts: [String] = []
        if let preset { parts.append(preset.title) }
        if let container { parts.append(container.title) }
        if subtitles == true {
            parts.append(String(localized: "Subtitles") + (subtitleLanguages.map { " (\($0))" } ?? ""))
        }
        if clipStart != nil || clipEnd != nil {
            parts.append("\(clipStart ?? "0:00")–\(clipEnd ?? String(localized: "end"))")
        }
        if let sponsorBlock, sponsorBlock != .off { parts.append(sponsorBlock.title) }
        if downloadPlaylist == true { parts.append(String(localized: "Whole playlist")) }
        if downloadPlaylist == false { parts.append(String(localized: "Only this video")) }
        return parts.joined(separator: " · ")
    }
}

/// "Smart command" field. Uses Apple Intelligence (on-device, private) when available
/// and falls back to a fast built-in parser for German and English.
@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()

    @Published private(set) var onDeviceModelAvailable = false

    init() {
        refresh()
    }

    func refresh() {
        onDeviceModelAvailable = Self.modelAvailable
    }

    func interpret(_ text: String) async -> AssistantSuggestion {
        let ruleBased = RuleParser.parse(text)
        guard Preferences.shared.assistantEnabled, onDeviceModelAvailable else { return ruleBased }
        if let model = try? await Self.askModel(text), !model.isEmpty {
            // The rule parser is very reliable for explicit numbers/times - let it win on those.
            var merged = model
            if let p = ruleBased.preset { merged.preset = p }
            if ruleBased.clipStart != nil || ruleBased.clipEnd != nil {
                merged.clipStart = ruleBased.clipStart
                merged.clipEnd = ruleBased.clipEnd
            }
            merged.usedOnDeviceModel = true
            return merged
        }
        return ruleBased
    }

    /// Two or three sentence summary of a video description.
    func summarize(title: String, description: String) async -> String? {
        guard onDeviceModelAvailable, !description.isEmpty else { return nil }
        let language = Locale.preferredLanguages.first ?? "en"
        let instructions = "You summarize video descriptions in 2 short sentences. Answer in the language with code \(language). No marketing, no links."
        let prompt = "Title: \(title)\n\nDescription:\n\(description.prefix(3000))"
        return try? await Self.respond(instructions: instructions, prompt: prompt)
    }

    // MARK: On-device model

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }

    private static func askModel(_ text: String) async throws -> AssistantSuggestion {
        let instructions = """
        You convert a user's download wish into JSON. Reply with JSON only, no prose.
        Keys (omit keys that the user did not mention):
        "kind": "video" or "audio";
        "audioFormat": one of "mp3","m4a","opus","flac","wav","best";
        "maxHeight": integer like 2160, 1440, 1080, 720, 480 (0 = best);
        "appleCompatible": true if the user wants it to play on iPhone/iPad/QuickTime;
        "container": one of "mp4","mkv","webm","mov";
        "subtitles": true/false; "subtitleLanguages": comma separated ISO codes like "de,en";
        "clipStart": "m:ss" or "h:mm:ss"; "clipEnd": "m:ss" or "h:mm:ss";
        "removeSponsors": true if ads/sponsor segments should be removed;
        "wholePlaylist": true for the whole playlist, false for only this video.
        """
        let raw = try await respond(instructions: instructions, prompt: text)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AssistantSuggestion()
        }
        var s = AssistantSuggestion()
        let kind = (json["kind"] as? String)?.lowercased()
        if kind == "audio" || json["audioFormat"] != nil && kind != "video" {
            switch (json["audioFormat"] as? String)?.lowercased() {
            case "mp3": s.preset = .audioMP3
            case "m4a", "aac": s.preset = .audioM4A
            case "opus": s.preset = .audioOpus
            case "flac": s.preset = .audioFLAC
            case "wav": s.preset = .audioWAV
            case "best": s.preset = .audioBest
            default: s.preset = .audioMP3
            }
        } else if json["appleCompatible"] as? Bool == true {
            s.preset = .appleCompatible
        } else if let height = json["maxHeight"] as? Int {
            s.preset = height <= 0 ? .best : QualityPreset.forHeight(height)
        }
        if let c = (json["container"] as? String).flatMap({ VideoContainer(rawValue: $0.lowercased()) }) { s.container = c }
        if let subs = json["subtitles"] as? Bool { s.subtitles = subs }
        if let langs = json["subtitleLanguages"] as? String, !langs.isEmpty {
            s.subtitles = true
            s.subtitleLanguages = langs.lowercased().replacingOccurrences(of: " ", with: "")
        }
        if let start = json["clipStart"] as? String, Format.parseTimecode(start) != nil { s.clipStart = start }
        if let end = json["clipEnd"] as? String, Format.parseTimecode(end) != nil { s.clipEnd = end }
        if json["removeSponsors"] as? Bool == true { s.sponsorBlock = .remove }
        if let whole = json["wholePlaylist"] as? Bool { s.downloadPlaylist = whole }
        return s
    }
}

/// Deterministic parser for common phrases in German and English.
enum RuleParser {
    static func parse(_ input: String) -> AssistantSuggestion {
        let text = " " + input.lowercased() + " "
        var s = AssistantSuggestion()

        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        // Audio
        if has(["mp3"]) { s.preset = .audioMP3 }
        else if has(["m4a", " aac"]) { s.preset = .audioM4A }
        else if has(["flac", "lossless", "verlustfrei"]) { s.preset = .audioFLAC }
        else if has([" wav"]) { s.preset = .audioWAV }
        else if has(["opus"]) { s.preset = .audioOpus }
        else if has(["nur audio", "nur ton", "only audio", "audio only", " audio", "musik", "music", "song", "podcast", "hörbuch", "audiobook", "tonspur"]) {
            s.preset = .audioMP3
        }
        // Video quality
        if s.preset == nil {
            if has(["iphone", "ipad", "quicktime", "kompatib", "compatib", "apple tv", "keynote", "imovie"]) { s.preset = .appleCompatible }
            else if has(["8k", "4320"]) { s.preset = .best }
            else if has(["4k", "2160", "uhd"]) { s.preset = .uhd2160 }
            else if has(["1440", "2k", "qhd"]) { s.preset = .qhd1440 }
            else if has(["1080", "full hd", "fullhd", "fhd"]) { s.preset = .fhd1080 }
            else if has(["720", " hd "]) { s.preset = .hd720 }
            else if has(["480", " sd ", "klein", "small", "wenig speicher", "low quality", "niedrige"]) { s.preset = .sd480 }
            else if has(["beste", "best", "höchste", "highest", "maximal"]) { s.preset = .best }
        }
        // Container
        if has(["mkv"]) { s.container = .mkv }
        else if has(["webm"]) { s.container = .webm }
        else if has([" mov"]) { s.container = .mov }
        else if has(["mp4"]) { s.container = .mp4 }

        // Subtitles
        if has(["untertitel", "subtitle", " subs", "captions", "caption", " cc "]) {
            s.subtitles = true
            let languageMap: [(String, [String])] = [
                ("de", ["deutsch", "german"]), ("en", ["englisch", "english"]), ("fr", ["französisch", "french", "franz"]),
                ("es", ["spanisch", "spanish"]), ("it", ["italienisch", "italian"]), ("pt", ["portugiesisch", "portuguese"]),
                ("nl", ["niederländisch", "dutch"]), ("pl", ["polnisch", "polish"]), ("tr", ["türkisch", "turkish"]),
                ("ru", ["russisch", "russian"]), ("ja", ["japanisch", "japanese"]), ("ko", ["koreanisch", "korean"]),
                ("zh", ["chinesisch", "chinese"]), ("ar", ["arabisch", "arabic"]), ("uk", ["ukrainisch", "ukrainian"]),
            ]
            let langs = languageMap.filter { has($0.1) }.map(\.0)
            if !langs.isEmpty { s.subtitleLanguages = langs.joined(separator: ",") }
            if has(["automatisch", "automatic", "auto-gen", "autogen", "auto "]) { s.autoSubtitles = true }
        }

        // Sponsors
        if has(["sponsor", "werbung", "ohne ads", "no ads", "without ads", "adfree", "werbefrei"]) {
            s.sponsorBlock = .remove
        }

        // Playlist
        if has(["ganze playlist", "komplette playlist", "gesamte playlist", "alle videos", "whole playlist", "entire playlist", "all videos", "full playlist"]) {
            s.downloadPlaylist = true
        } else if has(["nur dieses video", "nur das video", "only this video", "just this video", "only the video"]) {
            s.downloadPlaylist = false
        }

        // Clip ranges
        let time = #"(\d{1,2}:\d{2}(?::\d{2})?)"#
        if let m = firstMatch(#"(?:von|from|ab|zwischen|between)?\s*"# + time + #"\s*(?:bis|to|until|till|-|–|und|and)\s*"# + time, in: text), m.count == 2 {
            s.clipStart = m[0]
            s.clipEnd = m[1]
        } else if let m = firstMatch(#"(?:ab|from|starting at|start at|beginnend bei)\s*"# + time, in: text), m.count == 1 {
            s.clipStart = m[0]
        } else if let m = firstMatch(#"(?:bis|until|till|up to)\s*(?:minute\s*)?"# + time, in: text), m.count == 1 {
            s.clipEnd = m[0]
        }
        if s.clipStart == nil && s.clipEnd == nil,
           let m = firstMatch(#"(?:die ersten|ersten|first)\s*(\d{1,3})\s*(?:minuten|minutes|min)"#, in: text), let minutes = Int(m[0]) {
            s.clipStart = "0:00"
            s.clipEnd = "\(minutes):00"
        }
        if s.clipStart == nil && s.clipEnd == nil,
           let m = firstMatch(#"(?:die ersten|ersten|first)\s*(\d{1,4})\s*(?:sekunden|seconds|sek|sec|s\b)"#, in: text), let seconds = Int(m[0]) {
            s.clipStart = "0:00"
            s.clipEnd = String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return s
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var groups: [String] = []
        for i in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) { groups.append(String(text[r])) }
        }
        return groups.isEmpty ? nil : groups
    }
}
