import Foundation

/// What a Prevent Sleep session is waiting for. Every kind ends by itself; the
/// only one that runs forever is the one that says so.
enum SleepSession: Equatable {
    case indefinite
    /// Covers both the duration presets and "Until…" — a length of time is
    /// just an end date computed at the moment you pick it.
    case until(Date)
    case whileAppRuns(bundleID: String, name: String)
    /// Amphetamine's model: watch one file, and stop once it has gone
    /// `timeout` seconds without growing or changing.
    case whileFileGrows(url: URL, timeout: TimeInterval)

    static func lasting(_ minutes: Int) -> SleepSession {
        .until(Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    var endDate: Date? {
        if case .until(let date) = self { return date }
        return nil
    }

    /// Reads after "Prevent Sleep on — ".
    var summary: String {
        switch self {
        case .indefinite:
            return "until you stop it"
        case .until(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "until \(formatter.string(from: date))"
        case .whileAppRuns(_, let name):
            return "while \(name) is running"
        case .whileFileGrows(let url, _):
            return "while \(url.lastPathComponent) downloads"
        }
    }
}

/// Countdown text, shared by the menubar item and the session card so they
/// never drift apart.
enum Countdown {
    /// Tight enough for a menubar: "1:05", "42m", "58s".
    static func short(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded())
        if seconds >= 3600 {
            return "\(seconds / 3600):\(String(format: "%02d", (seconds % 3600) / 60))"
        }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    static func long(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded())
        if seconds >= 3600 {
            let minutes = (seconds % 3600) / 60
            return minutes == 0 ? "\(seconds / 3600) h left" : "\(seconds / 3600) h \(minutes) min left"
        }
        if seconds >= 60 { return "\(seconds / 60) min left" }
        return "\(seconds) sec left"
    }
}
