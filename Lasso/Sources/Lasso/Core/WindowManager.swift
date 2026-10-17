import SwiftUI
import AppKit
@preconcurrency import UserNotifications

/// "Minimize to the menu bar": the window's yellow button (and closing the window) hides Lasso's window and
/// Dock icon - Lasso keeps running in the menu bar and comes back with one click.
@MainActor
final class WindowManager: NSObject, ObservableObject {
    static let shared = WindowManager()

    private weak var mainWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var orderedOut = false
    @Published private(set) var isHiddenInMenuBar = false

    func attach(_ window: NSWindow) {
        guard window !== mainWindow else { return }
        mainWindow = window
        window.isRestorable = false
        applyMinimizeBehaviour()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { WindowManager.shared.mainWindowWillClose() }
        }
    }

    /// Re-targets the yellow button when "minimize to menu bar" is on.
    func applyMinimizeBehaviour() {
        guard let button = mainWindow?.standardWindowButton(.miniaturizeButton) else { return }
        if Preferences.shared.minimizeToMenuBar && Preferences.shared.showMenuBarExtra {
            button.target = self
            button.action = #selector(minimizeButtonClicked(_:))
        } else {
            button.target = mainWindow
            button.action = #selector(NSWindow.performMiniaturize(_:))
        }
    }

    @objc private func minimizeButtonClicked(_ sender: Any?) {
        hideToMenuBar()
    }

    func hideToMenuBar() {
        guard Preferences.shared.showMenuBarExtra else {
            mainWindow?.miniaturize(nil)
            return
        }
        mainWindow?.orderOut(nil)
        orderedOut = true
        NSApp.setActivationPolicy(.accessory)
        isHiddenInMenuBar = true
        announceOnce()
    }

    private func mainWindowWillClose() {
        orderedOut = false
        guard Preferences.shared.minimizeToMenuBar, Preferences.shared.showMenuBarExtra, !DemoMode.isActive else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Keep Settings or the player open? Then stay in the Dock.
                let others = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0 !== self.mainWindow }
                if others.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                    self.isHiddenInMenuBar = true
                    self.announceOnce()
                }
            }
        }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow, window.isVisible || window.isMiniaturized || orderedOut {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window was closed - SwiftUI creates a fresh one.
            AppState.shared.openMainWindow?()
        }
        orderedOut = false
        isHiddenInMenuBar = false
        NSApp.activate()
    }

    private func announceOnce() {
        let key = "announcedMenuBarMode"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleIdentifier != nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Lasso is still running")
        content.body = String(localized: "Downloads continue in the menu bar. Click the ring icon at the top to open Lasso again.")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if granted { center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) }
        }
    }
}

/// Gives SwiftUI views access to their NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Live state for the menu bar icon (kept separate so only the icon re-renders on progress).
@MainActor
final class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published private(set) var progress: Double?
    @Published private(set) var active = 0
    @Published private(set) var speed: Double = 0
    private var lastUpdate = Date.distantPast

    func update(progress: Double?, active: Int, speed: Double) {
        let now = Date()
        let changedState = (progress == nil) != (self.progress == nil) || active != self.active
        guard changedState || now.timeIntervalSince(lastUpdate) > 1 else { return }
        lastUpdate = now
        self.progress = progress
        self.active = active
        self.speed = speed
    }
}

/// Draws Lasso's ring + play glyph as a template image; the ring fills with download progress.
enum MenuBarIcon {
    static func image(progress: Double?, playing: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.2
            let lineWidth: CGFloat = 2.1
            NSColor.black.setStroke()
            NSColor.black.setFill()
            if let progress {
                // Faint track + progress arc (clockwise from 12 o'clock).
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = lineWidth
                NSColor.black.withAlphaComponent(0.28).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                let end = 90 - 360 * CGFloat(max(0.03, min(1, progress)))
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: end, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            } else {
                // Idle: the logo's open ring.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 70, endAngle: 110 - 360 + 10, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.stroke()
            }
            let tri = NSBezierPath()
            if playing {
                // Two bars while the player is running.
                tri.appendRect(NSRect(x: center.x - 2.6, y: center.y - 2.8, width: 1.9, height: 5.6))
                tri.appendRect(NSRect(x: center.x + 0.7, y: center.y - 2.8, width: 1.9, height: 5.6))
            } else {
                tri.move(to: NSPoint(x: center.x - 1.9, y: center.y + 3.0))
                tri.line(to: NSPoint(x: center.x - 1.9, y: center.y - 3.0))
                tri.line(to: NSPoint(x: center.x + 3.1, y: center.y))
                tri.close()
            }
            tri.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var state = MenuBarState.shared
    @ObservedObject private var player = PlayerController.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(progress: state.progress, playing: player.isPlaying))
            if prefs.menuBarShowsPercent, let progress = state.progress {
                Text(verbatim: "\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }
}
