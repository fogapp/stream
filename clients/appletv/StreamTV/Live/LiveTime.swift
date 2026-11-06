import Foundation

/// The arithmetic of "live" (PROPOSAL §7.7), kept pure for tests: where live
/// is in an airing, what's on a channel at a moment, which channel is next.
enum LiveTime {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ text: String) -> Date {
        fractional.date(from: text) ?? whole.date(from: text) ?? .distantPast
    }

    /// Seconds to add to this device's clock for the server's.
    static func skew(serverNow: String, receivedAt: Date = Date()) -> TimeInterval {
        let server = date(serverNow)
        return server == .distantPast ? 0 : server.timeIntervalSince(receivedAt)
    }

    /// How far into an airing a moment is, within it.
    static func offset(starts: Date, ends: Date, at now: Date) -> Double {
        min(max(now.timeIntervalSince(starts), 0), max(ends.timeIntervalSince(starts), 0))
    }

    /// Where live is in a session's file: a part of a program starts partway in.
    static func position(_ live: LiveInfo, at now: Date) -> Double {
        (live.mediaStart ?? 0) + offset(starts: live.starts, ends: live.ends, at: now)
    }

    /// What's on a channel then (filler included), and the next program.
    static func onAt(_ airings: [Airing], _ now: Date) -> (current: Airing?, next: Airing?) {
        let current = airings.first { $0.starts <= now && $0.ends > now }
        let next = airings.first { $0.starts > now && $0.filler != true }
        return (current, next)
    }

    /// The channel after (1) or before (-1) this one, wrapping around.
    static func adjacent<T>(_ stations: [T], number: String, step: Int, numberOf: (T) -> String) -> T? {
        guard !stations.isEmpty else { return nil }
        guard let index = stations.firstIndex(where: { numberOf($0) == number }) else { return stations.first }
        return stations[(index + step + stations.count) % stations.count]
    }

    /// A channel's programs for the guide: no filler, a program's parts as one.
    static func programs(_ airings: [Airing]) -> [(airing: Airing, ends: Date)] {
        var joined: [(airing: Airing, ends: Date)] = []
        for airing in airings where airing.filler != true {
            if let last = joined.last, (airing.mediaStart ?? 0) > 0, last.airing.playableId == airing.playableId {
                joined[joined.count - 1].ends = airing.ends
            } else {
                joined.append((airing, airing.ends))
            }
        }
        return joined
    }

    static func clock(_ date: Date, timeZone: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
