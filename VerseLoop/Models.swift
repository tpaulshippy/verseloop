import Foundation

// MARK: - Verse

/// A memorizable verse. NOTE: ESV text is never bundled in this repo
/// (Crossway copyright). ESV passages are fetched at runtime via the
/// user's ESV API key or the bundled Cloudflare Worker proxy, then
/// cached on-device for personal memorization use only.
struct Verse: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var reference: String
    var text: String
    /// "esv" | "manual" | "kjv-demo" (public-domain seeds for simulator/demo)
    var textSource: String
    var addedAt: Date
    /// Last local mutation (creation/edit). Drives newer-wins merge so a
    /// stale pull never reverts newer local state.
    var updatedAt: Date

    init(id: UUID = UUID(), reference: String, text: String, textSource: String, addedAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.reference = reference
        self.text = text
        self.textSource = textSource
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, reference, text, textSource, addedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        reference = try c.decode(String.self, forKey: .reference)
        text = try c.decode(String.self, forKey: .text)
        textSource = try c.decode(String.self, forKey: .textSource)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        // Old libraries (v1) have no updatedAt — fall back to addedAt so
        // existing records tie (local kept) until either side mutates.
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? addedAt
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
    /// Assists used across reps (v1 "peeks", v2 mistakes). Advisory only —
    /// only explicit grades move the schedule.
    var totalHints: Int
    var lastGrade: Grade?
    /// Last local grade/undo. Newer-wins on merge so stale pulls can't
    /// regress SM-2 progress.
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case verseId, ease, intervalDays, due, reps, lapses, lastGrade
        case totalHints = "totalPeeks" // v1 key kept so existing libraries still decode
        case updatedAt
    }

    init(verseId: UUID, ease: Double, intervalDays: Int, due: Date, reps: Int, lapses: Int, totalHints: Int, lastGrade: Grade?, updatedAt: Date? = nil) {
        self.verseId = verseId
        self.ease = ease
        self.intervalDays = intervalDays
        self.due = due
        self.reps = reps
        self.lapses = lapses
        self.totalHints = totalHints
        self.lastGrade = lastGrade
        self.updatedAt = updatedAt ?? Date()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verseId = try c.decode(UUID.self, forKey: .verseId)
        ease = try c.decode(Double.self, forKey: .ease)
        intervalDays = try c.decode(Int.self, forKey: .intervalDays)
        due = try c.decode(Date.self, forKey: .due)
        reps = try c.decode(Int.self, forKey: .reps)
        lapses = try c.decode(Int.self, forKey: .lapses)
        totalHints = try c.decodeIfPresent(Int.self, forKey: .totalHints) ?? 0
        lastGrade = try c.decodeIfPresent(Grade.self, forKey: .lastGrade)
        // Old records have no updatedAt. Fall back to the epoch so any
        // newly-graded record strictly wins; two old records tie (local kept).
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verseId, forKey: .verseId)
        try c.encode(ease, forKey: .ease)
        try c.encode(intervalDays, forKey: .intervalDays)
        try c.encode(due, forKey: .due)
        try c.encode(reps, forKey: .reps)
        try c.encode(lapses, forKey: .lapses)
        try c.encode(totalHints, forKey: .totalHints)
        try c.encodeIfPresent(lastGrade, forKey: .lastGrade)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    static func fresh(verseId: UUID, now: Date = Date()) -> ReviewState {
        ReviewState(verseId: verseId, ease: 2.5, intervalDays: 0, due: now, reps: 0, lapses: 0, totalHints: 0, lastGrade: nil)
    }

    var isDue: Bool { due <= Date() }

    /// Explicit grade -> next state. Typing mistakes never grade implicitly;
    /// they are recorded separately, already net of per-word accidental forgiveness.
    func advanced(with grade: Grade, mistakes: Int, now: Date = Date()) -> ReviewState {
        var r = self
        r.updatedAt = now
        r.totalHints += mistakes
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

// MARK: - Persistence envelope (also the sync/export format, v1/v2)

/// Tombstone so deletes propagate: without this, merge-as-union would
/// resurrect a deleted verse on the next pull of an older snapshot.
struct DeletedEntry: Codable, Equatable {
    var verseId: UUID
    var deletedAt: Date
}

struct LibraryEnvelope: Codable {
    /// 1 = original (no updatedAt/tombstones), 2 = newer-wins fields.
    /// Decoders accept either; encoders always write 2.
    var version: Int
    var verses: [Verse]
    var reviews: [ReviewState]
    var deleted: [DeletedEntry]

    init(version: Int = 2, verses: [Verse], reviews: [ReviewState], deleted: [DeletedEntry] = []) {
        self.version = version
        self.verses = verses
        self.reviews = reviews
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case version, verses, reviews, deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        verses = try c.decode([Verse].self, forKey: .verses)
        reviews = try c.decode([ReviewState].self, forKey: .reviews)
        deleted = try c.decodeIfPresent([DeletedEntry].self, forKey: .deleted) ?? []
    }
}

// MARK: - Encrypted sync envelope (v2, end-to-end encrypted)
//
// The sync code the user sees IS the password: a 256-bit key is derived
// from it with HKDF-SHA256, and the library JSON is sealed with AES-GCM.
// The server (Cloudflare Worker, or anyone holding a snapshot) only ever
// sees `ciphertext` and cannot read verses, reviews, or schedule state.
// Forgiving a mistake or grading never touches this layer — it only
// changes what gets encrypted next push.

struct EncryptedEnvelope: Codable {
    var version: Int // always 2
    var ciphertext: String // base64 AES-GCM combined (nonce + ct + tag)
    var updatedAt: Date
}
