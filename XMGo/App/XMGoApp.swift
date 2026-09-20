import SwiftUI

@main
struct XMGoApp: App {
    @State private var store = HeadphoneStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}
