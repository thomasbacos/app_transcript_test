import SwiftUI

@main
struct ParleyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.store)
                .environment(model.recorder)
                .environment(model.subscriptions)
                .environment(model.processing)
                .tint(Theme.indigo)
        }
    }
}
