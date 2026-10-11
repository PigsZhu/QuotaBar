import AppKit
import SwiftUI

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(QuotaBarDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
