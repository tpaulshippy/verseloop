import SwiftUI

@main
struct VerseLoopApp: App {
    @StateObject private var store = VerseStore()

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("-UITestReview") {
                // Deterministic UI-test hook: open the review screen directly
                // with the demo verse (bypasses list navigation).
                NavigationStack {
                    ReviewView(verse: Verse(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        reference: "Psalm 23:1 (demo · KJV)",
                        text: "The LORD is my shepherd; I shall not want.",
                        textSource: "kjv-demo"
                    ))
                }
                .environmentObject(store)
            } else if CommandLine.arguments.contains("-UITestRange") {
                // Multi-verse range hook (public-domain KJV): Psalm 23:1-2.
                NavigationStack {
                    ReviewView(verse: Verse(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        reference: "Psalm 23:1-2 (demo · KJV)",
                        text: "The LORD is my shepherd; I shall not want. He maketh me to lie down in green pastures: he leadeth me beside the still waters.",
                        textSource: "kjv-demo"
                    ))
                }
                .environmentObject(store)
            } else if CommandLine.arguments.contains("-UITestLong") {
                // Long-passage hook (public-domain KJV): Psalm 23:1-4.
                // Exercises auto-scroll follow on verses that overflow.
                NavigationStack {
                    ReviewView(verse: Verse(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                        reference: "Psalm 23:1-4 (demo · KJV)",
                        text: "The LORD is my shepherd; I shall not want. He maketh me to lie down in green pastures: he leadeth me beside the still waters. He restoreth my soul: he leadeth me in the paths of righteousness for his name's sake. Yea, though I walk through the valley of the shadow of death, I will fear no evil: for thou art with me; thy rod and thy staff they comfort me.",
                        textSource: "kjv-demo"
                    ))
                }
                .environmentObject(store)
            } else {
                ContentView()
                    .environmentObject(store)
            }
        }
    }
}
