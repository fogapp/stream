import Foundation

/// Stream's text subtitles are WebVTT (PROPOSAL §5.5); AVPlayer won't take
/// them beside an MP4 or a stream it didn't list, so the app reads them
/// itself and draws the current cue over the picture.
struct WebVTT: Equatable {
    struct Cue: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    let cues: [Cue]

    init(cues: [Cue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    init(parsing source: String) {
        var cues: [Cue] = []
        let blocks = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = Self.seconds(parts[0]), let end = Self.seconds(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let text = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: Self.plain(text)))
        }
        self.init(cues: cues)
    }

    /// What's on screen at a time: every cue covering it, in order.
    func text(at time: Double) -> String? {
        // The last cue starting at or before the time, then back over any
        // earlier ones still showing.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var showing: [String] = []
        var index = low - 1
        while index >= 0, index >= low - 8 {
            let cue = cues[index]
            if cue.start <= time && time < cue.end { showing.insert(cue.text, at: 0) }
            index -= 1
        }
        return showing.isEmpty ? nil : showing.joined(separator: "\n")
    }

    /// "00:01:02.500", "01:02.500" → seconds.
    static func seconds(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Without WebVTT's styling tags (<i>, <c.yellow>, <00:01.000>) and entities.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
