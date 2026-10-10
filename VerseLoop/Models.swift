import Foundation

// MARK: - Verse

/// A memorizable verse. NOTE: ESV text is never bundled in this repo
/// (Crossway copyright). ESV passages are fetched at runtime via the
/// user's ESV API key or the bundled Cloudflare Worker proxy, then
/// cached on-device for personal memorization use only.
struct Verse: Identifiable, Codable, Equatable {
    var id: UUID
    var reference: String
    var text: String
    /// "esv" | "manual" | "kjv-demo" (public-domain seeds for simulator/demo)
    var textSource: String
    var addedAt: Date

    init(id: UUID = UUID(), reference: String, text: String, textSource: String, addedAt: Date = Date()) {
        self.id = id
        self.reference = reference
        self.text = text
        self.textSource = textSource
        self.addedAt = addedAt
    }

    var words: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// First-letter hint per word, e.g. "The LORD is my shepherd" -> T L i m s
    var hints: [String] {
        words.map { w in
            if let c = w.first(where: { $0.isLetter }) { return String(c) }
            return "•"
        }
    }
}

// MARK: - Grades (explicit user feedback drives SM-2)

enum Grade: String, CaseIterable, Codable {
    case again, hard, good, easy

    var title: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    var systemImage: String {
        switch self {
        case .again: return "arrow.counterclockwise"
        case .hard: return "hand.thumbsdown"
        case .good: return "hand.thumbsup"
        case .easy: return "sparkles"
        }
    }
}

// MARK: - Review state + SM-2 (lite, Anki-style)

struct ReviewState: Codable, Equatable {
    var verseId: UUID
    var ease: Double
    var intervalDays: Int
    var due: Date
    var reps: Int
    var lapses: Int
    var totalPeeks: Int
    var lastGrade: Grade?

    static func fresh(verseId: UUID, now: Date = Date()) -> ReviewState {
        ReviewState(verseId: verseId, ease: 2.5, intervalDays: 0, due: now, reps: 0, lapses: 0, totalPeeks: 0, lastGrade: nil)
    }

    var isDue: Bool { due <= Date() }

    /// Explicit grade -> next state. Taps/peeks never grade implicitly;
    /// they are recorded separately and can be zeroed by the "accidental" flag.
    func advanced(with grade: Grade, peeks: Int, now: Date = Date()) -> ReviewState {
        var r = self
        r.totalPeeks += peeks
        r.lastGrade = grade
        switch grade {
        case .again:
            r.lapses += 1
            r.ease = max(1.3, r.ease - 0.20)
            r.reps = 0
            r.intervalDays = 0
            r.due = now.addingTimeInterval(10 * 60) // retry in ~10 min
        case .hard:
            r.ease = max(1.3, r.ease - 0.15)
            r.reps += 1
            r.intervalDays = r.reps <= 1 ? 1 : max(1, Int((Double(max(r.intervalDays, 1)) * 1.2).rounded()))
            r.due = Self.endOfDay(afterDays: r.intervalDays, from: now)
        case .good:
            r.reps += 1
            if r.reps <= 1 { r.intervalDays = 1 }
            else if r.reps == 2 { r.intervalDays = 3 }
            else { r.intervalDays = max(1, Int((Double(r.intervalDays) * r.ease).rounded())) }
            r.due = Self.endOfDay(afterDays: r.intervalDays, from: now)
        case .easy:
            r.ease += 0.15
            r.reps += 1
            if r.reps <= 1 { r.intervalDays = 4 }
            else { r.intervalDays = max(1, Int((Double(max(r.intervalDays, 1)) * r.ease * 1.3).rounded())) }
            r.due = Self.endOfDay(afterDays: r.intervalDays, from: now)
        }
        return r
    }

    static func endOfDay(afterDays days: Int, from date: Date) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: days, to: start) ?? date
    }
}

// MARK: - Persistence envelope (also the sync/export format, v1)

struct LibraryEnvelope: Codable {
    var version: Int
    var verses: [Verse]
    var reviews: [ReviewState]
}
