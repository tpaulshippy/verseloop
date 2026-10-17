import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let deviceDidShake = Notification.Name("verseloop.shake")
}

final class ShakeVC: UIViewController {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
}

struct ShakeDetector: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ShakeVC { ShakeVC() }
    func updateUIViewController(_ uiViewController: ShakeVC, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var store: VerseStore

    var body: some View {
        TabView {
            LoopTab()
                .tabItem { Label("Today", systemImage: "repeat.circle.fill") }
            VersesTab()
                .tabItem { Label("Verses", systemImage: "books.vertical.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .task {
            await store.autoPullOnLaunch()
        }
    }
}

// MARK: - Loop (the daily pass: due-sorted, one thing at a time)

struct LoopTab: View {
    @EnvironmentObject var store: VerseStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            // Live 30s tick. The tick date is load-bearing: it is threaded
            // through every row/badge as `now`, so each tick produces NEW
            // view inputs and SwiftUI actually re-renders the countdowns.
            // (Discarding the date — `{ _ in }` + `Date()` at render time —
            // leaves value-identical rows the framework skips, freezing
            // "in X min" / DUE until something else redraws the list.)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                VStack(spacing: 12) {
                    header(now: now)
                    if store.loopQueue(at: now).isEmpty {
                        emptyState
                    } else {
                        List {
                            ForEach(store.loopQueue(at: now)) { verse in
                                let r = store.review(for: verse.id)
                                NavigationLink(value: verse) {
                                    VerseRow(verse: verse, review: r, now: now, showDetails: store.showSchedulerDetails)
                                }
                            }
                            .onDelete { delete(at: $0, now: now) }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("Today's Verses")
            .navigationDestination(for: Verse.self) { verse in
                ReviewView(
                    verse: verse,
                    onNext: { next in
                        // Replace the just-graded verse so Back never lands
                        // on a stale graded screen; stack stays one deep.
                        if !path.isEmpty { path.removeLast() }
                        path.append(next)
                    },
                    onDone: { path = NavigationPath() }
                )
                // New identity per verse: without this SwiftUI reuses the
                // same ReviewView state slot when Next swaps verse A for
                // verse B, leaking revealed words + mistakes into B.
                .id(verse.id)
            }
            // A tapped due-reminder jumps straight into that verse — warm
            // (onChange) and cold start (.task on first appear) alike.
            .onChange(of: store.pendingPracticeVerseId) { _, _ in openPendingReminder() }
            .task { openPendingReminder() }
        }
    }

    /// Opens the tapped-reminder verse for practice immediately.
    private func openPendingReminder() {
        guard let verse = store.takePendingPracticeVerse() else { return }
        path = NavigationPath()
        path.append(verse)
    }

    private func header(now: Date) -> some View {
        let due = store.dueCount(at: now)
        return HStack(spacing: 16) {
            StatBubble(title: "Due", value: "\(due)", color: due > 0 ? .orange : .green)
            StatBubble(title: "Total", value: "\(store.verses.count)", color: .blue)
            StatBubble(title: "Mastered", value: "\(store.masteredCount)", color: .purple)
            Spacer()
        }
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("All caught up.").font(.title2).bold()
            Text("Add a verse in the Verses tab — ESV text fills in automatically.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
        }.padding(.top, 40)
    }

    private func delete(at offsets: IndexSet, now: Date) {
        let q = store.loopQueue(at: now)
        for i in offsets { store.deleteVerse(q[i]) }
    }
}

struct StatBubble: View {
    var title: String; var value: String; var color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2).bold().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct VerseRow: View {
    var verse: Verse; var review: ReviewState; var now: Date; var showDetails: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verse.reference).font(.headline)
            HStack(spacing: 8) {
                DueBadge(review: review, now: now)
                Text(showDetails ? review.detailedSchedule : review.friendlySchedule).font(.caption2).foregroundStyle(.secondary)
                if verse.textSource != "esv" {
                    Text(verse.textSource).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }
}

struct DueBadge: View {
    var review: ReviewState; var now: Date
    var body: some View {
        if review.isDue(at: now) {
            Text("DUE").font(.caption2).bold().padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        } else {
            Text(dueText(review)).font(.caption2).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    /// Honest relative label. Never "in 0d": a retry minutes away says so.
    private func dueText(_ r: ReviewState) -> String {
        let mins = Int(r.due.timeIntervalSince(now) / 60)
        if mins < 1 { return "moments" }
        if mins < 60 { return "in \(mins) min" }
        let cal = Calendar.current
        if cal.isDateInTomorrow(r.due) { return "tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: r.due)).day ?? r.intervalDays
        if days < 1 { return "in \(mins / 60)h" }
        return "in \(days)d"
    }
}

// MARK: - Verses tab (library + add)

struct VersesTab: View {
    @EnvironmentObject var store: VerseStore
    @State private var showingAdd = false
    @State private var editingVerse: Verse?

    var body: some View {
        NavigationStack {
            // Same 30s live tick as the Loop tab (tick date threaded as
            // `now` so badges stay truthful here too — see LoopTab).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                List {
                    ForEach(store.verses) { verse in
                        let r = store.review(for: verse.id)
                        Button { editingVerse = verse } label: {
                            VerseRow(verse: verse, review: r, now: now, showDetails: store.showSchedulerDetails)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        for i in idx { store.deleteVerse(store.verses[i]) }
                    }
                }
            }
            .navigationTitle("Verses")
            .toolbar {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showingAdd) { AddVerseView() }
            .sheet(item: $editingVerse) { v in AddVerseView(verseToEdit: v) }
        }
    }
}

struct AddVerseView: View {
    @EnvironmentObject var store: VerseStore
    @Environment(\.dismiss) var dismiss
    var verseToEdit: Verse?
    @State private var reference: String
    @State private var text: String
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var fetchedESV = false

    init(verseToEdit: Verse? = nil) {
        self.verseToEdit = verseToEdit
        _reference = State(initialValue: verseToEdit?.reference ?? "")
        _text = State(initialValue: verseToEdit?.text ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reference") {
                    TextField("John 1:1", text: $reference)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    Button {
                        Task { await fetchESV() }
                    } label: {
                        HStack {
                            if isFetching { ProgressView() }
                            Text(isFetching ? "Fetching ESV…" : "Fetch ESV text")
                        }
                    }
                    .disabled(isFetching || reference.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let e = fetchError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("ESV text is fetched automatically (ranges like Psalm 23:1-6 work too).")
                }
                Section("Text \(fetchedESV ? "· ESV ✓" : "")") {
                    TextEditor(text: $text).frame(minHeight: 140)
                }
                Section {
                    Button(verseToEdit == nil ? "Save verse" : "Save changes") {
                        if let v = verseToEdit {
                            store.updateVerse(v, reference: reference, text: text, source: fetchedESV ? "esv" : v.textSource)
                        } else {
                            store.addVerse(reference: reference, text: text, source: fetchedESV ? "esv" : "manual")
                        }
                        dismiss()
                    }
                    .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if verseToEdit != nil {
                        Button("Delete verse", role: .destructive) {
                            if let v = verseToEdit { store.deleteVerse(v) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(verseToEdit == nil ? "Add verse" : "Edit verse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private func fetchESV() async {
        isFetching = true; fetchError = nil; fetchedESV = false
        do {
            let t = try await store.esvService().fetchPassage(reference)
            text = t; fetchedESV = true
        } catch {
            fetchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isFetching = false
    }
}

// MARK: - Settings (keys, sync, export)

struct SettingsView: View {
    @EnvironmentObject var store: VerseStore
    @State private var isImporting = false
    @State private var isPasting = false
    @State private var pastedJSON = ""
    @State private var exportURL: URL?
    @State private var isBusy = false
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync (end-to-end encrypted)") {
                    Toggle("Auto-sync after changes", isOn: $store.autoSyncEnabled)
                    Button { Task { isBusy = true; await store.push(); isBusy = false } } label: { Text("Synchronize Backup") }.disabled(isBusy)
                    if !store.syncMessage.isEmpty { Text(store.syncMessage).font(.caption).foregroundStyle(.secondary) }
                    if let d = store.lastSyncAt { Text("Last sync: \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Review reminders", isOn: $store.remindersEnabled)
                    if store.remindersEnabled {
                        Picker("Remind me", selection: $store.reminderMode) {
                            Text("When verses become due").tag(VerseStore.ReminderMode.immediate)
                            Text("Daily at a set time").tag(VerseStore.ReminderMode.daily)
                        }
                        if store.reminderMode == .daily {
                            DatePicker("Time", selection: $store.dailyReminderDate, displayedComponents: .hourAndMinute)
                        }
                    }
                    if !store.reminderStatus.isEmpty {
                        Text(store.reminderStatus).font(.caption).foregroundStyle(.secondary)
                        Button("Open Settings app") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("“When verses become due” notifies as each verse's retry window arrives — tap it to jump straight into that verse. “Daily” sends one reminder at your chosen time.")
                }
                .onChange(of: store.remindersEnabled) { _, on in
                    Task {
                        if on { _ = await store.ensureReminderPermission() }
                        await store.rescheduleReminders()
                    }
                }
                Section {
                    Stepper("Good up to \(Int((store.goodThreshold * 100).rounded()))% mistakes",
                            value: $store.goodThreshold, in: 0...0.5, step: 0.01)
                    Stepper("Hard up to \(Int((store.hardThreshold * 100).rounded()))% mistakes",
                            value: $store.hardThreshold, in: 0...0.5, step: 0.01)
                    Button("Reset suggestion bands") { store.resetSuggestionThresholds() }
                } header: {
                    Text("Grading suggestions")
                } footer: {
                    Text("After a typing pass, 0 mistakes suggests Easy; a mistake rate at or under Good suggests Good, at or under Hard suggests Hard, above that Again — net of forgiven mistakes.")
                }
                Section {
                    Toggle("Show scheduler details", isOn: $store.showSchedulerDetails)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Off shows stage + interval (Learning · every 3d). On shows SM-2 internals (E1.65 · ×4).")
                }
                Section("Export / Import (your data is yours)") {
                    Button("Prepare JSON export") {
                        do { exportURL = try store.exportURL() } catch { store.syncMessage = error.localizedDescription }
                    }
                    if let u = exportURL {
                        ShareLink(item: u, subject: Text("Verse Loop Daily export"), message: Text("Verse Loop Daily library export (JSON v1)")) {
                            Label("Share export file", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Import JSON…") { isImporting = true }
                    Button("Import pasted JSON…") { pastedJSON = ""; isPasting = true }
                }
                Section("About") {
                    Text("Verse Loop Daily · ESV-only memorization with real SM-2 spaced repetition, forgiving first-letter testing, and exportable sync.").font(.caption)
                    Text(ESVService.attribution).font(.caption).foregroundStyle(.secondary)
                    Text("Verses: \(store.verses.count) · Due: \(store.dueCount)").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Link(destination: VerseStore.privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised.fill")
                    }
                    .accessibilityIdentifier("privacy-policy-link")
                    Link(destination: VerseStore.supportURL) {
                        Label("Support & Help", systemImage: "questionmark.circle.fill")
                    }
                    Text("No account. No analytics. No ads. Verses stay on your device; the optional encrypted backup can't be read by the developer.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Privacy & Support")
                } footer: {
                    Text("Same policy as App Store Connect → Privacy Policy URL.")
                }
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        HStack {
                            if isDeleting { ProgressView() }
                            Text(isDeleting ? "Deleting…" : "Delete All My Data")
                        }
                    }
                    .disabled(isDeleting || (store.verses.isEmpty && store.reviews.isEmpty))
                    .accessibilityIdentifier("delete-all-data")
                    .confirmationDialog(
                        "Delete everything?",
                        isPresented: $showingDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Delete everything", role: .destructive) {
                            isDeleting = true
                            Task {
                                await store.deleteAllData()
                                isDeleting = false
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Removes all verses, reviews, and history on this device, deletes the encrypted cloud backup for this sync code, and rotates the code. This can't be undone — export first if you want a copy.")
                    }
                } header: {
                    Text("Delete My Data")
                } footer: {
                    Text("No account to delete — this is the full equivalent. Also documented at Support → Delete My Data.")
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    try store.importFrom(url: url)
                    store.syncMessage = "Imported ✓"
                } catch {
                    store.syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            .sheet(isPresented: $isPasting) {
                NavigationStack {
                    Form {
                        Section {
                            TextEditor(text: $pastedJSON)
                                .frame(minHeight: 220)
                                .font(.system(.callout, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } footer: {
                            Text("Paste a Verse Loop Daily JSON export (same format as the export file).")
                        }
                        Section {
                            Button("Import") {
                                do {
                                    guard let data = pastedJSON.data(using: .utf8), !data.isEmpty else { return }
                                    try store.importJSON(data)
                                    store.syncMessage = "Imported ✓"
                                    isPasting = false
                                } catch {
                                    store.syncMessage = "Import failed — not a Verse Loop Daily export."
                                }
                            }
                            .disabled(pastedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .navigationTitle("Import pasted JSON")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { isPasting = false } }
                }
            }
        }
    }
}
