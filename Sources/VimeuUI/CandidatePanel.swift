import AppKit
import SwiftUI

/// The one and only window vimeu creates.
///
/// macOS 26 never reclaims the memory an `NSWindow` allocates, so the 2026
/// input-method guidelines say to keep the window count minimal. Anything that
/// would otherwise be its own panel (tooltips, tuning UI) belongs inside this
/// one. `IMKCandidates` is deliberately not used: it predates ARC and renders
/// badly (transparent backgrounds, illegible text) on current macOS.
public final class CandidatePanel {
    private let panel: NSPanel
    public let viewModel = CandidateViewModel()

    // Candidates are whole sentences, so the panel has to size itself to the
    // content instead of using one fixed width.
    private static let minWidth: CGFloat = 200
    private static let maxWidth: CGFloat = 560
    private static let rowHeight: CGFloat = 28
    private static let padding: CGFloat = 8
    /// Number column + horizontal padding + shadow inset, per row.
    private static let rowChrome: CGFloat = 46

    private var cursorRect: NSRect?

    public init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: 40),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        // Just below the maximum level: above ordinary windows, below the
        // screen-capture/menu layer. A non-activating panel never takes key
        // focus, which is essential — the client app must keep receiving keys.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: CandidateView(model: viewModel))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    public var isVisible: Bool { panel.isVisible }

    /// Show the candidates anchored to the caret rectangle (screen coordinates).
    ///
    /// The anchor is passed in on every call rather than set separately: a panel
    /// ordered front before it has been positioned appears wherever the window
    /// last happened to be, which on the first conversion is the bottom-left
    /// corner of the screen. Pass `nil` only when the client genuinely cannot
    /// report a caret; the last known anchor is then reused, and failing that
    /// the panel lands near the pointer instead of at an arbitrary spot.
    public func show(candidates: [String], selected: Int, anchor: NSRect?) {
        viewModel.update(candidates: candidates, selected: selected)
        if let anchor { cursorRect = anchor }
        fitToContent()
        panel.orderFront(nil)
    }

    public func update(candidates: [String], selected: Int, anchor: NSRect?) {
        viewModel.update(candidates: candidates, selected: selected)
        if let anchor { cursorRect = anchor }
        fitToContent()
    }

    public func hide() {
        panel.orderOut(nil)
        // Forget the anchor with the panel. It belongs to the client that just
        // finished; reusing it would place the next app's candidates over the
        // caret of the previous one.
        cursorRect = nil
    }

    private func reposition() {
        // No caret to work from: sit under the pointer, which is at least on the
        // screen the user is looking at.
        let rect = cursorRect ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let visFrame = screen(containing: rect).visibleFrame
        let below = rect.minY - panel.frame.height - 2
        // Flip above the caret when there is no room below it.
        let y = below < visFrame.minY ? rect.maxY + 2 : below
        panel.setFrameOrigin(clampToScreen(NSPoint(x: rect.minX, y: y), in: visFrame))
    }

    private func fitToContent() {
        let height = CGFloat(viewModel.candidates.count) * Self.rowHeight + Self.padding * 2
        var frame = panel.frame
        frame.size = CGSize(width: contentWidth(), height: height)
        panel.setFrame(frame, display: true)
        reposition()
    }

    /// Width of the widest candidate, clamped. Measured with the same font the
    /// row uses, so the text is not truncated unless it exceeds `maxWidth`.
    private func contentWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: CandidateView.textSize)
        let widest = viewModel.candidates.reduce(CGFloat.zero) { widest, text in
            max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        return min(max(widest.rounded(.up) + Self.rowChrome, Self.minWidth), Self.maxWidth)
    }

    /// The screen the caret is on.
    ///
    /// Tested with `contains`, not `intersects`: a caret's line-height rectangle
    /// is zero-width, and `NSRect.intersects` is false for an empty rectangle
    /// against *any* screen. Using it silently fell through to `NSScreen.main` —
    /// the screen with the key window — so on a multi-display setup the panel
    /// was clamped to the wrong screen's visible frame and jumped displays.
    private func screen(containing rect: NSRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(rect.origin) }
            ?? NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func clampToScreen(_ origin: NSPoint, in visFrame: NSRect) -> NSPoint {
        let x = max(visFrame.minX, min(origin.x, visFrame.maxX - panel.frame.width))
        let y = max(visFrame.minY, min(origin.y, visFrame.maxY - panel.frame.height))
        return NSPoint(x: x, y: y)
    }
}
