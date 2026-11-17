import SwiftUI
import AppKit

@main struct EdwardScissorhandsApp: App {
    @NSApplicationDelegateAdaptor(EdwardAppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Edward Scissorhands") {
            WorkspaceView()
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
        }.defaultSize(width: 1440, height: 920)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { NotificationCenter.default.post(name: .edwardSettings, object: nil) }.keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

extension Notification.Name { static let edwardSettings = Notification.Name("EdwardOpenSettings") }

final class EdwardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
