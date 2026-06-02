//
//  AFMServerApp.swift
//  afm-server
//
//  Created by Michael Doise on 9/14/25.
//

import SwiftUI

#if os(macOS)
import AppKit
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private(set) var updaterController: SPUStandardUpdaterController!

    override init() {
        super.init()
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let betaEnabled = UserDefaults.standard.bool(forKey: "enableBetaUpdates")
        return betaEnabled ? ["beta"] : []
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if state.userInitiated { return }
        NSApp.dockTile.badgeLabel = "Update"
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.dockTile.badgeLabel = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable window state restoration to prevent previously opened windows from appearing
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        AppLog.info("Application launched", source: "app")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When app is clicked in dock and no windows are visible, open the dashboard
        if !flag {
            NotificationCenter.default.post(name: .openDashboard, object: nil)
        }
        return true
    }

    @objc func openChatWindow() {
        NotificationCenter.default.post(name: .openChatWindow, object: nil)
    }

    @objc func openDashboard() {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

extension Notification.Name {
    static let openChatWindow = Notification.Name("openChatWindow")
    static let openDashboard = Notification.Name("openDashboard")
}
#endif

@main
struct AFMServerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serverController = ServerController()
    @Environment(\.openWindow) private var openWindow
    #endif
    
    init() {
        // Server auto-starts on launch via ServerController.
    }
    
    var body: some Scene {
        #if os(macOS)
        // Main Dashboard Window - this is the default window that opens on launch
        Window("Dashboard", id: "dashboard") {
            ServerDashboardView()
                .environmentObject(serverController)
                .task {
                    // Sync controller state with actual server state on appear
                    let running = await LocalHTTPServer.shared.getIsRunning()
                    let port = await LocalHTTPServer.shared.getPort()
                    let error = await LocalHTTPServer.shared.getLastError()
                    await MainActor.run {
                        serverController.isRunning = running
                        serverController.port = port
                        serverController.errorMessage = error
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openChatWindow)) { _ in
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "chat")
                }
                .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                }
        }
        .defaultSize(width: 600, height: 750)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            ChatCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    NSApp.sendAction(#selector(AppDelegate.checkForUpdates), to: nil, from: nil)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Open Chat Window") {
                    NSApp.sendAction(#selector(AppDelegate.openChatWindow), to: nil, from: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        
        // Menu Bar Extra
        MenuBarExtra("afm-server", systemImage: "bolt.horizontal.circle") {
            MenuBarContentView()
                .environmentObject(serverController)
                .task {
                    serverController.syncState()
                }
        }
        
        // Chat Window - suppressed on launch, only opens when requested
        Window("Chat", id: "chat") {
            ChatView()
                .environmentObject(serverController)
        }
        .defaultSize(width: 500, height: 600)
        .defaultLaunchBehavior(.suppressed)
        
        // Settings
        Settings {
            SettingsView()
        }
        #else
        WindowGroup {
            ChatView()
        }
        #endif
    }
}
