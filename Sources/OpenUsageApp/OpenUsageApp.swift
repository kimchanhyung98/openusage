import OpenUsage
import SwiftUI

@main
struct OpenUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // status item과 custom panel은 AppKit 소유이므로 별도 window scene 불필요.
        // `Settings`로 activation window 없이 SwiftUI scene만 제공.
        Settings {
            EmptyView()
        }
    }
}
