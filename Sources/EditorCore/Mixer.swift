import Foundation

/// Renders the project's tracks. Stateless: `render` gives the raw mix (no voice processing) for any range,
/// and `renderTrack` gives one track for `MixRenderer`, which adds the stateful speech chain.
public struct Mixer {
    private struct PreparedRegion {
        let startFrame: Int
        let endFrame: Int
        let sourceStartFrame: Int
        let envelope: RegionEnvelope
        let pcm: PCMData
    }

    public struct TrackInfo {
        public let voice: VoiceSettings
        /// Speaking level of the track at its current gain, for the compressor threshold.
        public let referenceLevelDB: Double
    }

    private struct PreparedTrack {
        let gain: Float
        let regions: [PreparedRegion]
        let info: TrackInfo
    }

    public let sampleRate: Double
    private let tracks: [PreparedTrack]
    public let durationFrames: Int

    /// Regions whose source isn't in `sources` (not yet decoded, or missing on disk) render as silence.
    public init(project: Project, sources: [UUID: PCMData]) {
        sampleRate = project.sampleRate
        var prepared: [PreparedTrack] = []
        for track in project.tracks where !track.muted {
            var regions: [PreparedRegion] = []
            for region in track.regions {
                guard let pcm = sources[region.sourceID], region.length > 0 else { continue }
                let startFrame = Int((region.start * project.sampleRate).rounded())
                let lengthFrames = Int((region.length * project.sampleRate).rounded())
                regions.append(PreparedRegion(
                    startFrame: startFrame,
                    endFrame: startFrame + lengthFrames,
                    sourceStartFrame: Int((region.offset * project.sampleRate).rounded()),
                    envelope: RegionEnvelope(region),
                    pcm: pcm))
            }
            // Reference level: the longest region's source level at its gain and the track volume.
            let main = track.regions.filter { sources[$0.sourceID] != nil }.max { $0.length < $1.length }
            let sourceLevel = main.flatMap { sources[$0.sourceID]?.activeLevelDB } ?? -20
            let reference = sourceLevel + (main?.gainDB ?? 0) + track.volumeDB
            prepared.append(PreparedTrack(gain: Float(dbToLinear(track.volumeDB)), regions: regions,
                                          info: TrackInfo(voice: track.voice, referenceLevelDB: reference)))
        }
        tracks = prepared
        durationFrames = Int((project.duration * project.sampleRate).rounded())
    }

    public var trackCount: Int { tracks.count }
    public func trackInfo(_ index: Int) -> TrackInfo { tracks[index].info }

    /// Renders one (unmuted) track, overwriting `left` and `right`.
    public func renderTrack(_ index: Int, startFrame: Int, frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        left.update(repeating: 0, count: frameCount)
        right.update(repeating: 0, count: frameCount)
        let track = tracks[index]
        let windowEnd = startFrame + frameCount
        for r in track.regions {
            let s = max(startFrame, r.startFrame)
            let e = min(windowEnd, r.endFrame)
            if s >= e { continue }
            let pcm = r.pcm
            let channels = pcm.channelCount
            let rightChannel = channels > 1 ? 1 : 0
            let t0 = Double(s - r.startFrame) / sampleRate
            let t1 = Double(e - r.startFrame) / sampleRate
            let flat = r.envelope.isFlat(from: t0, to: t1)
            let flatGain = flat ? Float(r.envelope.gain(at: t0)) * track.gain : 0
            var f = s
            while f < e {
                let src = r.sourceStartFrame + (f - r.startFrame)
                if src >= 0 && src < pcm.frameCount {
                    let g = flat ? flatGain : Float(r.envelope.gain(at: Double(f - r.startFrame) / sampleRate)) * track.gain
                    let base = src * channels
                    let out = f - startFrame
                    left[out] += pcm.samples[base] * g
                    right[out] += pcm.samples[base + rightChannel] * g
                }
                f += 1
            }
        }
    }

    /// Mixes all tracks without voice processing, overwriting `left` and `right`.
    public func render(startFrame: Int, frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        left.update(repeating: 0, count: frameCount)
        right.update(repeating: 0, count: frameCount)
        guard frameCount > 0 else { return }
        let tl = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let tr = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { tl.deallocate(); tr.deallocate() }
        for t in tracks.indices {
            renderTrack(t, startFrame: startFrame, frameCount: frameCount, left: tl, right: tr)
            for i in 0..<frameCount { left[i] += tl[i]; right[i] += tr[i] }
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

/// Plays the mix forward from a position, running each track's voice chain. Used by export and playback,
/// so what you hear is what gets exported. Not thread-safe: one reader at a time.
public final class MixRenderer {
    public let mixer: Mixer
    private let processors: [VoiceProcessor?]
    private var scratchL: UnsafeMutablePointer<Float>
    private var scratchR: UnsafeMutablePointer<Float>
    private var capacity: Int
    public private(set) var position = 0

    /// Frames rendered and thrown away before a seek target so filters and the compressor have settled.
    /// Long enough for several time constants of the compressor's 150 ms release.
    public static let preroll = 22_050

    public init(project: Project, sources: [UUID: PCMData]) {
        let mixer = Mixer(project: project, sources: sources)
        self.mixer = mixer
        processors = (0..<mixer.trackCount).map { i in
            let info = mixer.trackInfo(i)
            return info.voice.enabled
                ? VoiceProcessor(sampleRate: project.sampleRate, settings: info.voice, referenceLevelDB: info.referenceLevelDB)
                : nil
        }
        capacity = 8192
        scratchL = .allocate(capacity: capacity)
        scratchR = .allocate(capacity: capacity)
    }

    deinit {
        scratchL.deallocate()
        scratchR.deallocate()
    }

    public var durationFrames: Int { mixer.durationFrames }

    /// Moves to `frame`, resetting the processors and pre-rolling so there is no click.
    public func seek(to frame: Int) {
        let target = max(0, frame)
        let hasVoice = processors.contains { $0 != nil }
        if hasVoice, target >= position, target - position <= Self.preroll {
            // Close ahead: just run forward, which keeps the processors exactly in step.
        } else {
            for p in processors { p?.reset() }
            position = hasVoice ? max(0, target - Self.preroll) : target
        }
        if position < target {
            let n = target - position
            let l = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { l.deallocate(); r.deallocate() }
            render(frameCount: n, left: l, right: r)
        }
    }

    /// Renders the next `frameCount` frames, overwriting `left` and `right`, and advances.
    public func render(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        left.update(repeating: 0, count: frameCount)
        right.update(repeating: 0, count: frameCount)
        guard frameCount > 0 else { return }
        if frameCount > capacity {
            scratchL.deallocate(); scratchR.deallocate()
            capacity = frameCount
            scratchL = .allocate(capacity: capacity)
            scratchR = .allocate(capacity: capacity)
        }
        for t in 0..<mixer.trackCount {
            mixer.renderTrack(t, startFrame: position, frameCount: frameCount, left: scratchL, right: scratchR)
            processors[t]?.process(left: scratchL, right: scratchR, frameCount: frameCount)
            for i in 0..<frameCount { left[i] += scratchL[i]; right[i] += scratchR[i] }
        }
        position += frameCount
    }
}
