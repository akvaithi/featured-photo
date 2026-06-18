import SwiftUI

@main
struct FeaturedPhotoApp: App {
    @StateObject private var store = StackStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}
