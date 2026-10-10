import SwiftUI
import UIKit
import AudioToolbox

/// Flowing-text wrapper so revealed words read like a paragraph.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                x = 0; y += rowH + verticalSpacing; rowH = 0
            }
            rowH = max(rowH, s.height)
            x += s.width + horizontalSpacing
        }
        return CGSize(width: maxWidth.isInfinite ? x : maxWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX; y += rowH + verticalSpacing; rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            rowH = max(rowH, s.height)
            x += s.width + horizontalSpacing
        }
    }
}

/// Type-the-first-letter tester (matches the Versify "Type" flow):
/// - words reveal one at a time as you type each first letter
/// - right letter -> word appears, move on
/// - wrong letter -> vibrate, word appears red as a mistake, move on
/// - every mistake carries its own "accidental?" forgiveness toggle
/// - mistake count shown instead of a progress bar
/// - grade is ALWAYS explicit (Again/Hard/Good/Easy) -> true SM-2
/// - every grade has an 8s Undo
struct ReviewView: View {
    @EnvironmentObject var store: VerseStore
    var verse: Verse

    @State private var idx = 0
    @State private var revealed: Set<Int> = []
    @State private var mistakes: Set<Int> = []
    @State private var forgiven: Set<Int> = []
    @State private var entry = ""
    @FocusState private var entryFocused: Bool
    @State private var graded: Grade?
    @Environment(\.dismiss) var dismiss

    private var words: [String] { verse.words }
    private var done: Bool { idx >= words.count }
    private var mistakeCount: Int { mistakes.subtracting(forgiven).count }
    private var mistakeText: String { mistakeCount == 1 ? "1 mistake" : "\(mistakeCount) mistakes" }
    private var suggested: String {
        if mistakeCount == 0 { return "Easy" }
        if mistakeCount <= 2 { return "Good" }
        return "Hard"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                passage
                if !done {
                    inputRow
                    controls
                }
                if graded == nil {
                    if done { gradeBlock }
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
            forgiveLatestMistake()
        }
        .onAppear { entryFocused = true }
    }

    // MARK: header — mistake count, no progress bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DueBadge(review: store.review(for: verse.id))
                Text(done ? "\(words.count) of \(words.count)" : "word \(min(idx + 1, words.count)) of \(words.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("· \(mistakeText)")
                    .font(.caption).bold(mistakeCount > 0)
                    .foregroundStyle(mistakeCount > 0 ? Color.red : Color.secondary)
                Spacer()
            }
            Text("Type the first letter of each word. Wrong letter buzzes and marks a mistake — tap any red word to forgive a slip.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: passage — revealed words only, mistakes in red

    private var passage: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                if revealed.contains(i) {
                    let isMistake = mistakes.contains(i) && !forgiven.contains(i)
                    let isForgiven = mistakes.contains(i) && forgiven.contains(i)
                    Button {
                        if mistakes.contains(i) { toggleForgiven(i) }
                    } label: {
                        VStack(spacing: 0) {
                            Text(word)
                                .font(.title3)
                                .foregroundStyle(isMistake ? Color.red : Color.primary)
                            if isMistake {
                                Text("accidental?").font(.caption2).foregroundStyle(.secondary)
                            } else if isForgiven {
                                Text("accidental ✓").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!mistakes.contains(i))
                    .accessibilityLabel(isMistake ? "Mark accidental: \(word)" : (isForgiven ? "Accidental, tap to unmark: \(word)" : word))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }

    // MARK: input

    private var inputRow: some View {
        HStack(spacing: 12) {
            TextField("first letter…", text: $entry)
                .accessibilityIdentifier("first-letter-input")
                .font(.system(.title2, design: .rounded).bold())
                .multilineTextAlignment(.center)
                .frame(width: 120)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($entryFocused)
                .onChange(of: entry) { _, new in processInput(new) }
                .onSubmit { entry = "" }
            VStack(alignment: .leading, spacing: 2) {
                Text("Type the first letter").font(.subheadline)
                Text("of word \(min(idx + 1, words.count))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Show word") {
                // A shown word is a miss — forgivable like any other mistake.
                mistakes.insert(idx)
                revealed.insert(idx)
                advance()
            }
            .buttonStyle(.bordered)
            Button("Restart") { reset() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: grading

    private var gradeBlock: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: mistakeCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(mistakeCount == 0 ? .green : .orange)
                Text("\(words.count) words · \(mistakeText)\(forgiven.isEmpty ? "" : " (\(forgiven.count) forgiven)")")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Suggested: \(suggested) — but your grade decides, as always.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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

    // MARK: typing engine

    private func processInput(_ new: String) {
        guard !new.isEmpty, !done else {
            if new.isEmpty { return }
            entry = ""
            return
        }
        for ch in new where ch.isLetter {
            if done { break }
            check(letter: ch)
        }
        entry = ""
    }

    private func check(letter: Character) {
        let want = verse.hints[idx].lowercased()
        if String(letter).lowercased() == want {
            revealed.insert(idx)
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred()
            advance()
        } else {
            mistakes.insert(idx)
            revealed.insert(idx)
            buzzError()
            advance()
        }
    }

    private func advance() {
        idx += 1
        if done { entryFocused = false }
    }

    private func buzzError() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func toggleForgiven(_ i: Int) {
        if forgiven.contains(i) { forgiven.remove(i) } else { forgiven.insert(i) }
        entryFocused = true
    }

    private func forgiveLatestMistake() {
        // Shake forgives the most recent unforgiven mistake.
        if let last = mistakes.subtracting(forgiven).sorted().last {
            forgiven.insert(last)
        }
    }

    private func reset() {
        idx = 0
        revealed = []
        mistakes = []
        forgiven = []
        entry = ""
        graded = nil
        entryFocused = true
    }

    private func grade(_ g: Grade) {
        store.grade(verse.id, grade: g, mistakes: mistakeCount)
        graded = g
    }
}
