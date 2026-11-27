import AppKit
import Sparkle
import SwiftUI

@main
struct BlissStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioDelegate.self) private var delegate

    var body: some Scene {
        Settings { StudioSettings(windows: delegate.windows) }
            .commands {
                CommandGroup(after: .appInfo) {
                    StudioUpdateMenu(controller: delegate.updater)
                }
                CommandGroup(after: .windowArrangement) {
                    Button("Open Player") { delegate.windows.openPlayer() }
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("Open Artwork") { delegate.windows.openArtwork() }
                    Button("Preview") { delegate.windows.openPlayer(preview: true) }
                }
            }
    }
}

final class StudioDelegate: NSObject, NSApplicationDelegate {
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    let windows: StudioWindows
    private var migrationError: Error?

    override init() {
        do { try StudioLibrary.migrate() }
        catch { migrationError = error }
        windows = StudioWindows()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let migrationError { NSApp.presentError(migrationError) }
        NSApp.setActivationPolicy(.regular)
        windows.openPlayer()
        updater.startUpdater()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.openPlayer()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { windows.stop() }
}

private struct StudioSettings: View {
    @Bindable var windows: StudioWindows

    var body: some View {
        @Bindable var session = windows.session
        Form {
            Section("Playback") {
                Picker("Follow player", selection: $session.preferredSource) {
                    Text("Automatic").tag(StudioSource?.none)
                    ForEach(StudioSource.allCases) { Text($0.title).tag(Optional($0)) }
                }
                HStack {
                    Button("Open artwork window") { windows.openArtwork() }
                    Button("Preview") { windows.openPlayer(preview: true) }
                }
            }
            Section("Edge light") {
                Toggle("Desktop edge light", isOn: $windows.desktopLight)
                Picker("Display", selection: $windows.displayID) {
                    Text("Main display").tag("")
                    ForEach(windows.screenOptions) { Text($0.title).tag($0.id) }
                    if !windows.displayID.isEmpty && !windows.screenOptions.contains(where: { $0.id == windows.displayID }) {
                        Text("Disconnected display").tag(windows.displayID)
                    }
                }
                Picker("Light palette", selection: $session.paletteMode) {
                    ForEach(StudioPaletteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Slider(value: $session.lightIntensity, in: 0...1) { Text("Glow") }
                Slider(value: $session.lightWidth, in: 1...16, step: 1) { Text("Edge width") }
                Toggle("Animate light", isOn: $session.animateLight)
                Toggle("Sync light to the beat", isOn: $session.beatSync)
                Text(session.beatStatus).font(.caption).foregroundStyle(.secondary)
                Toggle("React to system audio", isOn: $session.reactive)
                if let status = session.meterStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).frame(width: 450, height: 570)
    }
}
