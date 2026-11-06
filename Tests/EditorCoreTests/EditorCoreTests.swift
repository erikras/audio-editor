import XCTest
@testable import EditorCore

final class TimecodeTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Timecode.parse("05.205")!, 5.205, accuracy: 1e-9)
        XCTAssertEqual(Timecode.parse("1:17:19.787")!, 4639.787, accuracy: 1e-9)
        XCTAssertEqual(Timecode.parse("2:03")!, 123, accuracy: 1e-9)
        XCTAssertEqual(Timecode.parse("0")!, 0)
        XCTAssertNil(Timecode.parse(""))
        XCTAssertNil(Timecode.parse("abc"))
        XCTAssertNil(Timecode.parse("1.5:00"))
    }

    func testFormatRoundTrip() {
        XCTAssertEqual(Timecode.format(4639.787), "1:17:19.787")
        XCTAssertEqual(Timecode.format(5.205), "0:05.205")
        XCTAssertEqual(Timecode.parse(Timecode.format(1234.5))!, 1234.5, accuracy: 1e-9)
    }
}

final class SessionImportTests: XCTestCase {
    func fixture() throws -> SessionImporter.ImportResult {
        let url = Bundle.module.url(forResource: "sample", withExtension: "nhsx", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try SessionImporter.importSession(data: data, sessionDirectory: "/Users/someone/Podcasting/EP1", fileExists: { path in
            path == "/Users/someone/Podcasting/EP1/final/edit.wav" || path == "/Users/someone/Podcasting/EP1/final/intro.wav"
        })
    }

    func testMetadata() throws {
        let m = try fixture().project.metadata
        XCTAssertEqual(m.title, "Ep. 1 – Pilot")
        XCTAssertEqual(m.album, "Example Show")
        XCTAssertEqual(m.author, "Host A and Host B")
        XCTAssertEqual(m.trackNumber, "1")
        XCTAssertEqual(m.year, "2026")
        XCTAssertTrue(m.explicit)
        XCTAssertEqual(m.description, "Two hosts catch up & talk about \"travel\".")
    }

    func testTracksRegionsAndFades() throws {
        let result = try fixture()
        let p = result.project
        XCTAssertEqual(p.tracks.map(\.name), ["Speak", "Intro"])
        XCTAssertEqual(p.tracks[1].volumeDB, -13)

        let speech = p.tracks[0].regions[0]
        XCTAssertEqual(speech.start, 5.205, accuracy: 1e-9)
        XCTAssertEqual(speech.offset, 6.95, accuracy: 1e-9)
        XCTAssertEqual(speech.length, 4639.787, accuracy: 1e-9)
        XCTAssertEqual(speech.fadeIn, 2.449, accuracy: 1e-9)
        XCTAssertEqual(speech.fadeOut, 1.839, accuracy: 1e-9)
        XCTAssertEqual(p.source(speech.sourceID)?.path, "/Users/someone/Podcasting/EP1/final/edit.wav")

        let music = p.tracks[1].regions[1]
        XCTAssertEqual(music.gainDB, -9.5)
        XCTAssertEqual(music.gainRamps.count, 2)
        XCTAssertEqual(music.gainRamps[0].gainDB, -18.8)

        XCTAssertEqual(p.markers.map(\.name), ["In", "Out"])
        XCTAssertEqual(result.missingSources.map(\.name), ["outro-music.wav"])
        XCTAssertEqual(result.ignoredPlugins, ["Speak: Voice Profiler", "Speak: Compressor"])
    }

    func testProjectFileRoundTrip() throws {
        let p = try fixture().project
        XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(p)), p)
    }
}

final class EnvelopeTests: XCTestCase {
    func testFadesAndRamps() {
        let r = Region(sourceID: UUID(), name: "r", start: 0, offset: 0, length: 10, fadeIn: 1, fadeOut: 2, gainDB: -6,
                       gainRamps: [GainRamp(start: 4, length: 2, gainDB: -18)])
        let e = RegionEnvelope(r)
        XCTAssertEqual(e.gain(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(e.levelDB(at: 2), -6, accuracy: 1e-9)
        XCTAssertEqual(e.levelDB(at: 5), -12, accuracy: 1e-9)
        XCTAssertEqual(e.levelDB(at: 7), -18, accuracy: 1e-9)
        XCTAssertEqual(e.fadeFactor(at: 0.5), sin(.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(e.fadeFactor(at: 10), 0, accuracy: 1e-9)
        XCTAssertTrue(e.isFlat(from: 1.5, to: 3.5))
        XCTAssertFalse(e.isFlat(from: 3, to: 5))
        XCTAssertFalse(e.isFlat(from: 7, to: 9))
    }
}

final class MixerTests: XCTestCase {
    func testAlignmentOffsetGainAndMono() {
        // A mono ramp source: sample i has value i / 1000.
        let sr = 1000.0
        let pcm = PCMData(channels: [(0..<1000).map { Float($0) / 1000 }], sampleRate: sr)
        var p = Project()
        p.sampleRate = sr
        let source = AudioSource(name: "s", path: "/s.wav", duration: 1, channels: 1)
        p.sources = [source]
        p.tracks = [Track(name: "T", volumeDB: -6.0206, regions: [
            Region(sourceID: source.id, name: "r", start: 0.1, offset: 0.2, length: 0.3)
        ])]
        let mixer = Mixer(project: p, sources: [source.id: pcm])
        XCTAssertEqual(mixer.durationFrames, 400)
        let (l, r) = mixer.render(startFrame: 0, frameCount: 500)
        XCTAssertEqual(l[99], 0)
        XCTAssertEqual(l[100], 0.2 * 0.5, accuracy: 1e-4)   // offset 0.2s -> sample 200, at half volume
        XCTAssertEqual(r[150], 0.25 * 0.5, accuracy: 1e-4)  // mono feeds both sides
        XCTAssertEqual(l[400], 0)
    }

    func testMutedTrackIsSilent() {
        let pcm = PCMData(channels: [[1, 1, 1, 1]], sampleRate: 4)
        var p = Project(); p.sampleRate = 4
        let s = AudioSource(name: "s", path: "/s", duration: 1, channels: 1)
        p.sources = [s]
        p.tracks = [Track(name: "T", muted: true, regions: [Region(sourceID: s.id, name: "r", start: 0, offset: 0, length: 1)])]
        XCTAssertEqual(Mixer(project: p, sources: [s.id: pcm]).render(startFrame: 0, frameCount: 4).left, [0, 0, 0, 0])
    }
}

final class LoudnessTests: XCTestCase {
    /// EBU Tech 3341 case: stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS.
    func testReferenceSine() {
        let sr = 48_000.0
        let n = Int(sr * 5)
        let amp = Float(dbToLinear(-23))
        let sine = (0..<n).map { amp * Float(sin(2 * .pi * 1000 * Double($0) / sr)) }
        let meter = LoudnessMeter(sampleRate: sr, channelCount: 2)
        sine.withUnsafeBufferPointer { b in meter.add(channels: [b.baseAddress!, b.baseAddress!], frameCount: n) }
        XCTAssertEqual(meter.integratedLoudness!, -23, accuracy: 0.1)
    }

    func testSilenceHasNoLoudness() {
        let zeros = [Float](repeating: 0, count: 44_100)
        let meter = LoudnessMeter(sampleRate: 44_100, channelCount: 1)
        zeros.withUnsafeBufferPointer { meter.add(channels: [$0.baseAddress!], frameCount: zeros.count) }
        XCTAssertNil(meter.integratedLoudness)
    }

    func testLimiterHoldsCeiling() {
        var x = (0..<4410).map { Float(sin(Double($0) * 0.05)) * 1.5 }
        let limiter = PeakLimiter(sampleRate: 44_100, channelCount: 1, ceilingDB: -1)
        x.withUnsafeMutableBufferPointer { limiter.process(channels: [$0.baseAddress!], frameCount: $0.count) }
        let ceiling = Float(dbToLinear(-1))
        XCTAssertLessThanOrEqual(x.map(abs).max()!, ceiling + 1e-6)
    }
}

final class ID3Tests: XCTestCase {
    func testTagHeaderAndFrames() {
        var m = PodcastMetadata()
        m.title = "Ep. 1 – Pilot"
        m.album = "Show"
        m.description = "Desc"
        let tag = ID3Tag.build(metadata: m, chapters: [.init(title: "Intro", start: 0, end: 10)])
        XCTAssertEqual(Array(tag.prefix(5)), [0x49, 0x44, 0x33, 3, 0])
        let size = tag[6...9].reduce(0) { ($0 << 7) | Int($1) }
        XCTAssertEqual(size, tag.count - 10)
        for id in ["TIT2", "TALB", "COMM", "PCST", "CTOC", "CHAP"] {
            XCTAssertNotNil(tag.range(of: Data(id.utf8)), id)
        }
    }
}

final class MP3ExportTests: XCTestCase {
    func testExportWritesTaggedMP3() throws {
        let sr = 44_100.0
        let tone = (0..<Int(sr * 2)).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / sr)) }
        let pcm = PCMData(channels: [tone], sampleRate: sr)
        var p = Project()
        let s = AudioSource(name: "tone", path: "/tone.wav", duration: 2, channels: 1)
        p.sources = [s]
        p.tracks = [Track(name: "T", regions: [Region(sourceID: s.id, name: "tone", start: 0.5, offset: 0, length: 2, fadeIn: 0.1, fadeOut: 0.1)])]
        p.metadata.title = "Test"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try MP3Exporter.export(project: p, sources: [s.id: pcm], options: ExportOptions(), to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(3)), Array("ID3".utf8))
        XCTAssertEqual(report.bytes, data.count)
        XCTAssertGreaterThan(data.count, 20_000)   // ~2.5 s at 128 kbps
        XCTAssertNotNil(report.measuredLoudness)
        XCTAssertEqual(report.measuredLoudness! + report.appliedGainDB, -16, accuracy: 1e-9)
    }
}
