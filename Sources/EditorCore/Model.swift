import Foundation

/// A whole editing session. Value type: copy it to snapshot for undo or to hand to the audio thread.
public struct Project: Codable, Equatable {
    public var formatVersion: Int = 1
    public var sampleRate: Double = 44_100
    public var metadata = PodcastMetadata()
    public var sources: [AudioSource] = []
    public var tracks: [Track] = []
    public var markers: [Marker] = []

    public init() {}

    /// End of the last region on any track, in seconds.
    public var duration: Double {
        tracks.flatMap(\.regions).map(\.end).max() ?? 0
    }

    public func source(_ id: UUID) -> AudioSource? { sources.first { $0.id == id } }

    /// Finds a region anywhere in the project.
    public func locate(region id: UUID) -> (track: Int, region: Int)? {
        for (t, track) in tracks.enumerated() {
            if let r = track.regions.firstIndex(where: { $0.id == id }) { return (t, r) }
        }
        return nil
    }
}

/// An audio file on disk that regions play from.
public struct AudioSource: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Absolute path of the file.
    public var path: String
    /// Duration in seconds as last known (from the session or from decoding).
    public var duration: Double
    public var channels: Int

    public init(id: UUID = UUID(), name: String, path: String, duration: Double, channels: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.duration = duration
        self.channels = channels
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public struct Track: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var volumeDB: Double = 0
    public var muted = false
    public var regions: [Region] = []

    public init(id: UUID = UUID(), name: String, volumeDB: Double = 0, muted: Bool = false, regions: [Region] = []) {
        self.id = id
        self.name = name
        self.volumeDB = volumeDB
        self.muted = muted
        self.regions = regions
    }
}

/// A piece of a source placed on a track.
public struct Region: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var sourceID: UUID
    public var name: String
    /// Position on the timeline, seconds.
    public var start: Double
    /// Where in the source file the region begins, seconds.
    public var offset: Double
    /// Length on the timeline, seconds.
    public var length: Double
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    /// Base gain in dB.
    public var gainDB: Double = 0
    /// Volume changes inside the region (e.g. ducking music under a voice), sorted by start.
    public var gainRamps: [GainRamp] = []

    public init(id: UUID = UUID(), sourceID: UUID, name: String, start: Double, offset: Double, length: Double,
                fadeIn: Double = 0, fadeOut: Double = 0, gainDB: Double = 0, gainRamps: [GainRamp] = []) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.start = start
        self.offset = offset
        self.length = length
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.gainDB = gainDB
        self.gainRamps = gainRamps
    }

    public var end: Double { start + length }
}

/// A ramp, relative to the region's start, from the current level to `gainDB` over `length` seconds.
public struct GainRamp: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var length: Double
    public var gainDB: Double

    public init(id: UUID = UUID(), start: Double, length: Double, gainDB: Double) {
        self.id = id
        self.start = start
        self.length = length
        self.gainDB = gainDB
    }
}

public struct Marker: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var time: Double

    public init(id: UUID = UUID(), name: String, time: Double) {
        self.id = id
        self.name = name
        self.time = time
    }
}

/// Episode metadata written into the exported MP3 as ID3 tags.
public struct PodcastMetadata: Codable, Equatable {
    public var title = ""
    public var author = ""
    /// Show name.
    public var album = ""
    public var trackNumber = ""
    public var date = ""
    public var genre = "Podcast"
    public var description = ""
    public var copyright = ""
    public var email = ""
    public var link = ""
    public var keywords = ""
    public var explicit = false
    /// Path to a JPEG or PNG cover image.
    public var artworkPath = ""

    public init() {}

    /// A four-digit year found in `date`, if any.
    public var year: String? {
        let digits = date.split(whereSeparator: { !$0.isNumber })
        return digits.first(where: { $0.count == 4 }).map(String.init)
    }
}
