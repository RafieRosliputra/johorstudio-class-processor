import SwiftUI
import AppKit

@main
struct ClassProcessorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        Window("JohorStudio-Class-Processor", id: "main") {
            MainView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    app.saveNow()
                }
        }
        .defaultSize(width: Self.screenSize.width, height: Self.screenSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    static var screenSize: CGSize {
        NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
