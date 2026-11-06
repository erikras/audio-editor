import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports `.nhsx` session files (the XML format used by Hindenburg) into a `Project`.
///
/// What carries over: audio pool files, tracks with volume, regions (position, source offset, length,
/// fade in/out, gain, inner volume ramps), markers and episode metadata.
/// Effect plug-ins (Voice Profiler, compressor) are listed in `ImportResult.ignoredPlugins` but not applied.
public enum SessionImporter {
    public struct ImportResult {
        public var project: Project
        /// Sources whose audio file couldn't be found on disk.
        public var missingSources: [AudioSource]
        /// "Track name: plug-in name" for every effect that was skipped.
        public var ignoredPlugins: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case unreadable(String)
        case notASession

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "The session file couldn't be read: \(detail)"
            case .notASession: return "This file isn't a session file."
            }
        }
    }

    public static func importSession(at url: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> ImportResult {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ImportError.unreadable(error.localizedDescription) }
        return try importSession(data: data, sessionDirectory: url.deletingLastPathComponent().path, fileExists: fileExists)
    }

    public static func importSession(data: Data, sessionDirectory: String, fileExists: (String) -> Bool) throws -> ImportResult {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ImportError.unreadable(parser.parserError?.localizedDescription ?? "invalid XML")
        }
        guard delegate.sawSession else { throw ImportError.notASession }

        var project = Project()
        project.sampleRate = delegate.sampleRate ?? 44_100
        project.metadata = delegate.metadata

        // Resolve pool files to absolute paths.
        var idMap: [String: UUID] = [:]
        var missing: [AudioSource] = []
        for file in delegate.files {
            let candidates = candidatePaths(for: file, poolPath: delegate.poolPath, poolLocation: delegate.poolLocation, sessionDirectory: sessionDirectory)
            let found = candidates.first(where: fileExists)
            let source = AudioSource(name: file.name, path: found ?? candidates.first ?? file.name, duration: file.duration, channels: file.channels)
            if found == nil { missing.append(source) }
            idMap[file.id] = source.id
            project.sources.append(source)
        }

        for t in delegate.tracks {
            var track = Track(name: t.name, volumeDB: t.volumeDB)
            for r in t.regions {
                guard let sourceID = idMap[r.ref] else { continue }
                track.regions.append(Region(sourceID: sourceID, name: r.name, start: r.start, offset: r.offset, length: r.length,
                                            fadeIn: r.fadeIn, fadeOut: r.fadeOut, gainDB: r.gainDB, gainRamps: r.ramps))
            }
            track.regions.sort { $0.start < $1.start }
            project.tracks.append(track)
        }
        project.markers = delegate.markers.sorted { $0.time < $1.time }

        let ignored = delegate.tracks.flatMap { t in t.activePlugins.map { "\(t.name): \($0)" } }
        return ImportResult(project: project, missingSources: missing, ignoredPlugins: ignored)
    }

    static func candidatePaths(for file: PoolFile, poolPath: String?, poolLocation: String?, sessionDirectory: String) -> [String] {
        func join(_ parts: String?...) -> String? {
            let pieces = parts.compactMap { $0 }.filter { !$0.isEmpty }
            guard !pieces.isEmpty else { return nil }
            return pieces.dropFirst().reduce(pieces[0]) { ($0 as NSString).appendingPathComponent($1) }
        }
        var paths: [String?] = []
        if let poolPath, poolPath.hasPrefix("/") {
            paths.append(join(poolPath, file.name))
        } else {
            paths.append(join(sessionDirectory, poolPath, file.name))
            paths.append(join(poolLocation, poolPath, file.name))
        }
        paths.append(join(poolLocation, file.name))
        paths.append(join(sessionDirectory, file.name))
        paths.append(file.originalPath)
        var seen = Set<String>()
        return paths.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    struct PoolFile {
        var id: String
        var name: String
        var duration: Double
        var channels: Int
        var originalPath: String?
    }

    struct ParsedRegion {
        var ref: String
        var name: String
        var start: Double
        var offset: Double
        var length: Double
        var fadeIn: Double
        var fadeOut: Double
        var gainDB: Double
        var ramps: [GainRamp] = []
    }

    struct ParsedTrack {
        var name: String
        var volumeDB: Double
        var regions: [ParsedRegion] = []
        var activePlugins: [String] = []
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawSession = false
        var sampleRate: Double?
        var metadata = PodcastMetadata()
        var poolPath: String?
        var poolLocation: String?
        var files: [PoolFile] = []
        var tracks: [ParsedTrack] = []
        var markers: [Marker] = []
        private var stack: [String] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            let parent = stack.last
            stack.append(name)
            func time(_ key: String) -> Double { a[key].flatMap(Timecode.parse) ?? 0 }
            func number(_ key: String) -> Double? { a[key].flatMap { Double($0) } }

            switch name {
            case "Session":
                sawSession = true
                sampleRate = number("Samplerate")
            case "Info" where parent == "Session":
                var m = PodcastMetadata()
                m.title = a["Title"] ?? ""
                m.author = a["Author"] ?? ""
                m.album = a["Album"] ?? ""
                m.trackNumber = a["Track"] ?? ""
                m.date = a["Date"] ?? ""
                m.genre = a["Genre"] ?? "Podcast"
                m.description = a["Description"] ?? ""
                m.copyright = a["Copyright"] ?? ""
                m.email = a["Email"] ?? ""
                m.link = a["Link"] ?? ""
                m.keywords = a["Keywords"] ?? ""
                m.explicit = (a["Explicit"] ?? "").lowercased() == "yes"
                m.artworkPath = a["Image"] ?? a["Artwork"] ?? ""
                metadata = m
            case "AudioPool":
                poolPath = a["Path"]
                poolLocation = a["Location"]
            case "File" where parent == "AudioPool":
                files.append(PoolFile(id: a["Id"] ?? "", name: a["Name"] ?? "",
                                      duration: time("Duration"), channels: Int(a["Channels"] ?? "") ?? 1))
            case "MetaData" where parent == "File":
                if let original = a["OriginalPath"], !files.isEmpty { files[files.count - 1].originalPath = original }
            case "Track" where parent == "Tracks":
                tracks.append(ParsedTrack(name: a["Name"] ?? "Track \(tracks.count + 1)", volumeDB: number("Volume") ?? 0))
            case "Region" where parent == "Track":
                guard !tracks.isEmpty else { break }
                tracks[tracks.count - 1].regions.append(ParsedRegion(
                    ref: a["Ref"] ?? "", name: a["Name"] ?? "",
                    start: time("Start"), offset: time("Offset"), length: time("Length"),
                    fadeIn: time("FadeIn"), fadeOut: time("FadeOut"), gainDB: number("Gain") ?? 0))
            case "Fade" where parent == "Region":
                guard !tracks.isEmpty, !tracks[tracks.count - 1].regions.isEmpty else { break }
                let t = tracks.count - 1, r = tracks[t].regions.count - 1
                tracks[t].regions[r].ramps.append(GainRamp(start: time("Start"), length: time("Length"), gainDB: number("Gain") ?? 0))
            case "Plugin" where parent == "Plugins":
                guard !tracks.isEmpty, stack.dropLast(2).last == "Track" else { break }
                if (a["Bypass"] ?? "False").lowercased() != "true" {
                    tracks[tracks.count - 1].activePlugins.append(a["Name"] ?? "Plug-in")
                }
            case "Marker" where parent == "Markers":
                markers.append(Marker(name: a["Name"] ?? "", time: time("Time")))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }
    }
}
