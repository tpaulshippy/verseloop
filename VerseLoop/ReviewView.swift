import SwiftUI

/// First-letter tester with forgiving taps:
/// - tap a word to peek (marked, not punished)
/// - Oops button / shake undoes the last tap
/// - grade is ALWAYS explicit (Again/Hard/Good/Easy) -> true SM-2
/// - "taps were accidental" zeroes peek influence on that grade
/// - every grade has an 8s Undo
struct ReviewView: View {
    @EnvironmentObject var store: VerseStore
    var verse: Verse

    @State private var peeked: Set<Int> = []
    @State private var tapHistory: [TapEvent] = []
    @State private var revealAll = false
    @State private var accidental = false
    @State private var graded: Grade?
    @State private var undoDeadline: Date?
    @Environment(\.dismiss) var dismiss

    enum TapEvent: Equatable {
        case peek(Int)
        case revealAll(Set<Int>)
        case hideAll(Set<Int>)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                chips
                controls
                if graded == nil {
                    gradeBlock
                } else {
                    gradedBlock
                }
            }
            .padding()
        }
        .navigationTitle(verse.reference)
        .navigationBarTitleDisplayMode(.inline)
        .background(ShakeDetector().frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            undoLastTap()
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DueBadge(review: store.review(for: verse.id))
                Text("\(verse.words.count) words").font(.caption).foregroundStyle(.secondary)
                Text("· \(peeked.count) peeked").font(.caption).foregroundStyle(peeked.isEmpty ? Color.secondary : Color.orange)
                Spacer()
            }
            Text("Say it aloud from first letters, then peek to check. Taps never fail you — only your grade moves the schedule.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: chips

    private var chips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
            ForEach(Array(verse.words.enumerated()), id: \.offset) { i, word in
                let shown = revealAll || peeked.contains(i)
                Button {
                    togglePeek(i)
                } label: {
                    Text(shown ? word : verse.hints[i])
                        .font(shown ? .body : .system(.title3, design: .rounded).bold())
                        .monospaced(shown ? false : true)
                        .lineLimit(shown ? 3 : 1)
                        .minimumScaleFactor(0.7)
                        .frame(minWidth: 56, minHeight: 44)
                        .padding(.horizontal, 6)
                        .background(shown ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(shown ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shown ? word : "Hidden word starting with \(verse.hints[i])")
            }
        }
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button(revealAll ? "Hide all" : "Reveal all") {
                if revealAll {
                    tapHistory.append(.hideAll(peeked))
                    peeked = []
                } else {
                    tapHistory.append(.revealAll(peeked))
                    peeked = Set(verse.words.indices)
                }
                revealAll.toggle()
            }
            .buttonStyle(.bordered)

            Button {
                undoLastTap()
            } label: {
                Label("Oops · undo tap", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(tapHistory.isEmpty)
            .help("Undoes your last tap — accidental taps cost nothing. Shake also undoes.")
        }
    }

    // MARK: grading

    private var gradeBlock: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $accidental) {
                VStack(alignment: .leading) {
                    Text("My taps were accidental").font(.subheadline)
                    Text("Ignores peeks for this grade").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Text("How well did you recall it?").font(.headline).frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Grade.allCases, id: \.self) { g in
                    Button {
                        grade(g)
                    } label: {
                        Label(g.title, systemImage: g.systemImage)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint(for: g))
                }
            }
            Text("This grade — not your taps — sets the next review. That's the whole fix vs. auto-penalty apps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var gradedBlock: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Graded \(graded?.title ?? "") — next: \(nextDueText)").font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.undoToast != nil {
                Button {
                    _ = store.undoLastGrade()
                    graded = nil
                } label: {
                    Label("Undo grade (8s)", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
            }
            Button("Next →") { dismiss() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .task {
            // 8-second undo window
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            store.clearUndoToast()
        }
    }

    private var nextDueText: String {
        let r = store.review(for: verse.id)
        if r.intervalDays <= 0 { return "~10 min" }
        return r.due.formatted(date: .abbreviated, time: .omitted)
    }

    private func tint(for g: Grade) -> Color {
        switch g {
        case .again: return .red
        case .hard: return .orange
        case .good: return .blue
        case .easy: return .green
        }
    }

    // MARK: actions

    private func togglePeek(_ i: Int) {
        if peeked.contains(i) { peeked.remove(i) } else { peeked.insert(i) }
        tapHistory.append(.peek(i))
        revealAll = peeked.count == verse.words.count
    }

    private func undoLastTap() {
        guard let last = tapHistory.popLast() else { return }
        switch last {
        case .peek(let i):
            // toggle back
            if peeked.contains(i) { peeked.remove(i) } else { peeked.insert(i) }
        case .revealAll(let prev), .hideAll(let prev):
            peeked = prev
        }
        revealAll = peeked.count == verse.words.count
    }

    private func grade(_ g: Grade) {
        store.grade(verse.id, grade: g, peeks: accidental ? 0 : peeked.count, accidental: accidental)
        graded = g
    }
}
