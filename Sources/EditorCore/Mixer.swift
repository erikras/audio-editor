import Foundation

/// Renders the project's tracks into a stereo mix. Pure and allocation-free per call, so playback and export share it.
public struct Mixer {
    private struct PreparedRegion {
        let startFrame: Int
        let endFrame: Int
        let sourceStartFrame: Int
        let envelope: RegionEnvelope
        let trackGain: Float
        let pcm: PCMData
    }

    public let sampleRate: Double
    private let regions: [PreparedRegion]
    public let durationFrames: Int

    /// Regions whose source isn't in `sources` (not yet decoded, or missing on disk) render as silence.
    public init(project: Project, sources: [UUID: PCMData]) {
        sampleRate = project.sampleRate
        var prepared: [PreparedRegion] = []
        for track in project.tracks where !track.muted {
            let trackGain = Float(dbToLinear(track.volumeDB))
            for region in track.regions {
                guard let pcm = sources[region.sourceID], region.length > 0 else { continue }
                let startFrame = Int((region.start * project.sampleRate).rounded())
                let lengthFrames = Int((region.length * project.sampleRate).rounded())
                prepared.append(PreparedRegion(
                    startFrame: startFrame,
                    endFrame: startFrame + lengthFrames,
                    sourceStartFrame: Int((region.offset * project.sampleRate).rounded()),
                    envelope: RegionEnvelope(region),
                    trackGain: trackGain,
                    pcm: pcm))
            }
        }
        regions = prepared
        durationFrames = Int((project.duration * project.sampleRate).rounded())
    }

    /// Mixes `frameCount` frames starting at timeline frame `startFrame`, overwriting `left` and `right`.
    public func render(startFrame: Int, frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        left.update(repeating: 0, count: frameCount)
        right.update(repeating: 0, count: frameCount)
        let windowEnd = startFrame + frameCount
        for r in regions {
            let s = max(startFrame, r.startFrame)
            let e = min(windowEnd, r.endFrame)
            if s >= e { continue }
            let pcm = r.pcm
            let channels = pcm.channelCount
            let rightChannel = channels > 1 ? 1 : 0
            let t0 = Double(s - r.startFrame) / sampleRate
            let t1 = Double(e - r.startFrame) / sampleRate
            let flat = r.envelope.isFlat(from: t0, to: t1)
            let flatGain = flat ? Float(r.envelope.gain(at: t0)) * r.trackGain : 0
            var f = s
            while f < e {
                let src = r.sourceStartFrame + (f - r.startFrame)
                if src >= 0 && src < pcm.frameCount {
                    let g = flat ? flatGain : Float(r.envelope.gain(at: Double(f - r.startFrame) / sampleRate)) * r.trackGain
                    let base = src * channels
                    let out = f - startFrame
                    left[out] += pcm.samples[base] * g
                    right[out] += pcm.samples[base + rightChannel] * g
                }
                f += 1
            }
        }
    }

    /// Convenience for tests: renders into arrays.
    public func render(startFrame: Int, frameCount: Int) -> (left: [Float], right: [Float]) {
        guard frameCount > 0 else { return ([], []) }
        var l = [Float](repeating: 0, count: frameCount)
        var r = [Float](repeating: 0, count: frameCount)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                render(startFrame: startFrame, frameCount: frameCount, left: lp.baseAddress!, right: rp.baseAddress!)
            }
        }
        return (l, r)
    }
}
