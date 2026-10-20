import AppKit
import SwiftUI

/// Manages the subtitle overlay window lifecycle and updates
@MainActor
final class SubtitleOverlayManager {
    static let shared = SubtitleOverlayManager()

    private var overlayWindow: NSWindow?
    private weak var appState: AppState?
    private var isHiding = false
    private var windowMoveObserver: Any?
    private var currentScreenFrame: NSRect = .zero
    private var positionSaveTimer: Timer?

    /// Flag to prevent updatePosition() calls during drag
    private(set) var isDragging = false

    /// Origin set by updateSize(); lets windowDidMove() tell a programmatic
    /// resize apart from the user dragging the window
    private var programmaticOrigin: NSPoint?

    /// Window level for subtitle overlay (above most windows but below system UI)
    private static let subtitleWindowLevel = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 1)

    private init() {}

    deinit {
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil
        if let observer = windowMoveObserver {
            NotificationCenter.default.removeObserver(observer)
            windowMoveObserver = nil
        }
    }

    /// Show the subtitle overlay on the specified screen
    /// - Parameter screen: The screen to show the overlay on. If nil, uses main screen.
    func show(appState: AppState, on screen: NSScreen? = nil) {
        self.appState = appState

        let targetScreen = screen ?? overlayWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first

        // Hide existing window if any (without animation to avoid delays)
        if let existingWindow = overlayWindow {
            removeWindowMoveObserver()
            existingWindow.orderOut(nil)
            overlayWindow = nil
        }

        guard let targetScreen = targetScreen else { return }

        // Store current screen frame for position validation
        currentScreenFrame = targetScreen.frame

        // Calculate window frame
        let screenFrame = targetScreen.visibleFrame  // Use visibleFrame to account for menu bar and dock
        let windowSize = Self.windowSize(for: appState, in: screenFrame)
        let windowWidth = windowSize.width
        let windowHeight = windowSize.height
        var windowFrame: NSRect

        if appState.subtitleUseCustomPosition {
            // Use saved custom position, but validate it's within current screen bounds
            var x = appState.subtitleCustomX
            var y = appState.subtitleCustomY

            // Ensure the window is within screen bounds
            let fullScreenFrame = targetScreen.visibleFrame
            x = max(fullScreenFrame.minX, min(x, fullScreenFrame.maxX - windowWidth))
            y = max(fullScreenFrame.minY, min(y, fullScreenFrame.maxY - windowHeight))

            windowFrame = NSRect(
                x: x,
                y: y,
                width: windowWidth,
                height: windowHeight
            )
        } else if appState.subtitlePosition == .top {
            windowFrame = NSRect(
                x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
                y: screenFrame.maxY - windowHeight - 20,
                width: windowWidth,
                height: windowHeight
            )
        } else {
            windowFrame = NSRect(
                x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
                y: screenFrame.origin.y + 20,
                width: windowWidth,
                height: windowHeight
            )
        }
        dprint("SubtitleOverlayManager: Screen frame: \(targetScreen.frame), visible: \(screenFrame)")
        dprint("SubtitleOverlayManager: Window frame: \(windowFrame)")


        // Create the overlay window
        let window = NSPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        window.identifier = NSUserInterfaceItemIdentifier("subtitle")
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = Self.subtitleWindowLevel
        window.ignoresMouseEvents = false  // Allow mouse interaction for dragging
        window.isMovableByWindowBackground = false // Explicit handle in SubtitleOverlayView.
        window.hasShadow = false
        // Remove .stationary to allow free movement
        window.collectionBehavior = ToolWindowPolicy.currentSpace
        window.isReleasedWhenClosed = false

        // Set up SwiftUI content view
        let contentView = SubtitleOverlayView()
            .environment(appState)

        window.contentView = NSHostingView(rootView: contentView)
        WindowPlacement.fit(window)
        window.orderFrontRegardless()

        self.overlayWindow = window

        // Observe window move events to save position
        setupWindowMoveObserver(for: window)
        dprint("SubtitleOverlayManager: Overlay shown on screen: \(targetScreen.localizedName)")

    }

    /// Hide the subtitle overlay
    func hide() {
        // Prevent re-entrant calls
        guard !isHiding else { return }
        isHiding = true

        // Remove observer
        removeWindowMoveObserver()

        // Capture window reference before clearing
        let windowToHide = overlayWindow
        overlayWindow = nil

        // Hide the window
        windowToHide?.orderOut(nil)

        isHiding = false
        dprint("SubtitleOverlayManager: Overlay hidden")

    }

    /// Update the overlay position (top/bottom or custom)
    func updatePosition() {
        guard let appState = appState, overlayWindow != nil else { return }
        // Recreate the window with new position
        show(appState: appState)
    }

    /// Window size derived from the current subtitle settings.
    /// Height = max lines of text + header + padding, plus room for the
    /// original-text block when it is shown next to the translation.
    private static func windowSize(for appState: AppState, in screenFrame: NSRect) -> NSSize {
        let width = min(screenFrame.width * 0.92, CGFloat(appState.subtitleWindowWidth))
        let lineHeight = appState.subtitleFontSize * 1.4
        var textAreaHeight = lineHeight * CGFloat(appState.subtitleMaxLines)
        if appState.subtitleShowOriginal && appState.subtitleTranslationEnabled {
            // Original text uses 0.7x font size and up to 2 lines, plus 8pt spacing
            textAreaHeight += appState.subtitleFontSize * 0.7 * 1.4 * 2 + 8
        }
        return NSSize(width: width, height: textAreaHeight + 84)  // header (24) + padding
    }

    /// Resize the visible overlay in place after a settings change
    /// (font size, max lines, width, show-original). Keeps the window's anchor edge fixed.
    func updateSize() {
        guard let appState = appState, let window = overlayWindow, !isHiding else { return }
        guard let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let size = Self.windowSize(for: appState, in: screenFrame)
        var frame = window.frame
        let anchorBottom = !appState.subtitleUseCustomPosition && appState.subtitlePosition == .bottom
        let oldTop = frame.maxY
        frame.size = size
        frame.origin.y = anchorBottom ? frame.origin.y : oldTop - size.height
        // Keep inside the visible screen area
        frame.origin.x = max(screenFrame.minX, min(frame.origin.x, screenFrame.maxX - size.width))
        frame.origin.y = max(screenFrame.minY, min(frame.origin.y, screenFrame.maxY - size.height))

        // A programmatic resize must not be mistaken for the user dragging the window
        programmaticOrigin = (frame.origin == window.frame.origin) ? nil : frame.origin
        window.setFrame(frame, display: true, animate: false)
    }

    /// Check if overlay is currently visible
    var isVisible: Bool {
        overlayWindow?.isVisible ?? false
    }

    /// Reset to preset position (clear custom position)
    func resetToPresetPosition() {
        guard let appState = appState else { return }
        appState.subtitleUseCustomPosition = false
        updatePosition()
    }

    // MARK: - Private Methods

    private func setupWindowMoveObserver(for window: NSWindow) {
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowDidMove()
            }
        }
    }

    private func removeWindowMoveObserver() {
        if let observer = windowMoveObserver {
            NotificationCenter.default.removeObserver(observer)
            windowMoveObserver = nil
        }
        cancelPendingSave()
        isDragging = false
    }

    private func windowDidMove() {
        guard let window = overlayWindow, appState != nil else { return }

        // Ignore the move notification caused by updateSize()
        if let expected = programmaticOrigin {
            programmaticOrigin = nil
            if abs(window.frame.origin.x - expected.x) < 1, abs(window.frame.origin.y - expected.y) < 1 {
                return
            }
        }

        // Mark as dragging to prevent updatePosition() calls
        isDragging = true

        // Cancel any pending save
        positionSaveTimer?.invalidate()

        // Debounce: save position after dragging stops (200ms delay)
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveWindowPosition()
            }
        }
    }

    private func saveWindowPosition() {
        guard let window = overlayWindow, let appState = appState else { return }

        // Save the position
        let frame = window.frame
        appState.subtitleCustomX = frame.origin.x
        appState.subtitleCustomY = frame.origin.y

        // Set custom position flag without triggering updatePosition
        if !appState.subtitleUseCustomPosition {
            appState.setCustomPositionFlag(true)
        }

        // Clear dragging flag
        isDragging = false
        dprint("SubtitleOverlayManager: Position saved at (\(frame.origin.x), \(frame.origin.y))")

    }

    private func cancelPendingSave() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil
    }
}
