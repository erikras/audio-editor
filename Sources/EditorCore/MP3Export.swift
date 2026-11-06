import Foundation
import CLame

/// Thin wrapper over libmp3lame.
public final class MP3Encoder {
    public enum EncoderError: Error, LocalizedError {
        case initFailed
        case encodeFailed(Int32)
        public var errorDescription: String? {
            switch self {
            case .initFailed: return "The MP3 encoder couldn't start with these settings."
            case .encodeFailed(let code): return "MP3 encoding failed (code \(code))."
            }
        }
    }

    private let lame: OpaquePointer
    public let channelCount: Int
    private var buffer: [UInt8] = []

    public init(sampleRate: Int, channelCount: Int, bitrateKbps: Int, quality: Int = 2) throws {
        guard let l = lame_init() else { throw EncoderError.initFailed }
        lame = l
        self.channelCount = channelCount
        lame_set_in_samplerate(l, Int32(sampleRate))
        lame_set_out_samplerate(l, Int32(sampleRate))
        lame_set_num_channels(l, Int32(channelCount))
        lame_set_mode(l, channelCount == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(l, Int32(bitrateKbps))
        lame_set_VBR(l, vbr_off)
        lame_set_quality(l, Int32(quality))
        lame_set_write_id3tag_automatic(l, 0)
        lame_set_bWriteVbrTag(l, 1)
        guard lame_init_params(l) >= 0 else {
            lame_close(l)
            throw EncoderError.initFailed
        }
    }

    deinit { lame_close(lame) }

    /// Encodes float samples in -1...1. For mono, `right` is ignored.
    public func encode(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int) throws -> Data {
        let needed = frameCount * 5 / 4 + 7200
        if buffer.count < needed { buffer = [UInt8](repeating: 0, count: needed) }
        let size = buffer.count
        let n = buffer.withUnsafeMutableBufferPointer { out in
            lame_encode_buffer_ieee_float(lame, left, channelCount == 1 ? left : right, Int32(frameCount), out.baseAddress, Int32(size))
        }
        guard n >= 0 else { throw EncoderError.encodeFailed(n) }
        return Data(buffer[0..<Int(n)])
    }

    public func flush() throws -> Data {
        if buffer.count < 7200 { buffer = [UInt8](repeating: 0, count: 7200) }
        let size = buffer.count
        let n = buffer.withUnsafeMutableBufferPointer { out in
            lame_encode_flush(lame, out.baseAddress, Int32(size))
        }
        guard n >= 0 else { throw EncoderError.encodeFailed(n) }
        return Data(buffer[0..<Int(n)])
    }

    /// The finished Xing/LAME info frame, which replaces the placeholder at the start of the audio.
    public func infoFrame() -> Data {
        var frame = [UInt8](repeating: 0, count: 2880)
        let n = frame.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        guard n > 0, n <= frame.count else { return Data() }
        return Data(frame[0..<n])
    }
}

public struct ExportOptions: Equatable {
    public var bitrateKbps = 128
    public var mono = false
    /// Normalize the mix to this integrated loudness. nil leaves levels alone.
    public var loudnessTarget: Double? = -16
    public var truePeakCeilingDB = -1.0
    /// Write markers as chapters.
    public var includeChapters = false

    public init() {}
}

public struct ExportReport {
    public var duration: Double
    /// Loudness of the mix before normalization (LUFS).
    public var measuredLoudness: Double?
    public var appliedGainDB: Double
    public var bytes: Int
}

public enum MP3Exporter {
    /// Renders the project and writes an MP3 with ID3 metadata.
    /// - Parameters:
    ///   - sources: decoded audio by source id. Regions without decoded audio are silent.
    ///   - progress: called with 0...1; return false to cancel.
    public static func export(project: Project, sources: [UUID: PCMData], options: ExportOptions, to url: URL,
                              progress: (Double) -> Bool = { _ in true }) throws -> ExportReport {
        let mixer = Mixer(project: project, sources: sources)
        let total = mixer.durationFrames
        let chunk = 1 << 16
        let channelCount = options.mono ? 1 : 2
        var left = [Float](repeating: 0, count: chunk)
        var right = [Float](repeating: 0, count: chunk)

        func renderChunk(_ start: Int, _ count: Int) {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    mixer.render(startFrame: start, frameCount: count, left: l.baseAddress!, right: r.baseAddress!)
                    if options.mono {
                        for i in 0..<count { l[i] = (l[i] + r[i]) * 0.5 }
                    }
                }
            }
        }

        // Pass 1: measure loudness.
        var measured: Double?
        var gainDB = 0.0
        if let target = options.loudnessTarget {
            let meter = LoudnessMeter(sampleRate: project.sampleRate, channelCount: channelCount)
            var pos = 0
            while pos < total {
                let n = min(chunk, total - pos)
                renderChunk(pos, n)
                left.withUnsafeBufferPointer { l in
                    right.withUnsafeBufferPointer { r in
                        let ptrs = options.mono ? [l.baseAddress!] : [l.baseAddress!, r.baseAddress!]
                        meter.add(channels: ptrs, frameCount: n)
                    }
                }
                pos += n
                if !progress(0.4 * Double(pos) / Double(max(total, 1))) { throw CancellationError() }
            }
            measured = meter.integratedLoudness
            if let measured { gainDB = target - measured }
        }

        // Pass 2: render, apply gain + limiter, encode.
        let encoder = try MP3Encoder(sampleRate: Int(project.sampleRate), channelCount: channelCount, bitrateKbps: options.bitrateKbps)
        let limiter = PeakLimiter(sampleRate: project.sampleRate, channelCount: channelCount, ceilingDB: options.truePeakCeilingDB)
        let gain = Float(dbToLinear(gainDB))

        var artwork: Data?
        if !project.metadata.artworkPath.isEmpty {
            artwork = try? Data(contentsOf: URL(fileURLWithPath: project.metadata.artworkPath))
        }
        let chapters = options.includeChapters ? makeChapters(project.markers, duration: project.duration) : []
        let tag = ID3Tag.build(metadata: project.metadata, artwork: artwork, chapters: chapters)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: tag)

        // The limiter delays output by its look-ahead: drop that many leading frames and render as many extra at the end.
        var toSkip = limiter.latency
        let renderTotal = total + limiter.latency
        var pos = 0
        var bytes = tag.count
        while pos < renderTotal {
            let n = min(chunk, renderTotal - pos)
            if pos >= total {
                for i in 0..<n { left[i] = 0; right[i] = 0 }
            } else {
                let real = min(n, total - pos)
                renderChunk(pos, real)
                for i in real..<n { left[i] = 0; right[i] = 0 }
            }
            let data: Data = try left.withUnsafeMutableBufferPointer { l in
                try right.withUnsafeMutableBufferPointer { r in
                    if gain != 1 {
                        for i in 0..<n { l[i] *= gain; r[i] *= gain }
                    }
                    let ptrs = options.mono ? [l.baseAddress!] : [l.baseAddress!, r.baseAddress!]
                    limiter.process(channels: ptrs, frameCount: n)
                    let skip = min(toSkip, n)
                    toSkip -= skip
                    guard n - skip > 0 else { return Data() }
                    return try encoder.encode(left: l.baseAddress! + skip, right: r.baseAddress! + skip, frameCount: n - skip)
                }
            }
            if !data.isEmpty { try handle.write(contentsOf: data); bytes += data.count }
            pos += n
            if !progress(0.4 + 0.6 * Double(pos) / Double(max(renderTotal, 1))) { throw CancellationError() }
        }
        let tail = try encoder.flush()
        try handle.write(contentsOf: tail)
        bytes += tail.count

        let info = encoder.infoFrame()
        if !info.isEmpty {
            try handle.seek(toOffset: UInt64(tag.count))
            try handle.write(contentsOf: info)
        }
        return ExportReport(duration: project.duration, measuredLoudness: measured, appliedGainDB: gainDB, bytes: bytes)
    }

    static func makeChapters(_ markers: [Marker], duration: Double) -> [ID3Tag.Chapter] {
        let sorted = markers.filter { $0.time < duration }.sorted { $0.time < $1.time }
        return sorted.enumerated().map { i, m in
            ID3Tag.Chapter(title: m.name, start: m.time, end: i + 1 < sorted.count ? sorted[i + 1].time : duration)
        }
    }
}
