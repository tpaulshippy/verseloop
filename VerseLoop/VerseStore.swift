import Foundation
import SwiftUI

/// Single source of truth: verses + SM-2 reviews, JSON-persisted, exportable,
/// and syncable through the free Cloudflare Worker (no Apple entitlements needed).
@MainActor
final class VerseStore: ObservableObject {
    @Published var verses: [Verse] = []
    @Published var reviews: [UUID: ReviewState] = [:]
    @Published var lastSyncAt: Date?
    @Published var syncMessage: String = ""

    // Settings (UserDefaults so they survive reinstalls of dev builds)
    @Published var workerBaseURL: String {
        didSet { UserDefaults.standard.set(workerBaseURL, forKey: "verseloop.worker") }
    }
    @Published var syncCode: String {
        didSet { UserDefaults.standard.set(syncCode, forKey: "verseloop.synccode") }
    }
    @Published var esvAPIKey: String {
        didSet { UserDefaults.standard.set(esvAPIKey, forKey: "verseloop.esvkey") }
    }

    // Undo support for accidental grades
    struct GradeUndo {
        let verseId: UUID
        let previous: ReviewState
        let grade: Grade
    }
    private var gradeUndoStack: [GradeUndo] = []
    @Published var undoToast: String? // "Graded Good — Undo" with auto-dismiss handled by view

    init() {
        self.workerBaseURL = UserDefaults.standard.string(forKey: "verseloop.worker") ?? ""
        self.syncCode = UserDefaults.standard.string(forKey: "verseloop.synccode") ?? ""
        self.esvAPIKey = UserDefaults.standard.string(forKey: "verseloop.esvkey") ?? ""
        if !load() { seedDemo() }
    }

    // MARK: - Queue (the "Loop": one due-sorted pass per day)

    /// Due verses first (oldest due at top), then not-yet-due remainder.
    var loopQueue: [Verse] {
        verses.sorted { a, b in
            let ra = reviews[a.id] ?? .fresh(verseId: a.id)
            let rb = reviews[b.id] ?? .fresh(verseId: b.id)
            let aOverdue = ra.due <= Date()
            let bOverdue = rb.due <= Date()
            if aOverdue != bOverdue { return aOverdue && !bOverdue }
            if ra.due != rb.due { return ra.due < rb.due }
            return a.addedAt < b.addedAt
        }
    }

    var dueCount: Int {
        verses.filter { (reviews[$0.id] ?? .fresh(verseId: $0.id)).isDue }.count
    }

    var masteredCount: Int {
        reviews.values.filter { $0.reps >= 5 && $0.intervalDays >= 21 }.count
    }

    func review(for verseId: UUID) -> ReviewState {
        reviews[verseId] ?? .fresh(verseId: verseId)
    }

    // MARK: - Mutations

    func addVerse(reference: String, text: String, source: String) {
        let cleanRef = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRef.isEmpty, !cleanText.isEmpty else { return }
        let v = Verse(reference: cleanRef, text: cleanText, textSource: source)
        verses.append(v)
        reviews[v.id] = .fresh(verseId: v.id)
        save()
    }

    func deleteVerse(_ verse: Verse) {
        verses.removeAll { $0.id == verse.id }
        reviews.removeValue(forKey: verse.id)
        save()
    }

    /// Explicit grade. `accidental=true` zeroes peek influence and is logged
    /// with the grade so a stray tap never silently tanks the ease factor.
    func grade(_ verseId: UUID, grade: Grade, peeks: Int, accidental: Bool) {
        let current = review(for: verseId)
        gradeUndoStack.append(GradeUndo(verseId: verseId, previous: current, grade: grade))
        let effectivePeeks = accidental ? 0 : peeks
        reviews[verseId] = current.advanced(with: grade, peeks: effectivePeeks)
        undoToast = accidental
            ? "Graded \(grade.title) · taps marked accidental — Undo"
            : "Graded \(grade.title) — Undo"
        save()
    }

    func undoLastGrade() -> Bool {
        guard let last = gradeUndoStack.popLast() else { return false }
        reviews[last.verseId] = last.previous
        undoToast = nil
        save()
        return true
    }

    func clearUndoToast() { undoToast = nil }

    // MARK: - Persistence (local JSON, offline-first)

    private var libraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("verseloop.json")
    }

    func save() {
        let env = LibraryEnvelope(version: 1, verses: verses, reviews: Array(reviews.values))
        do {
            let data = try JSONEncoder().encode(env)
            try data.write(to: libraryURL, options: .atomic)
        } catch {
            syncMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: libraryURL),
              let env = try? JSONDecoder().decode(LibraryEnvelope.self, from: data) else { return false }
        verses = env.verses
        reviews = Dictionary(uniqueKeysWithValues: env.reviews.map { ($0.verseId, $0) })
        return true
    }

    /// Public-domain KJV seeds so the simulator build is usable with zero
    /// network and zero copyrighted text. Real ESV verses are added via Fetch.
    private func seedDemo() {
        let seeds = [
            Verse(reference: "Psalm 23:1 (demo · KJV)", text: "The LORD is my shepherd; I shall not want.", textSource: "kjv-demo"),
            Verse(reference: "Proverbs 3:5 (demo · KJV)", text: "Trust in the LORD with all thine heart; and lean not unto thine own understanding.", textSource: "kjv-demo"),
        ]
        verses = seeds
        reviews = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, ReviewState.fresh(verseId: $0.id)) })
        save()
    }

    // MARK: - Export / Import (fixes "no way to get my data out")

    func exportURL() throws -> URL {
        let env = LibraryEnvelope(version: 1, verses: verses, reviews: Array(reviews.values))
        let data = try JSONEncoder().encode(env)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verseloop-export.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func importFrom(url: URL) throws {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        let data = try Data(contentsOf: url)
        let env = try JSONDecoder().decode(LibraryEnvelope.self, from: data)
        // Merge by id: imported wins.
        var vById = Dictionary(uniqueKeysWithValues: verses.map { ($0.id, $0) })
        for v in env.verses { vById[v.id] = v }
        verses = Array(vById.values).sorted { $0.addedAt < $1.addedAt }
        for r in env.reviews { reviews[r.verseId] = r }
        save()
    }

    enum ImportError: LocalizedError {
        case access
        var errorDescription: String? { "Couldn't read that file." }
    }

    // MARK: - Worker sync (free tier; sync code is the only credential)

    struct SyncPayload: Codable {
        var version: Int
        var verses: [Verse]
        var reviews: [ReviewState]
        var updatedAt: Date
    }

    private func syncEndpoint(path: String) throws -> URL {
        let base = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = syncCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw SyncError.noWorker }
        guard !code.isEmpty else { throw SyncError.noCode }
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(b)/v1/sync/\(code)\(path)") else { throw SyncError.badURL }
        return url
    }

    enum SyncError: LocalizedError {
        case noWorker, noCode, badURL, server(String)
        var errorDescription: String? {
            switch self {
            case .noWorker: return "Set a Worker URL in Settings first (see worker/README)."
            case .noCode: return "Pick a sync code in Settings (same code on both devices)."
            case .badURL: return "Worker URL looks wrong."
            case .server(let s): return "Sync failed: \(s)"
            }
        }
    }

    func push() async {
        do {
            let url = try syncEndpoint(path: "")
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15
            let payload = SyncPayload(version: 1, verses: verses, reviews: Array(reviews.values), updatedAt: Date())
            req.httpBody = try JSONEncoder().encode(payload)
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.server("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)") }
            lastSyncAt = Date()
            syncMessage = "Pushed \(verses.count) verses ✓"
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func pull() async {
        do {
            let url = try syncEndpoint(path: "")
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.server("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)") }
            let payload = try JSONDecoder().decode(SyncPayload.self, from: data)
            var vById = Dictionary(uniqueKeysWithValues: verses.map { ($0.id, $0) })
            for v in payload.verses { vById[v.id] = v }
            verses = Array(vById.values).sorted { $0.addedAt < $1.addedAt }
            for r in payload.reviews { reviews[r.verseId] = r }
            lastSyncAt = Date()
            syncMessage = "Pulled \(payload.verses.count) verses ✓"
            save()
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func esvService() -> ESVService {
        ESVService(workerBaseURL: workerBaseURL, apiKey: esvAPIKey)
    }
}
