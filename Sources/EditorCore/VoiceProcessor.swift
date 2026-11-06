import Foundation

/// RBJ biquad, transposed direct form II, Double state.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Biquad {
        Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highpass(frequency f: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let w = 2 * .pi * min(f, fs * 0.45) / fs, c = cos(w), alpha = sin(w) / (2 * q)
        return normalized((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func lowShelf(frequency f: Double, gainDB: Double, sampleRate fs: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * min(f, fs * 0.45) / fs, c = cos(w), k = 2 * A.squareRoot() * sin(w) / 2 * 2.0.squareRoot()
        return normalized(A * ((A + 1) - (A - 1) * c + k), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - k),
                          (A + 1) + (A - 1) * c + k, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - k)
    }

    static func highShelf(frequency f: Double, gainDB: Double, sampleRate fs: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * min(f, fs * 0.45) / fs, c = cos(w), k = 2 * A.squareRoot() * sin(w) / 2 * 2.0.squareRoot()
        return normalized(A * ((A + 1) + (A - 1) * c + k), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - k),
                          (A + 1) - (A - 1) * c + k, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - k)
    }

    static func peaking(frequency f: Double, q: Double, gainDB: Double, sampleRate fs: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * min(f, fs * 0.45) / fs, c = cos(w), alpha = sin(w) / (2 * q)
        return normalized(1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A)
    }
}

/// Speech chain for one track: high-pass at 80 Hz, EQ, a de-esser, a soft-knee RMS compressor whose threshold follows
/// the track's own speaking level, then a fast stage that catches plosives the compressor's attack lets through.
/// The default sound was tuned by measuring against a finished speech master: fuller lows, less 2-3 kHz edge and more air.
/// Stateful and sample-by-sample, so rendering in chunks gives exactly the same result as one pass.
public final class VoiceProcessor {
    public let settings: VoiceSettings
    /// Typical speaking level of the track (dBFS RMS of active passages), used to place the compressor.
    public let referenceLevelDB: Double

    private var hpL: Biquad, hpR: Biquad
    private var warmthL: Biquad, warmthR: Biquad
    private var mudL: Biquad, mudR: Biquad
    private var edgeL: Biquad, edgeR: Biquad
    private var airL: Biquad, airR: Biquad
    private var essL: Biquad, essR: Biquad

    // De-esser
    private let essCoeff: Double
    private var essHigh = 0.0, essFull = 0.0, essGain = 1.0
    private let essThreshold = 0.4
    private let essFloor: Double
    private let essSmooth: Double

    // Compressor
    private let rmsCoeff: Double, attackCoeff: Double, releaseCoeff: Double
    private let threshold: Double, ratio: Double, knee = 6.0
    private let makeupDB: Double
    private var rms = 0.0
    private var reductionDB = 0.0
    // Plosive catcher
    private var catchGain = 1.0
    private let catchLevel: Double
    private let catchSlope: Double
    private let catchAttack: Double, catchRelease: Double

    public init(sampleRate fs: Double, settings: VoiceSettings, referenceLevelDB: Double) {
        self.settings = settings
        self.referenceLevelDB = referenceLevelDB
        let k = max(0, min(1, settings.strength)) * 2   // 0...2, 1 at the default strength

        hpL = .highpass(frequency: 80, q: 0.7071, sampleRate: fs); hpR = hpL
        warmthL = .lowShelf(frequency: 160, gainDB: 3 * k, sampleRate: fs); warmthR = warmthL
        mudL = .peaking(frequency: 300, q: 1.0, gainDB: -1 * k, sampleRate: fs); mudR = mudL
        edgeL = .peaking(frequency: 2500, q: 0.9, gainDB: -2 * k, sampleRate: fs); edgeR = edgeL
        airL = .highShelf(frequency: 8000, gainDB: 3 * k, sampleRate: fs); airR = airL
        essL = .highpass(frequency: 5500, q: 0.7071, sampleRate: fs); essR = essL

        essCoeff = 1 - exp(-1 / (0.004 * fs))
        essSmooth = 1 - exp(-1 / (0.002 * fs))
        essFloor = dbToLinear(-6 * k)

        rmsCoeff = 1 - exp(-1 / (0.005 * fs))
        attackCoeff = 1 - exp(-1 / (0.004 * fs))
        releaseCoeff = 1 - exp(-1 / (0.150 * fs))
        ratio = 1.5 + 1.5 * k                            // 3:1 at the default strength
        threshold = referenceLevelDB - 2 - 2 * k          // 4 dB under the speaking level by default
        catchLevel = dbToLinear(referenceLevelDB + 12)
        catchSlope = (1 - 1 / 6.0) * min(k, 1)             // 6:1 at the default strength
        catchAttack = 1 - exp(-1 / (0.0005 * fs))
        catchRelease = 1 - exp(-1 / (0.040 * fs))
        // Makeup holds the track's loudness where it was, so processing doesn't shift the balance with music tracks.
        let probe = referenceLevelDB + 9.5
        makeupDB = -Self.staticReduction(level: probe, threshold: threshold, ratio: ratio, knee: knee) 
    }

    /// Gain change (dB, ≤ 0) of the compressor's static curve at `level`.
    static func staticReduction(level: Double, threshold: Double, ratio: Double, knee: Double) -> Double {
        let over = level - threshold
        let slope = 1 / ratio - 1
        if over <= -knee / 2 { return 0 }
        if over < knee / 2 { return slope * (over + knee / 2) * (over + knee / 2) / (2 * knee) }
        return slope * over
    }

    public func reset() {
        hpL.reset(); hpR.reset(); warmthL.reset(); warmthR.reset(); mudL.reset(); mudR.reset()
        edgeL.reset(); edgeR.reset(); airL.reset(); airR.reset(); essL.reset(); essR.reset()
        essHigh = 0; essFull = 0; essGain = 1
        rms = 0; reductionDB = 0; catchGain = 1
    }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            var l = Double(left[i]), r = Double(right[i])

            // Clean-up EQ.
            l = airL.process(edgeL.process(mudL.process(warmthL.process(hpL.process(l)))))
            r = airR.process(edgeR.process(mudR.process(warmthR.process(hpR.process(r)))))

            // De-esser: turn down only the band above ~5.5 kHz when it dominates.
            let hl = essL.process(l), hr = essR.process(r)
            essHigh += essCoeff * (max(hl * hl, hr * hr) - essHigh)
            essFull += essCoeff * (max(l * l, r * r) - essFull)
            var essTarget = 1.0
            if essFull > 1e-7 {
                let share = essHigh / essFull
                if share > essThreshold { essTarget = max(essFloor, (essThreshold / share).squareRoot()) }
            }
            essGain += essSmooth * (essTarget - essGain)
            l -= (1 - essGain) * hl
            r -= (1 - essGain) * hr

            // Compressor (stereo-linked RMS detector, soft knee).
            rms += rmsCoeff * (max(l * l, r * r) - rms)
            let level = 10 * log10(rms + 1e-12) + 3.0103   // +3 dB: RMS of a sine reads as its peak level
            let target = Self.staticReduction(level: level, threshold: threshold, ratio: ratio, knee: knee)
            reductionDB += (target < reductionDB ? attackCoeff : releaseCoeff) * (target - reductionDB)
            var g = exp((reductionDB + makeupDB) * 0.11512925464970229)   // 10^(dB/20)
            // Plosive catcher: reacts within a millisecond and lets go quickly. Only loud peaks pay for the pow.
            let post = max(abs(l), abs(r)) * g
            var catchTarget = 1.0
            if post > catchLevel { catchTarget = pow(catchLevel / post, catchSlope) }
            catchGain += (catchTarget < catchGain ? catchAttack : catchRelease) * (catchTarget - catchGain)
            g *= catchGain

            left[i] = Float(l * g)
            right[i] = Float(r * g)
        }
    }

    /// Current gain reduction in dB (for meters and tests).
    public var currentReductionDB: Double { reductionDB }
}

/// Estimates inter-sample (true) peaks by 4x oversampling with a windowed-sinc interpolator, as in ITU-R BS.1770.
struct TruePeakInterpolator {
    static let half = 6                    // taps on each side
    static let taps = 2 * half             // 12 taps per phase
    /// Delay between the newest input and the sample whose peak `push` reports.
    static let delay = half

    /// coefficients[p][j]: weight of history sample j for the point p/4 after the centre sample.
    static let coefficients: [[Double]] = (1...3).map { p in
        let frac = Double(p) / 4
        var row = (0..<taps).map { j -> Double in
            let x = frac - Double(j - (half - 1))       // distance from tap j to the interpolated point
            let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let w = 0.5 * (1 + cos(.pi * x / (Double(half) + 0.5)))
            return sinc * w
        }
        let sum = row.reduce(0, +)
        row = row.map { $0 / sum }
        return row
    }

    private var buffer: [Double]
    private var pos = 0

    init() { buffer = Array(repeating: 0, count: 2 * Self.taps) }

    mutating func reset() {
        for i in buffer.indices { buffer[i] = 0 }
        pos = 0
    }

    /// Adds a sample; returns the peak magnitude around the sample `delay` steps back (itself and the 3 points after it).
    @inline(__always) mutating func push(_ x: Double) -> Double {
        buffer[pos] = x
        buffer[pos + Self.taps] = x
        pos = (pos + 1) % Self.taps
        // Window is buffer[pos ..< pos+taps], oldest first; centre sample is index half-1.
        let centre = buffer[pos + Self.half - 1]
        var peak = abs(centre)
        for row in Self.coefficients {
            var acc = 0.0
            var j = 0
            while j < Self.taps { acc += row[j] * buffer[pos + j]; j += 1 }
            peak = max(peak, abs(acc))
        }
        return peak
    }
}

/// Measures the true peak of a stream (linear, all channels).
public final class TruePeakMeter {
    private var interpolators: [TruePeakInterpolator]
    public private(set) var truePeak = 0.0

    public init(channelCount: Int) {
        interpolators = Array(repeating: TruePeakInterpolator(), count: channelCount)
    }

    public func add(channels: [UnsafePointer<Float>], frameCount: Int) {
        for c in 0..<min(channels.count, interpolators.count) {
            for i in 0..<frameCount { truePeak = max(truePeak, interpolators[c].push(Double(channels[c][i]))) }
        }
    }

    public var truePeakDB: Double { linearToDB(truePeak) }
}
