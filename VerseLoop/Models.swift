import Foundation
import FSRS

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

// MARK: - FSRS core (real scheduler via the swift-fsrs package, zero other deps)
//
// Scheduling math lives in the `swift-fsrs` package (FSRS-6 default weights);
// this enum is a thin adapter that owns our product pins. Per call we build a
// transient library Card from our stored fields, run it through a freshly
// constructed `FSRS` instance, and write the resulting memory state back.
// This structurally resolves the earlier review finding that our old inline
// interval formula did not invert the forgetting curve — the inversion now
// happens inside the library (`nextInterval` scaling by `intervalModifier`).
//
// Textbook FSRS: short-term (learning/relearning) steps are enabled, so the
// due date comes straight from the library card in all cases — minute
// precision while a card is still being learned, day precision once it
// graduates. The ONE intentional deviation from textbook is
// `maximumInterval: 365`, a product guardrail so a verse never schedules
// decades out; everything else follows the library defaults
// (learning steps 1m/10m, relearning steps 10m).

enum FSRSCore {
    /// Desired retention (probability of recall at due time). 0.9 default.
    static let defaultRetention: Double = 0.9
    /// Hard cap on any scheduled interval. This is the one intentional
    /// deviation from textbook FSRS (a product guardrail so verses never
    /// schedule decades out); everything else follows library defaults.
    static let maxIntervalDays: Int = 365

    /// Per-call scheduler at the requested retention. Constructed fresh per
    /// grade/preview so `requestRetention` always applies; the instance is an
    /// immutable value-style config wrapper, so this is cheap.
    /// `enableFuzz: false` keeps scheduling deterministic so the grade-button
    /// previews can never disagree with the applied grade.
    /// `enableShortTerm: true` is textbook FSRS: learning steps (1m/10m) and
    /// relearning steps (10m) come from the library defaults, so lapses come
    /// back in ~10 minutes through relearning steps.
    static func makeScheduler(retention: Double = defaultRetention) -> FSRS {
        FSRS(parameters: FSRSParameters(
            requestRetention: retention,
            maximumInterval: Double(maxIntervalDays),
            w: FSRSDefaults.defaultWv6,
            enableFuzz: false,
            enableShortTerm: true
        ))
    }

    /// Our explicit grades map 1:1 onto library ratings (never `.manual` —
    /// every review here is an explicit user grade).
    static func rating(for grade: Grade) -> Rating {
        switch grade {
        case .again: return .again
        case .hard: return .hard
        case .good: return .good
        case .easy: return .easy
        }
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
    /// Last explicit grade time. Drives library elapsed time (the scheduler
    /// counts whole UTC calendar days from this date); nil for never-reviewed
    /// or pre-lastReview records, which fall back to `updatedAt`.
    ///
    /// UNDO CONTRACT: undoLastGrade() must restore previous.lastReview verbatim (never now), or elapsed time restarts.
    var lastReview: Date?
    /// Library card state raw value (CardState: 0 new / 1 learning / 2 review /
    /// 3 relearning). Nil for never-reviewed / pre-persistence records, which
    /// reconstruct as `.new` / `.review` respectively. Written back from the
    /// graded library card on every grade so intraday learning/relearning
    /// steps survive across calls instead of resetting to `.review`.
    var fsrsStateRaw: Int?
    /// 0-based index into the library's learning/relearning steps. Only
    /// meaningful while `fsrsStateRaw` is learning/relearning; nil for old
    /// records (treated as 0).
    var fsrsStep: Int?

    private enum CodingKeys: String, CodingKey {
        case verseId, ease, intervalDays, due, reps, lapses, lastGrade
        case totalHints = "totalPeeks" // v1 key kept so existing libraries still decode
        case updatedAt
        case stability, difficulty, lastReview
        case fsrsStateRaw, fsrsStep
    }

    init(verseId: UUID, ease: Double, intervalDays: Int, due: Date, reps: Int, lapses: Int, totalHints: Int, lastGrade: Grade?, updatedAt: Date? = nil, stability: Double? = nil, difficulty: Double? = nil, lastReview: Date? = nil, fsrsStateRaw: Int? = nil, fsrsStep: Int? = nil) {
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
        self.lastReview = lastReview
        self.fsrsStateRaw = fsrsStateRaw
        self.fsrsStep = fsrsStep
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
        // Pre-lastReview records carry no explicit grade time — nil so elapsed
        // time falls back to updatedAt until the next explicit grade sets it.
        lastReview = try c.decodeIfPresent(Date.self, forKey: .lastReview)
        // Pre-persistence records carry no library state/step — nil so the
        // transient card falls back to `.review` / step 0 until the next grade.
        fsrsStateRaw = try c.decodeIfPresent(Int.self, forKey: .fsrsStateRaw)
        fsrsStep = try c.decodeIfPresent(Int.self, forKey: .fsrsStep)
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
        try c.encodeIfPresent(lastReview, forKey: .lastReview)
        try c.encodeIfPresent(fsrsStateRaw, forKey: .fsrsStateRaw)
        try c.encodeIfPresent(fsrsStep, forKey: .fsrsStep)
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
    /// when never reviewed (no stability yet). Delegates to the library's
    /// `getRetrievability`; `retention` is kept for signature compatibility
    /// (retrievability itself is retention-independent).
    func retrievability(at now: Date = Date(), retention: Double = FSRSCore.defaultRetention) -> Double? {
        _ = retention
        guard stability != nil else { return nil }
        return FSRSCore.makeScheduler().getRetrievability(card: transientLibraryCard(), now: now).number
    }

    /// Interval (days) each grade would schedule from this state, without
    /// mutating. Powers ReviewView button previews.
    func previewIntervals(retention: Double = FSRSCore.defaultRetention, now: Date = Date()) -> [(Grade, Int)] {
        Grade.allCases.map { grade in (grade, hypotheticalInterval(for: grade, retention: retention, now: now)) }
    }

    /// Transient library Card rebuilt from our stored fields on every call —
    /// the library is stateless, so this is the only handoff. Reviewed cards
    /// (stability + difficulty present) resume in their persisted library
    /// state (`fsrsStateRaw`, falling back to `.review` for records written
    /// before state persistence) at the persisted step index (`fsrsStep`,
    /// falling back to 0), with elapsed time counted from `lastReview`
    /// (falling back to `updatedAt` for records written before `lastReview`
    /// existed); never-reviewed and pre-FSRS records enter as `.new` so the
    /// library initializes S/D from scratch.
    private func transientLibraryCard() -> Card {
        if let s = stability, let d = difficulty {
            let state = fsrsStateRaw.flatMap(CardState.init(rawValue:)) ?? .review
            return Card(
                due: due,
                stability: s,
                difficulty: d,
                scheduledDays: Double(intervalDays),
                learningSteps: fsrsStep ?? 0,
                reps: reps,
                lapses: lapses,
                state: state,
                lastReview: lastReview ?? updatedAt
            )
        }
        return Card(due: due, state: .new, lastReview: nil)
    }

    /// One private hypothetical path shared by `previewIntervals` and
    /// `advanced` so previews can never drift from the applied grade. Runs
    /// the transient card through the library and takes the library card's
    /// due verbatim (textbook: minute precision while learning/relearning,
    /// day precision once graduated). `intervalDays` preserves the library's
    /// `scheduledDays` (rounded to nearest, floor 0, capped): intraday
    /// learning/relearning steps report `scheduledDays` 0, so an intraday
    /// due crossing midnight still yields 0 (displayed as "~10m") instead of
    /// becoming a one-day interval via calendar-day math.
    private struct HypotheticalOutcome {
        var intervalDays: Int
        var due: Date
        var stability: Double?
        var difficulty: Double?
        var fsrsStateRaw: Int?
        var fsrsStep: Int?
    }

    /// Library `scheduledDays` rounded to the nearest whole day, floored at 0
    /// and capped at `maxIntervalDays`. Intraday steps (`scheduledDays` 0)
    /// yield 0.
    private static func cappedIntervalDays(_ scheduledDays: Double) -> Int {
        min(FSRSCore.maxIntervalDays, max(0, Int(scheduledDays.rounded())))
    }

    private func hypotheticalOutcome(for grade: Grade, retention: Double, now: Date) -> HypotheticalOutcome {
        let scheduler = FSRSCore.makeScheduler(retention: retention)
        if let item = try? scheduler.next(card: transientLibraryCard(), now: now, grade: FSRSCore.rating(for: grade)) {
            let lib = item.card
            return HypotheticalOutcome(
                intervalDays: Self.cappedIntervalDays(lib.scheduledDays),
                due: lib.due,
                stability: lib.stability,
                difficulty: lib.difficulty,
                fsrsStateRaw: lib.state.rawValue,
                fsrsStep: lib.learningSteps
            )
        }
        // Defensive fallback — `next` only throws for `.manual`, which we never
        // pass, so this is unreachable in practice. Keep the current schedule
        // and memory state.
        return HypotheticalOutcome(
            intervalDays: min(FSRSCore.maxIntervalDays, max(0, intervalDays)),
            due: due,
            stability: stability,
            difficulty: difficulty,
            fsrsStateRaw: fsrsStateRaw,
            fsrsStep: fsrsStep
        )
    }

    /// Shared next-interval math for advanced() + previewIntervals so the
    /// preview buttons can never disagree with the applied grade.
    private func hypotheticalInterval(for grade: Grade, retention: Double, now: Date) -> Int {
        hypotheticalOutcome(for: grade, retention: retention, now: now).intervalDays
    }

    /// Explicit grade -> next state (FSRS). Typing mistakes never grade
    /// implicitly; they are recorded separately, already net of per-word
    /// accidental forgiveness.
    ///
    /// Textbook FSRS: Again routes through relearning steps (due back in
    /// ~10 minutes), reps stays, lapses += 1. The due comes from the library
    /// card in all cases.
    func advanced(with grade: Grade, mistakes: Int, retention: Double = FSRSCore.defaultRetention, now: Date = Date()) -> ReviewState {
        var r = self
        r.updatedAt = now
        r.lastReview = now
        r.totalHints += mistakes
        r.lastGrade = grade

        // Single shared path: the exact outcome previewIntervals showed.
        let outcome = hypotheticalOutcome(for: grade, retention: retention, now: now)
        // Memory state always comes from the library. reps/lapses keep the
        // pinned product semantics (Again: reps stays, lapses += 1 even for a
        // first-ever lapse, where the raw library card would leave lapses
        // untouched); these match the library's long-term counters for
        // review-state cards.
        r.stability = outcome.stability
        r.difficulty = outcome.difficulty
        // Persist the library's post-grade state + step index so the next
        // grade resumes intraday learning/relearning instead of resetting to
        // `.review` and graduating prematurely.
        r.fsrsStateRaw = outcome.fsrsStateRaw
        r.fsrsStep = outcome.fsrsStep
        if grade == .again {
            r.lapses += 1
            // No rep reset (FSRS has no reps concept); keep reps as-is.
        } else {
            r.reps += 1
        }
        r.intervalDays = outcome.intervalDays
        r.due = outcome.due
        return r
    }

    /// Legacy wrapper (SM-2-era signature) so existing callers keep compiling
    /// during migration. Schedules at default retention (0.9).
    func advanced(with grade: Grade, mistakes: Int, now: Date = Date()) -> ReviewState {
        advanced(with: grade, mistakes: mistakes, retention: FSRSCore.defaultRetention, now: now)
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

// MARK: - Persistence envelope (also the sync/export format, v1/v2/v3/v4)

/// Tombstone so deletes propagate: without this, merge-as-union would
/// resurrect a deleted verse on the next pull of an older snapshot.
struct DeletedEntry: Codable, Equatable {
    var verseId: UUID
    var deletedAt: Date
}

struct LibraryEnvelope: Codable {
    /// 1 = original (no updatedAt/tombstones), 2 = newer-wins fields,
    /// 3 = FSRS fields (stability/difficulty) + review history,
    /// 4 = library-backed scheduling (swift-fsrs) + ReviewState.lastReview +
    /// `undoneLogIDs` tombstones. Decoders accept any version; encoders 4.
    var version: Int
    var verses: [Verse]
    var reviews: [ReviewState]
    var deleted: [DeletedEntry]
    /// FSRS review history (v3+). Missing in older payloads -> [].
    var history: [ReviewLogEntry]
    /// Synced tombstones for undone history entries (v4+). Merge contract:
    /// union both sides' sets, exclude those IDs from history, and drop
    /// tombstone IDs absent from both histories (self-pruning). Missing in
    /// older payloads -> [].
    var undoneLogIDs: Set<UUID>

    init(version: Int = 4, verses: [Verse], reviews: [ReviewState], deleted: [DeletedEntry] = [], history: [ReviewLogEntry] = [], undoneLogIDs: Set<UUID> = []) {
        self.version = version
        self.verses = verses
        self.reviews = reviews
        self.deleted = deleted
        self.history = history
        self.undoneLogIDs = undoneLogIDs
    }

    private enum CodingKeys: String, CodingKey {
        case version, verses, reviews, deleted, history, undoneLogIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        verses = try c.decode([Verse].self, forKey: .verses)
        reviews = try c.decode([ReviewState].self, forKey: .reviews)
        deleted = try c.decodeIfPresent([DeletedEntry].self, forKey: .deleted) ?? []
        history = try c.decodeIfPresent([ReviewLogEntry].self, forKey: .history) ?? []
        undoneLogIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .undoneLogIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(verses, forKey: .verses)
        try c.encode(reviews, forKey: .reviews)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(history, forKey: .history)
        try c.encode(undoneLogIDs, forKey: .undoneLogIDs)
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
