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
                .tabItem { Label("Loop", systemImage: "repeat.circle.fill") }
            VersesTab()
                .tabItem { Label("Verses", systemImage: "books.vertical.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Loop (the daily pass: due-sorted, one thing at a time)

struct LoopTab: View {
    @EnvironmentObject var store: VerseStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                header
                if store.loopQueue.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.loopQueue) { verse in
                            let r = store.review(for: verse.id)
                            NavigationLink {
                                ReviewView(verse: verse)
                            } label: {
                                VerseRow(verse: verse, review: r)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Today's Loop")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            StatBubble(title: "Due", value: "\(store.dueCount)", color: store.dueCount > 0 ? .orange : .green)
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
            Text("Add a verse in the Verses tab — ESV fetches from Settings key or Worker.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
        }.padding(.top, 40)
    }

    private func delete(at offsets: IndexSet) {
        let q = store.loopQueue
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
    var verse: Verse; var review: ReviewState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verse.reference).font(.headline)
            HStack(spacing: 8) {
                DueBadge(review: review)
                Text("E\(String(format: "%.2f", review.ease)) · ×\(review.reps)").font(.caption2).foregroundStyle(.secondary)
                if verse.textSource != "esv" {
                    Text(verse.textSource).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }
}

struct DueBadge: View {
    var review: ReviewState
    var body: some View {
        if review.isDue {
            Text("DUE").font(.caption2).bold().padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        } else {
            Text("in \(review.intervalDays)d").font(.caption2).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Verses tab (library + add)

struct VersesTab: View {
    @EnvironmentObject var store: VerseStore
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.verses) { verse in
                    let r = store.review(for: verse.id)
                    NavigationLink { ReviewView(verse: verse) } label: {
                        VerseRow(verse: verse, review: r)
                    }
                }
                .onDelete { idx in
                    for i in idx { store.deleteVerse(store.verses[i]) }
                }
            }
            .navigationTitle("Verses")
            .toolbar {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showingAdd) { AddVerseView() }
        }
    }
}

struct AddVerseView: View {
    @EnvironmentObject var store: VerseStore
    @Environment(\.dismiss) var dismiss
    @State private var reference = ""
    @State private var text = ""
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var fetchedESV = false

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
                    Text("ESV comes from api.esv.org (your key) or your Worker proxy. Get a free key at api.esv.org.")
                }
                Section("Text \(fetchedESV ? "· ESV ✓" : "")") {
                    TextEditor(text: $text).frame(minHeight: 140)
                }
                Section {
                    Button("Save verse") {
                        store.addVerse(reference: reference, text: text, source: fetchedESV ? "esv" : "manual")
                        dismiss()
                    }
                    .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add verse")
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync (end-to-end encrypted)") {
                    HStack {
                        Button { Task { isBusy = true; await store.push(); isBusy = false } } label: { Text("Push") }.disabled(isBusy)
                        Button { Task { isBusy = true; await store.pull(); isBusy = false } } label: { Text("Pull") }.disabled(isBusy)
                    }
                    if !store.syncMessage.isEmpty { Text(store.syncMessage).font(.caption).foregroundStyle(.secondary) }
                    if let d = store.lastSyncAt { Text("Last sync: \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Export / Import (your data is yours)") {
                    Button("Prepare JSON export") {
                        do { exportURL = try store.exportURL() } catch { store.syncMessage = error.localizedDescription }
                    }
                    if let u = exportURL {
                        ShareLink(item: u, subject: Text("VerseLoop export"), message: Text("VerseLoop library export (JSON v1)")) {
                            Label("Share export file", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Import JSON…") { isImporting = true }
                    Button("Import pasted JSON…") { pastedJSON = ""; isPasting = true }
                }
                Section("About") {
                    Text("VerseLoop · ESV-only memorization with real SM-2 spaced repetition, forgiving first-letter testing, and exportable sync.").font(.caption)
                    Text(ESVService.attribution).font(.caption).foregroundStyle(.secondary)
                    Text("Verses: \(store.verses.count) · Due: \(store.dueCount)").font(.caption).foregroundStyle(.secondary)
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
                            Text("Paste a VerseLoop JSON export (same format as the export file).")
                        }
                        Section {
                            Button("Import") {
                                do {
                                    guard let data = pastedJSON.data(using: .utf8), !data.isEmpty else { return }
                                    try store.importJSON(data)
                                    store.syncMessage = "Imported ✓"
                                    isPasting = false
                                } catch {
                                    store.syncMessage = "Import failed — not a VerseLoop export."
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
