import Foundation

/// Converts between seconds and "h:mm:ss.mmm" style strings.
///
/// Accepts every form seen in session files: "05.205", "1:17:19.787", "16.314", "0", "2:03".
public enum Timecode {
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let negative = trimmed.hasPrefix("-")
        let body = negative ? String(trimmed.dropFirst()) : trimmed
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Only the last component may carry a fraction.
            if index < parts.count - 1, value.rounded() != value { return nil }
            total = total * 60 + value
        }
        return negative ? -total : total
    }

    /// Formats seconds as "m:ss.mmm" or "h:mm:ss.mmm".
    public static func format(_ seconds: Double, showMillis: Bool = true) -> String {
        let negative = seconds < 0
        let totalMillis = Int((abs(seconds) * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if showMillis { out += String(format: ".%03d", millis) }
        return negative ? "-" + out : out
    }
}

@inlinable public func dbToLinear(_ db: Double) -> Double { pow(10, db / 20) }
@inlinable public func linearToDB(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-12)) }
