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
///   "tlimsisnwp231" flows in as one session; the reference composes
///   inline as "Psalm 23:1", styled just like the verse words.
/// - right character -> appears; wrong -> buzz, red mistake, move on
/// - every mistake carries its own "accidental?" forgiveness toggle
/// - mistake count shown instead of a progress bar
/// - grade is ALWAYS explicit (Again/Hard/Good/Easy) -> true SM-2
/// - every grade has an 8s Undo
struct ReviewView: View {
    @EnvironmentObject var store: VerseStore
    var verse: Verse

    // One unified stream: word indices 0..<words.count, then reference slots.
    @State private var idx = 0
    @State private var revealed: Set<Int> = []
    @State private var mistakes: Set<Int> = []
    @State private var forgiven: Set<Int> = []

    @State private var entry = ""
    @FocusState private var entryFocused: Bool
    @State private var graded: Grade?
    @Environment(\.dismiss) var dismiss

    private var words: [String] { verse.words }

    /// "Psalm 23:1-6" -> book "Psalm", tail "23:1-6".
    /// Parenthetical suffixes (e.g. demo labels) are stripped first.
    private var refParts: (book: String, tail: String) {
        let core = verse.reference.split(separator: "(").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? verse.reference
        guard let lastSpace = core.lastIndex(of: " "),
              lastSpace < core.index(before: core.endIndex) else {
            return (core, "") // e.g. "Jude": book only
        }
        let book = String(core[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        let tail = String(core[core.index(after: lastSpace)...])
        return (book, tail)
    }

    /// Typing stream for the reference: book initial, then tail digits.
    /// Separators (`:`, `-`, …) are never typed — they appear on their own.
    private var refExpected: [String] {
        let p = refParts
        var out: [String] = []
        if let initial = p.book.first(where: { $0.isLetter }) {
            out.append(String(initial))
        }
        out.append(contentsOf: p.tail.filter(\.isNumber).map(String.init))
        return out
    }

    private var total: Int { words.count + refExpected.count }
    private var done: Bool { idx >= total }
    private var inReference: Bool { idx >= words.count && !done }
    private var refStarted: Bool { revealed.contains(where: { $0 >= words.count }) }
    private var mistakeCount: Int { mistakes.subtracting(forgiven).count }
    private var mistakeText: String { mistakeCount == 1 ? "1 mistake" : "\(mistakeCount) mistakes" }
    private var suggested: String {
        if mistakeCount == 0 { return "Easy" }
        if mistakeCount <= 2 { return "Good" }
        return "Hard"
    }

    /// Stream index -> expected input character.
    private func want(for i: Int) -> String {
        i < words.count ? verse.hints[i] : refExpected[i - words.count]
    }

    /// Numbers must match exactly; letters match case-insensitively.
    private func matches(_ typed: Character, want: String) -> Bool {
        want.first?.isNumber == true
            ? String(typed) == want
            : String(typed).lowercased() == want.lowercased()
    }

    private func isMistake(_ i: Int) -> Bool { mistakes.contains(i) && !forgiven.contains(i) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hiddenField
                passage
                if refStarted { referenceRow }
                if !done {
                    controls
                }
                if graded == nil {
                    if done { gradeBlock }
                } else {
                    gradedBlock
                }
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture { entryFocused = true }
        }
        .navigationTitle("Type")
        .navigationBarTitleDisplayMode(.inline)
        .background(ShakeDetector().frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            forgiveLatestMistake()
        }
        .onAppear { entryFocused = true }
    }

    // MARK: header — due state + mistake count only

    private var header: some View {
        HStack {
            DueBadge(review: store.review(for: verse.id))
            Text("· \(mistakeText)")
                .font(.caption).bold(mistakeCount > 0)
                .foregroundStyle(mistakeCount > 0 ? Color.red : Color.secondary)
                .accessibilityIdentifier("mistake-count")
            Spacer()
        }
    }

    // MARK: passage — revealed words flow as one paragraph, mistakes in red

    private var passage: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                if revealed.contains(i) {
                    mistakeChip(label: word, index: i)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
    }

    // MARK: reference — composes inline ("Psalm 23:1-6"), styled like words.
    // Tail digits are typed slots; separators (:, -, …) appear on their own
    // once everything before them is revealed. So ranges just work.

    /// Tail mapped to stream slots: digits carry their stream index,
    /// separators carry nil and render statically in flow position.
    private var tailSlots: [(char: Character, stream: Int?)] {
        let w = words.count
        var typedOrdinal = 0
        return refParts.tail.map { ch -> (Character, Int?) in
            if ch.isNumber {
                typedOrdinal += 1
                return (ch, w + typedOrdinal) // +1: slot 0 is the book initial
            }
            return (ch, nil)
        }
    }

    private var referenceRow: some View {
        let p = refParts
        let w = words.count
        let bookSlot = w
        return HStack(alignment: .top, spacing: 0) {
            if revealed.contains(bookSlot) {
                mistakeChip(label: p.book, index: bookSlot)
                Text(" ").font(.title3)
            }
            ForEach(Array(tailSlots.enumerated()), id: \.offset) { k, slot in
                if let s = slot.stream {
                    if revealed.contains(s) {
                        mistakeChip(label: String(slot.char), index: s, refTag: s)
                    }
                } else if tailStaticVisible(k) {
                    Text(String(slot.char)).font(.title3).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A separator shows once every typed slot before it is revealed.
    private func tailStaticVisible(_ k: Int) -> Bool {
        let slots = tailSlots
        guard k < slots.count else { return false }
        for j in 0..<k {
            if let s = slots[j].stream, !revealed.contains(s) { return false }
        }
        return true
    }

    /// A revealed item: full color normally, red with an "accidental?"
    /// affordance while it's an unforgiven mistake. Forgiven items render
    /// plain (tap again to unmark).
    private func mistakeChip(label: String, index i: Int, refTag: Int? = nil) -> some View {
        let bad = isMistake(i)
        let wasBad = mistakes.contains(i)
        return Button {
            if wasBad { toggleForgiven(i) }
        } label: {
            VStack(spacing: 0) {
                Text(label)
                    .font(.title3)
                    .foregroundStyle(bad ? Color.red : Color.primary)
                if bad {
                    Text("accidental?").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!wasBad)
        .accessibilityLabel(bad
            ? (refTag == nil ? "Mark accidental: \(label)" : "Mark accidental ref \(refTag!)")
            : (mistakes.contains(i) ? "Accidental, tap to unmark" : label))
    }

    // MARK: input — invisible capture field; the keyboard is the UI.
    // Tapping anywhere refocuses (see the VStack tap gesture).

    private var hiddenField: some View {
        TextField("", text: $entry)
            .accessibilityIdentifier("first-letter-input")
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($entryFocused)
            .onChange(of: entry) { _, new in processInput(new) }
            .onSubmit { entry = "" }
            .frame(width: 1, height: 1)
            .opacity(0.01)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                // A shown item is a miss — forgivable like any other mistake.
                mistakes.insert(idx)
                revealed.insert(idx)
                advance()
                entryFocused = true
            } label: {
                Label(inReference ? "Show character" : "Show word",
                      systemImage: "questionmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            Button {
                reset()
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
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
