import AppKit
import SwiftUI
import VimeuEngine

/// The tuning window.
///
/// Created lazily and kept forever: macOS 26 never reclaims an `NSWindow`'s
/// memory, so a long-lived input method wants as few of them as possible and
/// certainly must not make a new one per open.
public final class AdjustmentWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = AdjustmentWindowController()

    /// The last reading that was actually committed through conversion. This
    /// belongs to the process rather than to one IMK controller: IMK can create
    /// a new controller when the client changes, while the tuning window is
    /// shared by all of them.
    private static var lastConversionReading: String?

    public let viewModel = AdjustmentViewModel()
    private var chrome: AdjustmentChrome?
    private var keyMonitor: Any?
    private var skipNextFocusRefresh = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vimeu 調整"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        chrome = AdjustmentChrome(window: window, model: viewModel)
        window.contentView = NSHostingView(rootView: AdjustmentView(model: viewModel))
        installEditShortcutMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Remember a committed conversion without creating the window. The IME
    /// calls this for every completed conversion, but the window itself remains
    /// lazy until the user opens it.
    public static func recordLastConversion(reading: String) {
        guard !reading.isEmpty else { return }
        lastConversionReading = reading
    }

    /// This process is a background input-method agent with no menu bar of its
    /// own, so ⌘V and friends are never routed to the field editor. Forward them
    /// to the responder chain by hand, or the text fields in this window cannot
    /// be pasted into.
    private func installEditShortcutMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            // Either this window or a sheet it presents (the add dialogs) can be
            // the key window; both need the shortcuts.
            guard window.isKeyWindow || (window.attachedSheet?.isKeyWindow ?? false) else {
                return event
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return event }

            let action: Selector?
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            case "w": action = #selector(NSWindow.performClose(_:))
            default: action = nil
            }
            guard let action else { return event }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    /// Open the window, seeded with what the user is currently composing. When
    /// there is no active composition, show the reading from the last committed
    /// conversion instead.
    public func open(editor: DictionaryEditor?, reading: String?) {
        if viewModel.editor !== editor { viewModel.editor = editor }
        // Keep the active composition as the more immediate context. The next
        // key-window notification would otherwise replace it before the user
        // can inspect it.
        let wasKeyWindow = window?.isKeyWindow == true
        skipNextFocusRefresh = reading != nil && !wasKeyWindow
        viewModel.show(reading: reading ?? Self.lastConversionReading)
        // The IME normally runs as an accessory app, which correctly keeps it
        // out of the Dock. While this document-style window is visible, make it
        // regular so its bundled icon can be used to select or reactivate it.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        // A background-only agent is not activated by ordering a window front.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock activation and switching back from another app do not call `open`.
    /// Refresh the field when the window receives focus so it still reflects
    /// the latest conversion made since the previous visit.
    public func windowDidBecomeKey(_ notification: Notification) {
        if skipNextFocusRefresh {
            skipNextFocusRefresh = false
            return
        }
        guard let reading = Self.lastConversionReading,
              viewModel.reading != reading else { return }
        viewModel.show(reading: reading)
    }

    /// Return the input method to its normal agent presentation once there is
    /// no adjustment window for the Dock item to select.
    public func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
