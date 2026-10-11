import Foundation
import SwiftUI
import CryptoKit

/// Key + seal/open helpers. Pure functions so the crypto stays reviewable
/// in one place and out of the UI/store logic.
enum SyncCrypto {
    private static let salt = Data("verseloop-sync-v1".utf8)
    private static let info = Data("envelope".utf8)

    static func key(fromCode code: String) -> SymmetricKey {
        let material = SymmetricKey(data: Data(code.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt, info: info, outputByteCount: 32)
    }

    static func seal(_ envelope: LibraryEnvelope, code: String) throws -> EncryptedEnvelope {
        let plain = try JSONEncoder().encode(envelope)
        let box = try AES.GCM.seal(plain, using: key(fromCode: code))
        return EncryptedEnvelope(version: 2, ciphertext: box.combined!.base64EncodedString(), updatedAt: Date())
    }

    static func open(_ env: EncryptedEnvelope, code: String) throws -> LibraryEnvelope {
        guard let combined = Data(base64Encoded: env.ciphertext) else { throw CryptoError.encoding }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: key(fromCode: code))
        return try JSONDecoder().decode(LibraryEnvelope.self, from: plain)
    }

    enum CryptoError: LocalizedError {
        case encoding
        var errorDescription: String? { "Couldn't decode the encrypted snapshot." }
    }
}

/// Single source of truth: verses + SM-2 reviews, JSON-persisted, exportable,
/// and syncable through the free Cloudflare Worker (no Apple entitlements needed).
@MainActor
final class VerseStore: ObservableObject {
    @Published var verses: [Verse] = []
    @Published var reviews: [UUID: ReviewState] = [:]
    @Published var lastSyncAt: Date?
    @Published var syncMessage: String = ""

    // Settings (UserDefaults so they survive reinstalls of dev builds).
    // The Worker URL is fixed (your own deployment); the ESV key lives
    // server-side only, so neither is user-visible anymore.
    static let workerBaseURL = "https://verseloop.pshippy-245.workers.dev"

    @Published var syncCode: String {
        didSet { UserDefaults.standard.set(syncCode, forKey: "verseloop.synccode") }
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
        let storedCode = UserDefaults.standard.string(forKey: "verseloop.synccode") ?? ""
        let code = storedCode.isEmpty ? Self.newSyncCode() : storedCode
        self.syncCode = code
        if storedCode.isEmpty { UserDefaults.standard.set(code, forKey: "verseloop.synccode") }
        if !load() { seedDemo() }
    }

    /// Random 128-bit code, grouped for transcription. Generated once;
    /// the same code on both devices links them. It doubles as the
    /// encryption password — treat it like one.
    static func newSyncCode() -> String {
        let hex = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        var out = ""
        for (i, ch) in hex.enumerated() {
            if i > 0 && i % 4 == 0 { out += "-" }
            out.append(ch)
        }
        return out
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

    /// Explicit grade after a typing pass. `mistakes` is the mistake count
    /// AFTER per-word accidental forgiveness, so stray keystrokes never
    /// silently tank the ease factor.
    func grade(_ verseId: UUID, grade: Grade, mistakes: Int) {
        let current = review(for: verseId)
        gradeUndoStack.append(GradeUndo(verseId: verseId, previous: current, grade: grade))
        reviews[verseId] = current.advanced(with: grade, mistakes: mistakes)
        undoToast = "Graded \(grade.title) · \(mistakes) mistake\(mistakes == 1 ? "" : "s") — Undo"
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

    private func syncEndpoint(path: String) throws -> URL {
        let base = Self.workerBaseURL
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
            case .noWorker: return "Sync is unavailable in this build."
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
            let inner = LibraryEnvelope(version: 1, verses: verses, reviews: Array(reviews.values))
            let code = syncCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { throw SyncError.noCode }
            req.httpBody = try JSONEncoder().encode(SyncCrypto.seal(inner, code: code))
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.server("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)") }
            lastSyncAt = Date()
            syncMessage = "Pushed \(verses.count) verses, encrypted ✓"
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
            let code = syncCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { throw SyncError.noCode }
            // v2 (encrypted) first, v1 plaintext as fallback for old snapshots.
            if let enc = try? JSONDecoder().decode(EncryptedEnvelope.self, from: data),
               enc.version == 2, !enc.ciphertext.isEmpty {
                do {
                    merge(try SyncCrypto.open(enc, code: code))
                } catch {
                    throw SyncError.server("wrong sync code or corrupt snapshot")
                }
            } else {
                let env = try JSONDecoder().decode(LibraryEnvelope.self, from: data)
                merge(env)
            }
            lastSyncAt = Date()
            syncMessage = "Pulled \(verses.count) verses ✓"
            save()
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func merge(_ env: LibraryEnvelope) {
        var vById = Dictionary(uniqueKeysWithValues: verses.map { ($0.id, $0) })
        for v in env.verses { vById[v.id] = v }
        verses = Array(vById.values).sorted { $0.addedAt < $1.addedAt }
        for r in env.reviews { reviews[r.verseId] = r }
    }

    func esvService() -> ESVService {
        ESVService(workerBaseURL: Self.workerBaseURL)
    }
}
