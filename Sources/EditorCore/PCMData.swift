import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Decoded audio: interleaved Float32 samples at the project sample rate.
///
/// Backed either by memory-mapped cache files (long episodes stay out of RAM) or by an in-memory buffer.
/// Immutable after creation, so it is safe to read from the audio thread.
public final class PCMData: @unchecked Sendable {
    public let channelCount: Int
    public let frameCount: Int
    public let sampleRate: Double
    public let samples: UnsafePointer<Float>
    private let release: () -> Void

    /// Copies interleaved samples into a new buffer.
    public init(interleaved: [Float], channelCount: Int, sampleRate: Double) {
        precondition(channelCount > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        frameCount = interleaved.count / channelCount
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(interleaved.count, 1))
        interleaved.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { buffer.initialize(from: base, count: src.count) }
        }
        samples = UnsafePointer(buffer)
        release = { buffer.deallocate() }
    }

    /// Builds from per-channel arrays of equal length.
    public convenience init(channels: [[Float]], sampleRate: Double) {
        let n = channels.first?.count ?? 0
        var inter = [Float](repeating: 0, count: n * channels.count)
        for (c, ch) in channels.enumerated() {
            for i in 0..<n { inter[i * channels.count + c] = ch[i] }
        }
        self.init(interleaved: inter, channelCount: channels.count, sampleRate: sampleRate)
    }

    /// Memory-maps a raw interleaved Float32 file (as written by the app's decode cache).
    public init(mappedFile url: URL, channelCount: Int, sampleRate: Double) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let byteCount = Int(info.st_size)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        frameCount = byteCount / (MemoryLayout<Float>.size * channelCount)
        if byteCount == 0 {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
            samples = UnsafePointer(buffer)
            release = { buffer.deallocate() }
            return
        }
        guard let raw = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, fd, 0), raw != MAP_FAILED else {
            throw CocoaError(.fileReadUnknown)
        }
        samples = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
        release = { munmap(raw, byteCount) }
    }

    deinit { release() }

    public var duration: Double { Double(frameCount) / sampleRate }

    @inline(__always) public func sample(frame: Int, channel: Int) -> Float {
        samples[frame * channelCount + min(channel, channelCount - 1)]
    }

    /// Peak amplitude (0...1) per bucket of `framesPerBucket` frames, across all channels. Used to draw waveforms.
    public func peaks(framesPerBucket: Int) -> [Float] {
        let bucket = max(framesPerBucket, 1)
        let count = (frameCount + bucket - 1) / bucket
        var out = [Float](repeating: 0, count: count)
        let total = frameCount * channelCount
        var i = 0
        var b = 0
        while i < total {
            let end = min(i + bucket * channelCount, total)
            var peak: Float = 0
            var j = i
            while j < end { peak = max(peak, abs(samples[j])); j += 1 }
            out[b] = peak
            b += 1
            i = end
        }
        return out
    }
}
