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

// MARK: - Grades (explicit user feedback drives scheduling)

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

// MARK: - FSRS core (compact FSRS-inspired scheduler, zero dependencies)
//
// Replaces SM-2-lite. This is an FSRS-6-*inspired* core written inline so
// the app keeps its zero-dependency guardrail (no swift-fsrs package).
// The constants below are plausible FSRS-6-style DEFAULT weights, not
// fitted to any user data; a per-user optimizer is deferred. Examples use
// invented strings only — never ESV text.
//
// KEY lapse guarantee: a lapse on a mature card does NOT nuke stability.
// Again multiplies stability by 0.25 (floor 0.1d), and a lapse on a card
// with stability >= 7d schedules max(1, round(S_new * 0.15)) >= 1 day —
// never the old 10-minute reset. E.g. S=30d, Again -> S=7.5d ->
// interval = max(1, round(7.5 * 0.15)) = 1d. Young lapses (S < 7d) retry same-day
// (interval 0, due +10min) as before.

enum FSRSCore {
    /// Desired retention (probability of recall at due time). 0.9 default.
    static let defaultRetention: Double = 0.9
    /// Hard cap on any scheduled interval.
    static let maxIntervalDays: Int = 365
    /// Stability at/above which a lapse still schedules >= 1 day out.
    static let matureThresholdDays: Double = 7
    /// Mature-lapse interval = max(1, round(nextStability * fraction)).
    /// S=30d -> nextS=7.5d -> 1d (never the 10-min nuke).

    // MARK: Forgetting-curve constants (FSRS-6 standard)

    /// FACTOR = 0.9^(1/-0.5) - 1 ≈ 0.2348, DECAY = -0.5.
    static let forgettingFactor: Double = 0.2348
    static let forgettingDecay: Double = -0.5

    // MARK: Stability-growth weights (FSRS-6-style defaults)

    static let w8: Double = 1.2
    static let w9: Double = 0.3
    static let w10: Double = 2.0
    /// Grade multiplier on the growth term: Hard grows slower…
    static let wHard: Double = 0.8
    /// …Easy grows faster (spec: Easy gets an extra ~1.3x).
    static let wEasy: Double = 1.3
    /// Hard recall still grows stability modestly even when the curve term ~0.
    static let hardMinGrowth: Double = 1.15

    /// New-card initial stability (days at 90% retention) per grade.
    static func initialStability(for grade: Grade) -> Double {
        switch grade {
        case .again: return 0.3
        case .hard: return 0.8
        case .good: return 2.0
        case .easy: return 4.5
        }
    }

    /// New-card initial difficulty (1...10) per grade.
    static func initialDifficulty(for grade: Grade) -> Double {
        switch grade {
        case .again: return 7.0
        case .hard: return 6.0
        case .good: return 5.0
        case .easy: return 4.0
        }
    }

    /// R(t, S) = (1 + FACTOR * t / S)^DECAY — recall probability t days
    /// after a review that left stability S (days).
    static func forgettingCurve(elapsedDays t: Double, stability s: Double) -> Double {
        let sSafe = max(s, 0.01)
        let tSafe = max(t, 0)
        return pow(1 + forgettingFactor * tSafe / sSafe, forgettingDecay)
    }

    /// Linear-damping difficulty update, clamped 1...10.
    /// Again +1.2, Hard +0.3, Good -0.2, Easy -0.8.
    static func nextDifficulty(difficulty: Double, grade: Grade) -> Double {
        let delta: Double
        switch grade {
        case .again: delta = 1.2
        case .hard: delta = 0.3
        case .good: delta = -0.2
        case .easy: delta = -0.8
        }
        return min(10, max(1, difficulty + delta))
    }

    /// Next stability S' (days) after a recall with retrievability R.
    ///
    /// Success: S' = S * (1 + exp(w8) * (11-D) * S^-w9 * (exp((1-R)*w10)-1)
    ///   * gradeMultiplier), gradeMultiplier = wHard (Hard), wEasy (Easy),
    ///   1.0 (Good). Hard additionally floors at S * 1.15 so a hard-won
    ///   recall always grows stability a little.
    /// Lapse (Again): S' = max(0.1, S * 0.25) — a proportional cut, never
    ///   a reset to ~0. S=30d -> 7.5d, so the next interval stays >= 1d.
    static func nextStability(stability: Double, difficulty: Double, retrievability: Double, grade: Grade) -> Double {
        let s = max(stability, 0.01)
        guard grade != .again else { return max(0.1, s * 0.25) }
        let r = min(max(retrievability, 0.01), 0.999)
        let d = min(max(difficulty, 1), 10)
        let curveTerm = exp(w8) * (11 - d) * pow(s, -w9) * (exp((1 - r) * w10) - 1)
        let multiplier: Double
        switch grade {
        case .hard: multiplier = wHard
        case .easy: multiplier = wEasy
        default: multiplier = 1.0
        }
        var grown = s * (1 + max(0, curveTerm) * multiplier)
        if grade == .hard { grown = max(grown, s * hardMinGrowth) }
        if grade == .easy { grown = max(grown, s * wEasy) }
        return max(0.1, grown)
    }

    /// Days until retrievability decays to `retention`:
    ///   I = max(1, round(S * ln(retention) / ln(0.9))).
    /// At retention 0.9 the interval equals stability exactly; higher
    /// retention shortens it. Capped at maxIntervalDays (365d).
    ///
    /// Lapse routing lives in ReviewState.advanced (which knows the grade
    /// and maturity): mature lapses (S >= 7d) -> max(1, round(S_new * 0.15));
    /// young lapses -> 0 (retry today, due +10min as before).
    static func nextInterval(stability: Double, retention: Double = defaultRetention) -> Int {
        let s = max(stability, 0.01)
        let ret = min(max(retention, 0.5), 0.999)
        let days = (s * log(ret) / log(0.9)).rounded()
        return min(maxIntervalDays, max(1, Int(days)))
    }
}

// MARK: - Review state (FSRS-scheduled; ease/intervalDays kept for compat)

struct ReviewState: Codable, Equatable {
    var verseId: UUID
    /// Legacy SM-2 ease. No longer drives scheduling (FSRS does); retained
    /// for old clients + debug display.
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
    /// regress scheduling progress.
    var updatedAt: Date
    /// FSRS memory stability in days (nil for never-reviewed / pre-FSRS).
    var stability: Double?
    /// FSRS difficulty 1...10 (nil for never-reviewed / pre-FSRS).
    var difficulty: Double?

    private enum CodingKeys: String, CodingKey {
        case verseId, ease, intervalDays, due, reps, lapses, lastGrade
        case totalHints = "totalPeeks" // v1 key kept so existing libraries still decode
        case updatedAt
        case stability, difficulty
    }

    init(verseId: UUID, ease: Double, intervalDays: Int, due: Date, reps: Int, lapses: Int, totalHints: Int, lastGrade: Grade?, updatedAt: Date? = nil, stability: Double? = nil, difficulty: Double? = nil) {
        self.verseId = verseId
        self.ease = ease
        self.intervalDays = intervalDays
        self.due = due
        self.reps = reps
        self.lapses = lapses
        self.totalHints = totalHints
        self.lastGrade = lastGrade
        self.updatedAt = updatedAt ?? Date()
        self.stability = stability
        self.difficulty = difficulty
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
        // Pre-FSRS records carry no S/D — nil so the next grade initializes.
        stability = try c.decodeIfPresent(Double.self, forKey: .stability)
        difficulty = try c.decodeIfPresent(Double.self, forKey: .difficulty)
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
        try c.encodeIfPresent(stability, forKey: .stability)
        try c.encodeIfPresent(difficulty, forKey: .difficulty)
    }

    static func fresh(verseId: UUID, now: Date = Date()) -> ReviewState {
        ReviewState(verseId: verseId, ease: 2.5, intervalDays: 0, due: now, reps: 0, lapses: 0, totalHints: 0, lastGrade: nil, stability: nil, difficulty: nil)
    }

    /// Human-friendly stability stage. Drives the list subtitle so raw
    /// scheduler internals never leak into the default UI.
    var stageLabel: String {
        if reps >= 5 && intervalDays >= 21 { return "Stable" }
        if intervalDays >= 7 { return "Growing" }
        if reps <= 1 { return "New" }
        return "Learning"
    }

    /// Default list subtitle: "Learning · every 3d" (stage only when new).
    var friendlySchedule: String {
        if intervalDays < 1 { return stageLabel }
        return "\(stageLabel) · every \(intervalDays)d"
    }

    /// Debug list subtitle behind Settings → Show scheduler details.
    /// FSRS values when present ("S7.5d · D6.2 · ×4"), legacy E-values
    /// ("E2.50 · ×4") for pre-FSRS records.
    var detailedSchedule: String {
        if let s = stability, let d = difficulty {
            let base = "S\(String(format: "%.1f", s))d · D\(String(format: "%.1f", d)) · ×\(reps)"
            if intervalDays < 1 { return base }
            return "\(base) · every \(intervalDays)d"
        }
        let base = "E\(String(format: "%.2f", ease)) · ×\(reps)"
        if intervalDays < 1 { return base }
        return "\(base) · every \(intervalDays)d"
    }

    var isDue: Bool { due <= Date() }

    /// Tick-aware variant: pass the TimelineView date so rows recompute
    /// (and SwiftUI sees new inputs) on every tick. See LoopTab.
    func isDue(at now: Date) -> Bool { due <= now }

    /// Current retrievability R (probability of recall right now), or nil
    /// when never reviewed (no stability yet).
    func retrievability(at now: Date = Date(), retention: Double = FSRSCore.defaultRetention) -> Double? {
        guard let s = stability else { return nil }
        let elapsed = max(0, now.timeIntervalSince(updatedAt) / 86400)
        _ = retention
        return FSRSCore.forgettingCurve(elapsedDays: elapsed, stability: s)
    }

    /// Interval (days) each grade would schedule from this state, without
    /// mutating. Powers ReviewView button previews.
    func previewIntervals(retention: Double = FSRSCore.defaultRetention, now: Date = Date()) -> [(Grade, Int)] {
        Grade.allCases.map { grade in (grade, hypotheticalInterval(for: grade, retention: retention, now: now)) }
    }

    /// Shared next-interval math for advanced() + previewIntervals so the
    /// preview buttons can never disagree with the applied grade.
    private func hypotheticalInterval(for grade: Grade, retention: Double, now: Date) -> Int {
        if let s = stability, let d = difficulty {
            let r = FSRSCore.forgettingCurve(
                elapsedDays: max(0, now.timeIntervalSince(updatedAt) / 86400),
                stability: s)
            let nextS = FSRSCore.nextStability(stability: s, difficulty: d, retrievability: r, grade: grade)
            if grade == .again {
                if s >= FSRSCore.matureThresholdDays || intervalDays >= 7 {
                    return min(FSRSCore.maxIntervalDays, max(1, Int((nextS * 0.15).rounded())))
                }
                return 0
            }
            return FSRSCore.nextInterval(stability: nextS, retention: retention)
        }
        // New card (or pre-FSRS record): initial stability per grade.
        let initS = FSRSCore.initialStability(for: grade)
        if grade == .again { return 0 }
        return FSRSCore.nextInterval(stability: initS, retention: retention)
    }

    /// Explicit grade -> next state (FSRS). Typing mistakes never grade
    /// implicitly; they are recorded separately, already net of per-word
    /// accidental forgiveness.
    ///
    /// Again never resets: reps stays, lapses += 1, and a mature card
    /// (stability or intervalDays >= 7) reschedules >= 1 day out.
    func advanced(with grade: Grade, mistakes: Int, retention: Double = FSRSCore.defaultRetention, now: Date = Date()) -> ReviewState {
        var r = self
        r.updatedAt = now
        r.totalHints += mistakes
        r.lastGrade = grade

        let priorStability = stability
        let priorDifficulty = difficulty
        let wasMature = (priorStability ?? Double(intervalDays)) >= FSRSCore.matureThresholdDays
            || intervalDays >= 7

        if let s = priorStability, let d = priorDifficulty {
            let retrievability = FSRSCore.forgettingCurve(
                elapsedDays: max(0, now.timeIntervalSince(updatedAt) / 86400),
                stability: s)
            let nextS = FSRSCore.nextStability(stability: s, difficulty: d, retrievability: retrievability, grade: grade)
            r.stability = nextS
            r.difficulty = FSRSCore.nextDifficulty(difficulty: d, grade: grade)
            if grade == .again {
                r.lapses += 1
                // No rep reset (FSRS has no reps concept); keep reps as-is.
                if wasMature {
                    // Mature lapse: proportional cut, still >= 1 day out.
                    r.intervalDays = min(FSRSCore.maxIntervalDays, max(1, Int((nextS * 0.15).rounded())))
                    r.due = Self.endOfDay(afterDays: r.intervalDays, from: now)
                } else {
                    r.intervalDays = 0
                    r.due = now.addingTimeInterval(10 * 60) // retry in ~10 min
                }
            } else {
                r.reps += 1
                r.intervalDays = FSRSCore.nextInterval(stability: nextS, retention: retention)
                r.due = Self.endOfDay(afterDays: r.intervalDays, from: now)
            }
        } else {
            // First FSRS grade (new card or pre-FSRS record): initialize S/D.
            r.stability = FSRSCore.initialStability(for: grade)
            r.difficulty = FSRSCore.initialDifficulty(for: grade)
            if grade == .again {
                r.lapses += 1
                r.intervalDays = 0
                r.due = now.addingTimeInterval(10 * 60)
            } else {
                r.reps += 1
                r.intervalDays = FSRSCore.nextInterval(stability: r.stability!, retention: retention)
                r.due = Self.endOfDay(afterDays: r.intervalDays, from: now)
            }
        }
        return r
    }

    /// Legacy wrapper (SM-2-era signature) so existing callers keep compiling
    /// during migration. Schedules at default retention (0.9).
    func advanced(with grade: Grade, mistakes: Int, now: Date = Date()) -> ReviewState {
        advanced(with: grade, mistakes: mistakes, retention: FSRSCore.defaultRetention, now: now)
    }

    static func endOfDay(afterDays days: Int, from date: Date) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: days, to: start) ?? date
    }
}

// MARK: - Review log (FSRS history; powers future optimizer + stats)

/// One graded review. Missing stability/retention decode to nil/defaults
/// so entries written before FSRS still decode.
struct ReviewLogEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var verseId: UUID
    var reviewedAt: Date
    var grade: Grade
    var mistakes: Int
    var prevIntervalDays: Int
    var nextIntervalDays: Int
    var prevStability: Double?
    var nextStability: Double?
    var retention: Double

    init(id: UUID = UUID(), verseId: UUID, reviewedAt: Date = Date(), grade: Grade, mistakes: Int, prevIntervalDays: Int, nextIntervalDays: Int, prevStability: Double? = nil, nextStability: Double? = nil, retention: Double = FSRSCore.defaultRetention) {
        self.id = id
        self.verseId = verseId
        self.reviewedAt = reviewedAt
        self.grade = grade
        self.mistakes = mistakes
        self.prevIntervalDays = prevIntervalDays
        self.nextIntervalDays = nextIntervalDays
        self.prevStability = prevStability
        self.nextStability = nextStability
        self.retention = retention
    }

    private enum CodingKeys: String, CodingKey {
        case id, verseId, reviewedAt, grade, mistakes
        case prevIntervalDays, nextIntervalDays
        case prevStability, nextStability, retention
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        verseId = try c.decode(UUID.self, forKey: .verseId)
        reviewedAt = try c.decode(Date.self, forKey: .reviewedAt)
        grade = try c.decode(Grade.self, forKey: .grade)
        mistakes = try c.decodeIfPresent(Int.self, forKey: .mistakes) ?? 0
        prevIntervalDays = try c.decodeIfPresent(Int.self, forKey: .prevIntervalDays) ?? 0
        nextIntervalDays = try c.decodeIfPresent(Int.self, forKey: .nextIntervalDays) ?? 0
        prevStability = try c.decodeIfPresent(Double.self, forKey: .prevStability)
        nextStability = try c.decodeIfPresent(Double.self, forKey: .nextStability)
        retention = try c.decodeIfPresent(Double.self, forKey: .retention) ?? FSRSCore.defaultRetention
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(verseId, forKey: .verseId)
        try c.encode(reviewedAt, forKey: .reviewedAt)
        try c.encode(grade, forKey: .grade)
        try c.encode(mistakes, forKey: .mistakes)
        try c.encode(prevIntervalDays, forKey: .prevIntervalDays)
        try c.encode(nextIntervalDays, forKey: .nextIntervalDays)
        try c.encodeIfPresent(prevStability, forKey: .prevStability)
        try c.encodeIfPresent(nextStability, forKey: .nextStability)
        try c.encode(retention, forKey: .retention)
    }
}

// MARK: - Persistence envelope (also the sync/export format, v1/v2/v3)

/// Tombstone so deletes propagate: without this, merge-as-union would
/// resurrect a deleted verse on the next pull of an older snapshot.
struct DeletedEntry: Codable, Equatable {
    var verseId: UUID
    var deletedAt: Date
}

struct LibraryEnvelope: Codable {
    /// 1 = original (no updatedAt/tombstones), 2 = newer-wins fields,
    /// 3 = FSRS fields (stability/difficulty) + review history.
    /// Decoders accept any version; encoders always write 3.
    var version: Int
    var verses: [Verse]
    var reviews: [ReviewState]
    var deleted: [DeletedEntry]
    /// FSRS review history (v3+). Missing in older payloads -> [].
    var history: [ReviewLogEntry]

    init(version: Int = 3, verses: [Verse], reviews: [ReviewState], deleted: [DeletedEntry] = [], history: [ReviewLogEntry] = []) {
        self.version = version
        self.verses = verses
        self.reviews = reviews
        self.deleted = deleted
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case version, verses, reviews, deleted, history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        verses = try c.decode([Verse].self, forKey: .verses)
        reviews = try c.decode([ReviewState].self, forKey: .reviews)
        deleted = try c.decodeIfPresent([DeletedEntry].self, forKey: .deleted) ?? []
        history = try c.decodeIfPresent([ReviewLogEntry].self, forKey: .history) ?? []
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
