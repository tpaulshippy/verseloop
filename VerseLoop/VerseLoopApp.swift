import SwiftUI

@main
struct VerseLoopApp: App {
    @StateObject private var store = VerseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
