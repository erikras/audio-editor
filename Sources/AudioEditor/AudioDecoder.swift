import AVFoundation
import EditorCore
import Foundation

/// Decodes audio files (WAV, AIFF, MP3, M4A, FLAC, …) to the project sample rate and caches the result
/// as raw interleaved Float32 in ~/Library/Caches, memory-mapped on later opens.
enum AudioDecoder {
    struct Decoded {
        var pcm: PCMData
        var peaks: [Float]
    }

    /// Frames per waveform peak. At 44.1 kHz that is ~5.8 ms per peak.
    static let framesPerPeak = 256

    static func load(url: URL, sampleRate: Double) throws -> Decoded {
        let cacheDir = try cacheDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = stableHash("\(url.path)|\(size)|\(mtime)|\(sampleRate)")

        for channels in [1, 2] {
            let cached = cacheDir.appendingPathComponent("\(key)-c\(channels).f32")
            if FileManager.default.fileExists(atPath: cached.path) {
                let pcm = try PCMData(mappedFile: cached, channelCount: channels, sampleRate: sampleRate)
                return Decoded(pcm: pcm, peaks: pcm.peaks(framesPerBucket: framesPerPeak))
            }
        }

        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let channels = min(max(Int(inFormat.channelCount), 1), 2)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let partial = cacheDir.appendingPathComponent("\(key)-c\(channels).partial")
        let final = cacheDir.appendingPathComponent("\(key)-c\(channels).f32")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let out = try FileHandle(forWritingTo: partial)

        func write(_ buffer: AVAudioPCMBuffer) throws {
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { return }
            var interleaved = [Float](repeating: 0, count: n * channels)
            for c in 0..<channels {
                let src = data[min(c, Int(buffer.format.channelCount) - 1)]
                for i in 0..<n { interleaved[i * channels + c] = src[i] }
            }
            try interleaved.withUnsafeBytes { try out.write(contentsOf: Data($0)) }
        }

        let chunk: AVAudioFrameCount = 1 << 16
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { throw CocoaError(.fileReadCorruptFile) }

        let needsConversion = inFormat.sampleRate != sampleRate || Int(inFormat.channelCount) != channels
        if needsConversion {
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw CocoaError(.fileReadCorruptFile) }
            converter.downmix = true
            let ratio = sampleRate / inFormat.sampleRate
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 4096) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var finished = false
            while true {
                var error: NSError?
                let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                    if finished {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    do { try file.read(into: inBuffer, frameCount: chunk) } catch { inBuffer.frameLength = 0 }
                    if inBuffer.frameLength == 0 {
                        finished = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inBuffer
                }
                if status == .error { throw error ?? CocoaError(.fileReadCorruptFile) }
                try write(outBuffer)
                if status == .endOfStream { break }
            }
        } else {
            while file.framePosition < file.length {
                try file.read(into: inBuffer, frameCount: chunk)
                if inBuffer.frameLength == 0 { break }
                try write(inBuffer)
            }
        }
        try out.close()
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: partial, to: final)
        let pcm = try PCMData(mappedFile: final, channelCount: channels, sampleRate: sampleRate)
        return Decoded(pcm: pcm, peaks: pcm.peaks(framesPerBucket: framesPerPeak))
    }

    static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("AudioEditor/decoded", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// FNV-1a, so cache names are stable across launches (String.hashValue is not).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
