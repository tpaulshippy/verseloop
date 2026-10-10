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
/// - the REFERENCE IS HIDDEN and no counts are shown
/// - one seamless stream: type each word's first letter, then — without
///   breaking stride — the book initial and the numbers (colon skipped).
///   "tlimsisnwp231" flows in as one session, reference rendering inline
///   under the verse just like the words.
/// - right character -> appears; wrong -> buzz, red mistake, move on
/// - every mistake carries its own "accidental?" forgiveness toggle
/// - mistake count shown instead of a progress bar
/// - grade is ALWAYS explicit (Again/Hard/Good/Easy) -> true SM-2
/// - every grade has an 8s Undo
struct ReviewView: View {
    @EnvironmentObject var store: VerseStore
    var verse: Verse

    // One unified stream: word indices 0..<words.count, then reference chars.
    @State private var idx = 0
    @State private var revealed: Set<Int> = []
    @State private var mistakes: Set<Int> = []
    @State private var forgiven: Set<Int> = []

    @State private var entry = ""
    @FocusState private var entryFocused: Bool
    @State private var graded: Grade?
    @Environment(\.dismiss) var dismiss

    private var words: [String] { verse.words }

    /// Reference challenge: book initial, then every digit (colon skipped).
    /// Parenthetical suffixes (e.g. demo labels) are stripped first.
    private var refExpected: [String] {
        let core = verse.reference.split(separator: "(").first.map(String.init) ?? verse.reference
        var out: [String] = []
        if let firstLetter = core.first(where: { $0.isLetter }) {
            out.append(String(firstLetter))
        }
        out.append(contentsOf: core.filter(\.isNumber).map(String.init))
        return out
    }

    private var total: Int { words.count + refExpected.count }
    private var done: Bool { idx >= total }
    private var inReference: Bool { idx >= words.count && !done }
    private var mistakeCount: Int { mistakes.subtracting(forgiven).count }
    private var mistakeText: String { mistakeCount == 1 ? "1 mistake" : "\(mistakeCount) mistakes" }
    private var suggested: String {
        if mistakeCount == 0 { return "Easy" }
        if mistakeCount <= 2 { return "Good" }
        return "Hard"
    }

    /// Display text for a revealed stream item.
    private func text(for i: Int) -> String {
        i < words.count ? words[i] : refExpected[i - words.count]
    }

    /// Expected input character for a stream item.
    private func want(for i: Int) -> String {
        i < words.count ? verse.hints[i] : refExpected[i - words.count]
    }

    /// Numbers must match exactly; letters match case-insensitively.
    private func matches(_ typed: Character, want: String) -> Bool {
        want.first?.isNumber == true
            ? String(typed) == want
            : String(typed).lowercased() == want.lowercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                passage
                if !done {
                    inputRow(
                        prompt: inReference ? "Type the reference" : "Type the first letter",
                        detail: inReference ? "initial, then numbers" : "of the next word"
                    )
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
        .navigationTitle("Type")
        .navigationBarTitleDisplayMode(.inline)
        .background(ShakeDetector().frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            forgiveLatestMistake()
        }
        .onAppear { entryFocused = true }
    }

    // MARK: header — mistake count only (no reference, no counts, no progress bar)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DueBadge(review: store.review(for: verse.id))
                Text("· \(mistakeText)")
                    .font(.caption).bold(mistakeCount > 0)
                    .foregroundStyle(mistakeCount > 0 ? Color.red : Color.secondary)
                Spacer()
            }
            Text("Type the first letter of each word, then the reference — one flow. Wrong letters buzz and mark red mistakes; tap any red word to forgive a slip.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: passage — revealed items flow as one paragraph, mistakes in red

    private var passage: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 10) {
            ForEach(0..<total, id: \.self) { i in
                if revealed.contains(i) {
                    let isMistake = mistakes.contains(i) && !forgiven.contains(i)
                    let isForgiven = mistakes.contains(i) && forgiven.contains(i)
                    let word = text(for: i)
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

    private func inputRow(prompt: String, detail: String) -> some View {
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
                Text(prompt).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(inReference ? "Show character" : "Show word") {
                // A shown item is a miss — forgivable like any other mistake.
                mistakes.insert(idx)
                revealed.insert(idx)
                advance()
            }
            .buttonStyle(.bordered)
            Button("Restart") { reset() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: grading (reference revealed only now that the test is over)

    private var gradeBlock: some View {
        VStack(spacing: 10) {
            Text(verse.reference).font(.title3).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Image(systemName: mistakeCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(mistakeCount == 0 ? .green : .orange)
                Text("\(mistakeText)\(forgiven.isEmpty ? "" : " (\(forgiven.count) forgiven)")")
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

    // MARK: typing engine — one stream, words then reference

    private func processInput(_ new: String) {
        guard !new.isEmpty, !done else {
            if new.isEmpty { return }
            entry = ""
            return
        }
        for ch in new {
            if done { break }
            check(char: ch)
        }
        entry = ""
    }

    private func check(char: Character) {
        // Reference digits must match exactly; everything else is case-insensitive.
        // Non-letters are ignored during the word pass (space/return slips).
        if idx < words.count && !char.isLetter && !char.isNumber {
            return
        }
        if matches(char, want: want(for: idx)) {
            revealed.insert(idx)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            mistakes.insert(idx)
            revealed.insert(idx)
            buzzError()
        }
        advance()
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
