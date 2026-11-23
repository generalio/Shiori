import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct Wenku8StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = StudioViewModel()

    var body: some Scene {
        WindowGroup("Wenku8 Studio · 轻小说文库 EPUB 下载器") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1020, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1220, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Wenku8 Studio") {
                    viewModel.navigateToSettingsCategory(.about)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    viewModel.navigateToSettingsCategory(.about)
                    Task { await viewModel.checkForAppUpdates(silent: false) }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    viewModel.navigateToSection(.settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
