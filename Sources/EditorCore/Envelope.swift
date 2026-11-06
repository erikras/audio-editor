import Foundation

/// Precomputed gain curve for one region: base gain, inner gain ramps, fade-in and fade-out.
public struct RegionEnvelope {
    private struct Segment {
        var start: Double      // region-relative seconds
        var end: Double
        var fromDB: Double
        var toDB: Double
    }

    public let length: Double
    public let fadeIn: Double
    public let fadeOut: Double
    private let baseDB: Double
    private let segments: [Segment]

    public init(_ region: Region) {
        length = region.length
        fadeIn = max(0, min(region.fadeIn, region.length))
        fadeOut = max(0, min(region.fadeOut, region.length))
        baseDB = region.gainDB
        var level = region.gainDB
        var segs: [Segment] = []
        for ramp in region.gainRamps.sorted(by: { $0.start < $1.start }) {
            segs.append(Segment(start: ramp.start, end: ramp.start + max(ramp.length, 0), fromDB: level, toDB: ramp.gainDB))
            level = ramp.gainDB
        }
        segments = segs
    }

    /// Level in dB from the base gain and ramps (no fades) at region-relative time `t`.
    public func levelDB(at t: Double) -> Double {
        var level = baseDB
        for seg in segments {
            if t < seg.start { break }
            if t >= seg.end {
                level = seg.toDB
            } else {
                let x = (t - seg.start) / (seg.end - seg.start)
                return seg.fromDB + (seg.toDB - seg.fromDB) * x
            }
        }
        return level
    }

    /// S-shaped fade curve: starts and ends gently, half gain at the midpoint.
    @inlinable public static func fadeCurve(_ x: Double) -> Double {
        let c = max(0, min(1, x))
        return (1 - cos(c * .pi)) / 2
    }

    /// Fade multiplier (0...1) at region-relative time `t`.
    public func fadeFactor(at t: Double) -> Double {
        var g = 1.0
        if fadeIn > 0, t < fadeIn {
            g *= Self.fadeCurve(max(t, 0) / fadeIn)
        }
        if fadeOut > 0, t > length - fadeOut {
            g *= Self.fadeCurve(max(length - t, 0) / fadeOut)
        }
        return g
    }

    /// Linear gain at region-relative time `t`.
    public func gain(at t: Double) -> Double {
        dbToLinear(levelDB(at: t)) * fadeFactor(at: t)
    }

    /// True when the envelope is constant across [t0, t1), so callers can skip per-sample evaluation.
    public func isFlat(from t0: Double, to t1: Double) -> Bool {
        if fadeIn > 0, t0 < fadeIn { return false }
        if fadeOut > 0, t1 > length - fadeOut { return false }
        for seg in segments where seg.end > t0 && seg.start < t1 { return false }
        return true
    }
}
