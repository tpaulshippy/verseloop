import Foundation
import SwiftUI
import CryptoKit
import UserNotifications

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
    /// Tombstones so deletes propagate instead of resurrecting on pull.
    var deleted: [DeletedEntry] = []

    @Published var autoSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSyncEnabled, forKey: "verseloop.autosync")
            if !autoSyncEnabled { autoSyncTask?.cancel() }
        }
    }
    private var autoSyncTask: Task<Void, Never>?

    // Suggestion bands (mistake rate net of forgiven): 0 slips -> Easy,
    // rate <= goodThreshold -> Good, <= hardThreshold -> Hard, else Again.
    // Configurable in Settings; enforced good <= hard.
    @Published var goodThreshold: Double = 0.05 {
        didSet {
            // Guard every write: a set inside didSet re-triggers didSet,
            // so unconditional clamping would recurse until stack overflow.
            let clamped = min(max(goodThreshold, 0), 0.5)
            if clamped != goodThreshold { goodThreshold = clamped; return }
            if goodThreshold > hardThreshold { hardThreshold = goodThreshold }
            UserDefaults.standard.set(goodThreshold, forKey: "verseloop.goodThreshold")
        }
    }
    @Published var hardThreshold: Double = 0.15 {
        didSet {
            let clamped = min(max(hardThreshold, 0), 0.5)
            if clamped != hardThreshold { hardThreshold = clamped; return }
            if hardThreshold < goodThreshold { goodThreshold = hardThreshold }
            UserDefaults.standard.set(hardThreshold, forKey: "verseloop.hardThreshold")
        }
    }

    func resetSuggestionThresholds() {
        goodThreshold = Self.defaultGoodThreshold
        hardThreshold = Self.defaultHardThreshold
    }
    static let defaultGoodThreshold = 0.05
    static let defaultHardThreshold = 0.15

    // MARK: - Reminders (local notifications, no server involved)

    /// .immediate fires right when each verse's retry window arrives;
    /// .daily sends one reminder at dailyReminderDate.
    enum ReminderMode: String, CaseIterable, Codable {
        case immediate
        case daily

        var title: String {
            switch self {
            case .immediate: return "When due"
            case .daily: return "Daily"
            }
        }
    }

    @Published var remindersEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(remindersEnabled, forKey: "verseloop.remindersEnabled")
            refreshReminders()
        }
    }
    @Published var reminderMode: ReminderMode = .immediate {
        didSet {
            UserDefaults.standard.set(reminderMode.rawValue, forKey: "verseloop.reminderMode")
            refreshReminders()
        }
    }
    /// Time of day for .daily mode (date part ignored).
    @Published var dailyReminderDate: Date = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date() {
        didSet {
            UserDefaults.standard.set(dailyReminderDate, forKey: "verseloop.dailyReminderDate")
            refreshReminders()
        }
    }
    /// Non-empty when reminders are on but blocked (e.g. denied in Settings).
    @Published var reminderStatus: String = ""

    // Settings (UserDefaults so they survive reinstalls of dev builds).
    // The Worker URL is fixed (your own deployment); the ESV key lives
    // server-side only, so neither is user-visible anymore.
    static let workerBaseURL = "https://verseloop.pshippy-245.workers.dev"

    /// Public App Store URLs (served by the Worker, sources in appstore/).
    static let privacyPolicyURL = URL(string: "https://verseloop.pshippy-245.workers.dev/privacy")!
    static let supportURL = URL(string: "https://verseloop.pshippy-245.workers.dev/support")!
    static let dataDeletionURL = URL(string: "https://verseloop.pshippy-245.workers.dev/support#delete-my-data")!

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
        // UserDefaults.bool(forKey:) is false when unset — but auto-sync
        // should default ON. Track "has been set" explicitly.
        if UserDefaults.standard.object(forKey: "verseloop.autosync") == nil {
            self.autoSyncEnabled = true
            UserDefaults.standard.set(true, forKey: "verseloop.autosync")
        } else {
            self.autoSyncEnabled = UserDefaults.standard.bool(forKey: "verseloop.autosync")
        }
        if !load() { seedDemo() }
        let good = UserDefaults.standard.object(forKey: "verseloop.goodThreshold") as? Double
        let hard = UserDefaults.standard.object(forKey: "verseloop.hardThreshold") as? Double
        self.goodThreshold = good ?? Self.defaultGoodThreshold
        self.hardThreshold = hard ?? Self.defaultHardThreshold
        if self.hardThreshold < self.goodThreshold { self.hardThreshold = self.goodThreshold }
        self.remindersEnabled = UserDefaults.standard.bool(forKey: "verseloop.remindersEnabled")
        if let raw = UserDefaults.standard.string(forKey: "verseloop.reminderMode"),
           let m = ReminderMode(rawValue: raw) {
            self.reminderMode = m
        }
        if let t = UserDefaults.standard.object(forKey: "verseloop.dailyReminderDate") as? Date {
            self.dailyReminderDate = t
        }
        // Pending requests survive restarts, but dues shift — rebuild once.
        refreshReminders()
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
    /// The `at:` variant takes the TimelineView tick date so the queue
    /// re-partitions live as retry windows elapse (see LoopTab).
    var loopQueue: [Verse] { loopQueue(at: Date()) }

    func loopQueue(at now: Date) -> [Verse] {
        verses.sorted { a, b in
            let ra = reviews[a.id] ?? .fresh(verseId: a.id)
            let rb = reviews[b.id] ?? .fresh(verseId: b.id)
            let aOverdue = ra.due <= now
            let bOverdue = rb.due <= now
            if aOverdue != bOverdue { return aOverdue && !bOverdue }
            if ra.due != rb.due { return ra.due < rb.due }
            return a.addedAt < b.addedAt
        }
    }

    var dueCount: Int { dueCount(at: Date()) }

    func dueCount(at now: Date) -> Int {
        verses.filter { (reviews[$0.id] ?? .fresh(verseId: $0.id)).isDue(at: now) }.count
    }

    var masteredCount: Int {
        reviews.values.filter { $0.reps >= 5 && $0.intervalDays >= 21 }.count
    }

    func review(for verseId: UUID) -> ReviewState {
        reviews[verseId] ?? .fresh(verseId: verseId)
    }

    /// Next due verse after the given one, for ReviewView's Next button.
    /// Returns nil when nothing else is due (caller shows Done instead).
    func nextDueVerse(excluding excludedId: UUID) -> Verse? {
        loopQueue.first { $0.id != excludedId && (reviews[$0.id] ?? .fresh(verseId: $0.id)).isDue }
    }

    // MARK: - Mutations

    func addVerse(reference: String, text: String, source: String) {
        let cleanRef = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRef.isEmpty, !cleanText.isEmpty else { return }
        let now = Date()
        let v = Verse(reference: cleanRef, text: cleanText, textSource: source, addedAt: now, updatedAt: now)
        verses.append(v)
        reviews[v.id] = ReviewState(verseId: v.id, ease: 2.5, intervalDays: 0, due: now, reps: 0, lapses: 0, totalHints: 0, lastGrade: nil, updatedAt: now)
        save()
        refreshReminders()
        scheduleAutoSync()
    }

    func updateVerse(_ verse: Verse, reference: String, text: String, source: String) {
        let cleanRef = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRef.isEmpty, !cleanText.isEmpty else { return }
        guard let i = verses.firstIndex(where: { $0.id == verse.id }) else { return }
        let now = Date()
        verses[i] = Verse(id: verse.id, reference: cleanRef, text: cleanText, textSource: source, addedAt: verse.addedAt, updatedAt: now)
        save()
        scheduleAutoSync()
    }

    func deleteVerse(_ verse: Verse) {
        verses.removeAll { $0.id == verse.id }
        reviews.removeValue(forKey: verse.id)
        let now = Date()
        deleted.removeAll { $0.verseId == verse.id }
        deleted.append(DeletedEntry(verseId: verse.id, deletedAt: now))
        save()
        refreshReminders()
        scheduleAutoSync()
    }

    /// Explicit grade after a typing pass. `mistakes` is the mistake count
    /// AFTER per-word accidental forgiveness, so stray keystrokes never
    /// silently tank the ease factor.
    func grade(_ verseId: UUID, grade: Grade, mistakes: Int) {
        let current = review(for: verseId)
        gradeUndoStack.append(GradeUndo(verseId: verseId, previous: current, grade: grade))
        reviews[verseId] = current.advanced(with: grade, mistakes: mistakes, now: Date())
        undoToast = "Graded \(grade.title) · \(mistakes) mistake\(mistakes == 1 ? "" : "s") — Undo"
        save()
        refreshReminders()
        scheduleAutoSync()
    }

    func undoLastGrade() -> Bool {
        guard let last = gradeUndoStack.popLast() else { return false }
        var restored = last.previous
        restored.updatedAt = Date()
        reviews[last.verseId] = restored
        undoToast = nil
        save()
        refreshReminders()
        scheduleAutoSync()
        return true
    }

    func clearUndoToast() { undoToast = nil }

    // MARK: - Reminders scheduling

    /// Asks for notification permission; Settings shows reminderStatus when blocked.
    func ensureReminderPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await updateReminderStatus()
            return granted
        } catch {
            reminderStatus = "Couldn't ask for notification permission."
            return false
        }
    }

    func updateReminderStatus() async {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            reminderStatus = ""
        case .denied:
            reminderStatus = "Notifications are off for Verse Loop Daily — turn them on in the Settings app to get reminders."
        default:
            reminderStatus = ""
        }
    }

    /// Fire-and-forget wrapper for sync mutation paths.
    private func refreshReminders() {
        Task { await rescheduleReminders() }
    }

    /// Rebuilds pending reminders from current dues + settings. Called after
    /// every schedule-affecting change; idempotent and cheap (≤20 requests).
    func rescheduleReminders() async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix("verseloop.reminder") }
            .map(\.identifier)
        if !ours.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ours) }
        guard remindersEnabled else { reminderStatus = ""; return }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            reminderStatus = ""
        case .denied:
            reminderStatus = "Notifications are off for Verse Loop Daily — turn them on in the Settings app to get reminders."
            return
        default:
            return
        }
        switch reminderMode {
        case .immediate:
            // One request per upcoming due (already-due verses need no nudge).
            let now = Date()
            let upcoming = verses
                .sorted { review(for: $0.id).due < review(for: $1.id).due }
                .filter { review(for: $0.id).due > now }
                .prefix(20)
            for v in upcoming {
                let due = review(for: v.id).due
                let content = UNMutableNotificationContent()
                content.title = "Verse due"
                content.body = "\(v.reference) is ready to review."
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, due.timeIntervalSince(now)), repeats: false)
                try? await center.add(UNNotificationRequest(
                    identifier: "verseloop.reminder.due-\(v.id.uuidString)",
                    content: content, trigger: trigger))
            }
        case .daily:
            let content = UNMutableNotificationContent()
            content.title = "Time to review"
            let n = dueCount
            content.body = n > 0
                ? "\(n) verse\(n == 1 ? "" : "s") due — open Today to review."
                : "Open Today for your daily pass."
            let comps = Calendar.current.dateComponents([.hour, .minute], from: dailyReminderDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            try? await center.add(UNNotificationRequest(
                identifier: "verseloop.reminder.daily", content: content, trigger: trigger))
        }
    }

    // MARK: - Delete my data (App Store 5.1.1(i): revocation + deletion)

    /// Deletes everything this app holds:
    /// 1. remote encrypted backup for the current sync code (best effort),
    /// 2. local verses / reviews / tombstones + persisted JSON,
    /// 3. rotates the sync code so the old cloud bucket can never be
    ///    re-linked, and disables auto-sync side effects until new data arrives.
    /// There are no accounts: this is the full account-deletion equivalent.
    func deleteAllData() async {
        let oldCode = syncCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !oldCode.isEmpty {
            do {
                let base = Self.workerBaseURL.hasSuffix("/") ? String(Self.workerBaseURL.dropLast()) : Self.workerBaseURL
                if let url = URL(string: "\(base)/v1/sync/\(oldCode)") {
                    var req = URLRequest(url: url)
                    req.httpMethod = "DELETE"
                    req.timeoutInterval = 15
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
        }
        autoSyncTask?.cancel()
        verses = []
        reviews = [:]
        deleted = []
        gradeUndoStack = []
        undoToast = nil
        lastSyncAt = nil
        try? FileManager.default.removeItem(at: libraryURL)
        // Persist the empty library so a relaunch stays empty (no demo reseed).
        save()
        await rescheduleReminders()
        // Rotate the code so a stale server snapshot can never resurrect data.
        let fresh = Self.newSyncCode()
        syncCode = fresh
        UserDefaults.standard.set(fresh, forKey: "verseloop.synccode")
        syncMessage = "All data deleted ✓"
    }

    // MARK: - Persistence (local JSON, offline-first)

    private var libraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("verseloop.json")
    }

    func save() {
        let env = LibraryEnvelope(version: 2, verses: verses, reviews: Array(reviews.values), deleted: deleted)
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
        deleted = env.deleted
        return true
    }

    /// Public-domain KJV seeds so the simulator build is usable with zero
    /// network and zero copyrighted text. Real ESV verses are added via Fetch.
    private func seedDemo() {
        let now = Date()
        let seeds = [
            Verse(reference: "Psalm 23:1 (demo · KJV)", text: "The LORD is my shepherd; I shall not want.", textSource: "kjv-demo", addedAt: now, updatedAt: now),
            Verse(reference: "Proverbs 3:5 (demo · KJV)", text: "Trust in the LORD with all thine heart; and lean not unto thine own understanding.", textSource: "kjv-demo", addedAt: now, updatedAt: now),
        ]
        verses = seeds
        reviews = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, ReviewState(verseId: $0.id, ease: 2.5, intervalDays: 0, due: now, reps: 0, lapses: 0, totalHints: 0, lastGrade: nil, updatedAt: now)) })
        deleted = []
        save()
    }

    // MARK: - Export / Import (fixes "no way to get my data out")

    func exportURL() throws -> URL {
        let env = LibraryEnvelope(version: 2, verses: verses, reviews: Array(reviews.values), deleted: deleted)
        let data = try JSONEncoder().encode(env)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verseloop-export.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func importFrom(url: URL) throws {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        try importJSON(try Data(contentsOf: url))
    }

    /// Import from pasted text (Settings → Import from pasted JSON).
    /// Newer-wins per record (same rule as pull), so imports can't regress
    /// newer local grades either.
    func importJSON(_ data: Data) throws {
        let env = try JSONDecoder().decode(LibraryEnvelope.self, from: data)
        merge(env)
        save()
        refreshReminders()
        scheduleAutoSync()
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
            case .badURL: return "Sync service URL looks wrong."
            case .server(let s): return "Sync failed: \(s)"
            }
        }
    }

    // MARK: - Automatic sync (stale-safe)

    /// Debounced push after every local mutation (add / practice / delete /
    /// undo / import). Coalesces rapid grades into one network write.
    private func scheduleAutoSync() {
        guard autoSyncEnabled else { return }
        autoSyncTask?.cancel()
        autoSyncTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self.push()
        }
    }

    /// One pull on app launch so a second device picks up the latest
    /// snapshot without opening Settings. Stale snapshots can't regress
    /// local state — merge is newer-wins per record.
    func autoPullOnLaunch() async {
        guard autoSyncEnabled else { return }
        await pull()
    }

    private struct RemoteSnapshot {
        let envelope: LibraryEnvelope
    }

    /// GET the server snapshot and decrypt it. Returns nil on 404 (never
    /// pushed). Throws SyncError.server("wrong sync code…") when the
    /// ciphertext can't be opened with the current code — callers must NOT
    /// push in that case, or they'd overwrite someone else's snapshot.
    private func fetchRemote() async throws -> RemoteSnapshot? {
        let url = try syncEndpoint(path: "")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.server("bad response") }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw SyncError.server("HTTP \(http.statusCode)") }
        let code = syncCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw SyncError.noCode }
        // v2 (encrypted) first, v1 plaintext as fallback for old snapshots.
        if let enc = try? JSONDecoder().decode(EncryptedEnvelope.self, from: data),
           enc.version == 2, !enc.ciphertext.isEmpty {
            do {
                return RemoteSnapshot(envelope: try SyncCrypto.open(enc, code: code))
            } catch {
                throw SyncError.server("wrong sync code or corrupt snapshot")
            }
        }
        return RemoteSnapshot(envelope: try JSONDecoder().decode(LibraryEnvelope.self, from: data))
    }

    /// Read-modify-write: pull-merge first so a stale local push can never
    /// clobber newer server state, then upload the merged result.
    func push() async {
        do {
            if let remote = try await fetchRemote() {
                merge(remote.envelope)
                save()
            }
            let url = try syncEndpoint(path: "")
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15
            let inner = LibraryEnvelope(version: 2, verses: verses, reviews: Array(reviews.values), deleted: deleted)
            let code = syncCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { throw SyncError.noCode }
            req.httpBody = try JSONEncoder().encode(SyncCrypto.seal(inner, code: code))
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.server("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)") }
            lastSyncAt = Date()
            syncMessage = "Synced \(verses.count) verses ✓"
            await rescheduleReminders()
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func pull() async {
        do {
            guard let remote = try await fetchRemote() else {
                syncMessage = "No snapshot yet — push first"
                return
            }
            merge(remote.envelope)
            lastSyncAt = Date()
            syncMessage = "Pulled \(verses.count) verses ✓"
            save()
            await rescheduleReminders()
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Newer-wins per record + tombstones:
    /// - verses/reviews keep whichever side has the larger updatedAt (ties: local)
    /// - deletes propagate via tombstones; tombstoned ids are not resurrected
    ///   by older snapshots
    private func merge(_ env: LibraryEnvelope) {
        var tombById: [UUID: Date] = Dictionary(uniqueKeysWithValues: deleted.map { ($0.verseId, $0.deletedAt) })
        for d in env.deleted {
            if let cur = tombById[d.verseId] {
                if d.deletedAt > cur { tombById[d.verseId] = d.deletedAt }
            } else {
                tombById[d.verseId] = d.deletedAt
            }
        }
        var vById = Dictionary(uniqueKeysWithValues: verses.map { ($0.id, $0) })
        for v in env.verses {
            if let local = vById[v.id] {
                if v.updatedAt > local.updatedAt { vById[v.id] = v }
            } else {
                if let t = tombById[v.id], v.updatedAt <= t { continue }
                vById[v.id] = v
            }
        }
        for (id, t) in tombById {
            if let v = vById[id], v.updatedAt <= t { vById.removeValue(forKey: id) }
        }
        verses = Array(vById.values).sorted { $0.addedAt < $1.addedAt }
        for r in env.reviews {
            if let t = tombById[r.verseId], r.updatedAt <= t { continue }
            if let local = reviews[r.verseId] {
                if r.updatedAt > local.updatedAt { reviews[r.verseId] = r }
            } else {
                reviews[r.verseId] = r
            }
        }
        for (id, t) in tombById {
            if let local = reviews[id], local.updatedAt <= t { reviews.removeValue(forKey: id) }
        }
        // Prune tombstones resurrected by a newer verse; keep the rest so
        // very old snapshots can't resurrect deletes.
        var kept: [DeletedEntry] = []
        for (id, t) in tombById {
            if let v = vById[id] {
                if v.updatedAt <= t { kept.append(DeletedEntry(verseId: id, deletedAt: t)) }
            } else {
                kept.append(DeletedEntry(verseId: id, deletedAt: t))
            }
        }
        deleted = kept
    }

    func esvService() -> ESVService {
        ESVService(workerBaseURL: Self.workerBaseURL)
    }
}
