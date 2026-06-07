import Foundation

enum DurationFormatter {
    // "1d 2h 03m", "1h 02m", or "5m 30s" depending on magnitude.
    static func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if d > 0 { return String(format: "%dd %dh %02dm", d, h, m) }
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, sec)
    }
}
