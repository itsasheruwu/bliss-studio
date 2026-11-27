import AppKit
import Observation
import SwiftUI

@Observable
final class StudioWindows: NSObject, NSWindowDelegate {
    let session = StudioSession()
    private(set) var screenOptions: [DisplayOption] = []
    private(set) var hasPlayer = false
    var desktopLight: Bool {
        get { session.desktopLightEnabled }
        set {
            session.desktopLightEnabled = newValue
            updateDisplays()
        }
    }
    var displayID = UserDefaults.standard.string(forKey: "studio.display") ?? "" {
        didSet {
            UserDefaults.standard.set(displayID, forKey: "studio.display")
            updateDisplays()
        }
    }

    struct DisplayOption: Identifiable {
        let id: String
        let title: String
    }

    @ObservationIgnored private var player: NSWindow?
    @ObservationIgnored private var companion: NSWindow?
    @ObservationIgnored private var rim: NSPanel?
    @ObservationIgnored private var rimScreenID: String?
    @ObservationIgnored private var rimFrame: CGRect?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var sleeping = false

    func start() {
        guard !running else { return }
        running = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateDisplays),
                                              name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        updateDisplays()
    }

    func stop() {
        running = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        player?.close()
        companion?.close()
        removeRim()
        session.setPresentation(active: false, showsContent: false)
    }

    func openPlayer(preview: Bool = false) {
        if !running { start() }
        if player == nil {
            let window = makeWindow(title: "Bliss Studio", id: "BlissStudio",
                                    size: CGSize(width: 900, height: 600), screen: selectedScreen)
            window.contentView = NSHostingView(rootView: StudioCanvas(
                session: session, onClose: { [weak window] in window?.performClose(nil) },
                onFullScreen: { [weak window] in window?.toggleFullScreen(nil) },
                onCompanion: { [weak self] in self?.openArtwork() },
                installKeyHandler: { [weak window] handler in window?.installPlayerKeys(handler) }
            ))
            player = window
            hasPlayer = true
        }
        if preview { session.startPreview() }
        updatePresentation()
        player?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openArtwork() {
        if !running { start() }
        if companion == nil {
            let other = NSScreen.screens.first { $0 != (player?.screen ?? selectedScreen) }
            let window = makeWindow(title: "Bliss Studio Artwork", id: "BlissStudioArtwork",
                                    size: CGSize(width: 590, height: 480), screen: other ?? selectedScreen)
            window.contentView = NSHostingView(rootView: StudioCompanion(session: session))
            companion = window
        }
        updatePresentation()
        companion?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var selectedScreen: NSScreen? {
        NSScreen.screens.first { identifier($0) == displayID } ?? NSScreen.screens.first
    }

    private func identifier(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func makeWindow(title: String, id: String, size: CGSize, screen: NSScreen?) -> StudioWindow {
        let window = StudioWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.minSize = CGSize(width: 420, height: 360)
        window.delegate = self
        if let frame = screen?.visibleFrame {
            let width = min(size.width, frame.width)
            let height = min(size.height, frame.height)
            window.setFrame(CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                                   width: width, height: height), display: false)
        } else { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === player { player = nil; hasPlayer = false }
        if closing === companion { companion = nil }
        updateDisplays()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateDisplays() }
    func windowDidExitFullScreen(_ notification: Notification) { updateDisplays() }
    func windowDidChangeScreen(_ notification: Notification) { updateDisplays() }

    @objc private func screensSlept() { sleeping = true; updateDisplays() }
    @objc private func screensWoke() { sleeping = false; updateDisplays() }

    @objc private func updateDisplays() {
        let displays = NSScreen.screens
        screenOptions = displays.map { DisplayOption(id: identifier($0), title: $0.localizedName) }
        if running, desktopLight, !sleeping, let screen = selectedScreen {
            let id = identifier(screen)
            if rim == nil || rimScreenID != id || rimFrame != screen.frame {
                removeRim()
                let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: true)
                panel.title = "Bliss Studio Edge Light"
                panel.level = .statusBar
                panel.ignoresMouseEvents = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.isExcludedFromWindowsMenu = true
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                var notch: CGRect?
                if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                    notch = CGRect(x: left.maxX - screen.frame.minX, y: 0, width: right.minX - left.maxX,
                                   height: screen.safeAreaInsets.top)
                }
                let hostingView = NSHostingView(rootView: StudioDesktopRim(session: session, notch: notch)
                    .ignoresSafeArea().accessibilityHidden(true))
                // The display frame owns the panel size, including while the light is off.
                hostingView.sizingOptions = []
                panel.contentView = hostingView
                // Borderless windows otherwise get constrained below the menu bar.
                panel.setFrame(screen.frame, display: false)
                panel.orderFrontRegardless()
                rim = panel
                rimScreenID = id
                rimFrame = screen.frame
            }
        } else { removeRim() }
        updatePresentation()
    }

    private func removeRim() {
        rim?.orderOut(nil)
        rim = nil
        rimScreenID = nil
        rimFrame = nil
    }

    private func updatePresentation() {
        let content = player != nil || companion != nil
        session.setPresentation(active: running && !sleeping && (content || desktopLight), showsContent: player != nil)
        if desktopLight && !content && session.isPreview { session.endPreview() }
    }
}

enum StudioPlayerKey { case artwork, escape }
typealias StudioPlayerKeyHandler = @MainActor (StudioPlayerKey) -> Bool

/// SwiftUI key equivalents require a focused hosting view. The title bar and window background
/// can also own focus, so handle the player's unmodified keys at their native window.
final class StudioWindow: NSWindow {
    private var playerKeys: StudioPlayerKeyHandler?
    private var trackingMenus = Set<ObjectIdentifier>()

    func installPlayerKeys(_ handler: StudioPlayerKeyHandler?) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        center.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        trackingMenus.removeAll()
        playerKeys = handler
        if handler != nil {
            center.addObserver(self, selector: #selector(menuTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            center.addObserver(self, selector: #selector(menuTracking(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        }
    }

    @objc private func menuTracking(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        if note.name == NSMenu.didBeginTrackingNotification { trackingMenus.insert(ObjectIdentifier(menu)) }
        else { trackingMenus.remove(ObjectIdentifier(menu)) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        routePlayerKey(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if !routePlayerKey(event) { super.sendEvent(event) }
    }

    private func routePlayerKey(_ event: NSEvent) -> Bool {
        guard let playerKeys, event.type == .keyDown,
              event.window === self || (event.window == nil && isKeyWindow),
              attachedSheet == nil, NSApp.modalWindow == nil, trackingMenus.isEmpty,
              RunLoop.current.currentMode != .eventTracking, (firstResponder as? NSTextView)?.isEditable != true,
              event.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty else { return false }
        let key: StudioPlayerKey
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": key = .artwork
        case "\u{1b}": key = .escape
        default: return false
        }
        if event.isARepeat { return true }
        return playerKeys(key)
    }
}
