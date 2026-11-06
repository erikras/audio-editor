import Foundation

/// Integrated loudness meter per ITU-R BS.1770-4 / EBU R128 (K-weighting, 400 ms blocks, 75% overlap,
/// absolute gate at -70 LUFS and relative gate at -10 LU). Feed it audio in any chunk size.
public final class LoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    public let channelCount: Int
    private var shelf: [Biquad]
    private var highpass: [Biquad]
    private let subBlockFrames: Int
    private var subBlockEnergy = 0.0
    private var subBlockFill = 0
    private var recentSubBlocks: [Double] = []
    private var blockEnergies: [Double] = []
    public private(set) var samplePeak: Float = 0

    public init(sampleRate: Double, channelCount: Int) {
        self.channelCount = channelCount
        // Coefficients derived for any sample rate (same derivation as libebur128).
        var f0 = 1681.974450955533
        let G = 3.999843853973347
        var Q = 0.7071752369554196
        var K = tan(.pi * f0 / sampleRate)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1.0 + K / Q + K * K
        let s = Biquad(b0: (Vh + Vb * K / Q + K * K) / a0,
                       b1: 2.0 * (K * K - Vh) / a0,
                       b2: (Vh - Vb * K / Q + K * K) / a0,
                       a1: 2.0 * (K * K - 1.0) / a0,
                       a2: (1.0 - K / Q + K * K) / a0)
        f0 = 38.13547087602444
        Q = 0.5003270373238773
        K = tan(.pi * f0 / sampleRate)
        a0 = 1.0 + K / Q + K * K
        let h = Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                       a1: 2.0 * (K * K - 1.0) / a0,
                       a2: (1.0 - K / Q + K * K) / a0)
        shelf = Array(repeating: s, count: channelCount)
        highpass = Array(repeating: h, count: channelCount)
        subBlockFrames = max(Int((sampleRate * 0.1).rounded()), 1)
    }

    /// Adds `frameCount` frames. `channels` holds one pointer per channel.
    public func add(channels: [UnsafePointer<Float>], frameCount: Int) {
        precondition(channels.count == channelCount)
        for i in 0..<frameCount {
            var energy = 0.0
            for c in 0..<channelCount {
                let x = channels[c][i]
                samplePeak = max(samplePeak, abs(x))
                let y = highpass[c].process(shelf[c].process(Double(x)))
                energy += y * y   // channel weights are 1.0 for L/R/mono
            }
            subBlockEnergy += energy
            subBlockFill += 1
            if subBlockFill == subBlockFrames { finishSubBlock() }
        }
    }

    private func finishSubBlock() {
        recentSubBlocks.append(subBlockEnergy / Double(subBlockFrames))
        subBlockEnergy = 0
        subBlockFill = 0
        if recentSubBlocks.count > 4 { recentSubBlocks.removeFirst() }
        if recentSubBlocks.count == 4 {
            blockEnergies.append(recentSubBlocks.reduce(0, +) / 4)
        }
    }

    private static func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(max(energy, 1e-20)) }

    /// Integrated loudness in LUFS, or nil if everything was below the absolute gate (silence).
    public var integratedLoudness: Double? {
        let absGated = blockEnergies.filter { Self.loudness($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let relativeGate = Self.loudness(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { Self.loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return Self.loudness(gated.reduce(0, +) / Double(gated.count))
    }
}

/// Look-ahead peak limiter that keeps output under `ceiling` (linear). Output is delayed by the look-ahead,
/// so call `flush` at the end to drain it.
public final class PeakLimiter {
    private let ceiling: Float
    private let lookahead: Int
    private let attack: Float
    private let release: Float
    private let channelCount: Int
    private var delay: [[Float]]
    private var writeIndex = 0
    private var gain: Float = 1
    // Monotonic deque of (input index, required gain) for a sliding minimum.
    private var dequeIndex: [Int]
    private var dequeValue: [Float]
    private var head = 0, tail = 0
    private var inputIndex = 0

    public init(sampleRate: Double, channelCount: Int, ceilingDB: Double = -1, lookaheadMs: Double = 5, releaseMs: Double = 80) {
        ceiling = Float(dbToLinear(ceilingDB))
        lookahead = max(Int(sampleRate * lookaheadMs / 1000), 1)
        attack = Float(1 - exp(-1.0 / (Double(lookahead) / 5)))
        release = Float(1 - exp(-1.0 / (sampleRate * releaseMs / 1000)))
        self.channelCount = channelCount
        delay = Array(repeating: Array(repeating: 0, count: lookahead), count: channelCount)
        let cap = lookahead + 2
        dequeIndex = Array(repeating: 0, count: cap)
        dequeValue = Array(repeating: 1, count: cap)
    }

    /// Processes in place. `channels` holds one mutable pointer per channel.
    public func process(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let cap = dequeIndex.count
        for i in 0..<frameCount {
            var peak: Float = 0
            for c in 0..<channelCount { peak = max(peak, abs(channels[c][i])) }
            let required: Float = peak > ceiling ? ceiling / peak : 1
            // Push into sliding-min deque.
            while head != tail {
                let last = (tail - 1 + cap) % cap
                if dequeValue[last] >= required { tail = last } else { break }
            }
            dequeIndex[tail] = inputIndex
            dequeValue[tail] = required
            tail = (tail + 1) % cap
            while dequeIndex[head] <= inputIndex - (lookahead + 1) { head = (head + 1) % cap }
            let target = dequeValue[head]
            gain += (target < gain ? attack : release) * (target - gain)
            if target < gain && dequeIndex[head] == inputIndex - lookahead { gain = target }
            inputIndex += 1
            // Swap the current input into the delay line and emit the delayed sample.
            for c in 0..<channelCount {
                let delayed = delay[c][writeIndex]
                delay[c][writeIndex] = channels[c][i]
                var y = delayed * gain
                if y > ceiling { y = ceiling } else if y < -ceiling { y = -ceiling }
                channels[c][i] = y
            }
            writeIndex = (writeIndex + 1) % lookahead
        }
    }

    /// Number of frames still held in the delay line.
    public var latency: Int { lookahead }
}
