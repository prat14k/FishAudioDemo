import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ponytail: belt-and-suspenders with Info.plist's LSUIElement — this works even bundle-less.
        NSApp.setActivationPolicy(.accessory)
    }
}
