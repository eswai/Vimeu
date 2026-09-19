import AppKit
import VimeuDict
import VimeuEngine
import VimeuUI
import VimeuUserDict
import SwiftUI

// Opens the tuning window outside the IME.
//
// The input method itself cannot be debugged — breakpoints freeze the desktop —
// and its windows are only reachable through the input menu, which makes
// iterating on this UI impossible from inside the app. This is the harness the
// 2026 input-method guidelines recommend for exactly that reason.
//
//   swift run vimeu-preview [--dic <path>] [--reading <kana>] [--user <dir>]
//                            [--tab words|collocations|connections|liveConversion] [--dark]
//                            [--snapshot <out.png>]
//
// With --snapshot it renders the window to a PNG and exits, so a layout change
// can be looked at without taking over the screen.

var flags: [String: String] = [:]
var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    guard argv[i].hasPrefix("--"), i + 1 < argv.count else {
        FileHandle.standardError.write(Data("vimeu-preview: bad argument \(argv[i])\n".utf8))
        exit(1)
    }
    flags[String(argv[i].dropFirst(2))] = argv[i + 1]
    i += 2
}

let dicPath = flags["dic"] ?? "dict/vimeu.dic"
let reading = flags["reading"] ?? "きょうはいいてんきですね"
let userDirectory = flags["user"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("vimeu-preview-user", isDirectory: true)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Everything here uses semantic colours, so checking the dark appearance is
// just a matter of asking for it. It has to be set on the *window* as well as
// the app: the hosting view resolves its colours from the window's appearance,
// and setting only NSApp's leaves SwiftUI drawing light-appearance text onto a
// dark background.
let darkAppearance = flags["dark"] != nil ? NSAppearance(named: .darkAqua) : nil
app.appearance = darkAppearance

let model = AdjustmentViewModel()
do {
    let system = try DicReader(path: dicPath)
    model.editor = DictionaryEditor(
        system: system,
        store: UserDictionaryStore(directory: userDirectory)
    )
} catch {
    FileHandle.standardError.write(Data("vimeu-preview: \(error)\n".utf8))
    exit(1)
}
model.show(reading: reading)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Vimeu 調整（プレビュー）"
window.appearance = darkAppearance
window.center()
model.tab = AdjustmentViewModel.Tab(rawValue: flags["tab"] ?? "words") ?? .words
let chrome = AdjustmentChrome(window: window, model: model)
_ = chrome
// The colour scheme has to reach SwiftUI's environment as well: setting only
// the window's NSAppearance leaves AppKit-backed views (the Table) dark while
// SwiftUI keeps resolving .primary for the light appearance — black on black.
window.contentView = NSHostingView(
    rootView: AdjustmentView(model: model)
        .preferredColorScheme(darkAppearance == nil ? .light : .dark)
)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

if let snapshotPath = flags["snapshot"] {
    // Give SwiftUI a moment to lay out and draw, then capture the content view.
    // The old window-server capture function is unavailable with the macOS 26
    // deployment target, and ScreenCaptureKit would add a screen-recording
    // permission prompt to this development-only harness.
    let delay = Double(flags["delay"] ?? "") ?? 1.5
    Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
        MainActor.assumeIsolated {
            guard let contentView = window.contentView,
                  let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
            else {
                FileHandle.standardError.write(Data("vimeu-preview: capture failed\n".utf8))
                exit(1)
            }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
            try? png.write(to: URL(fileURLWithPath: snapshotPath))
            print("wrote \(snapshotPath)")
            NSApp.terminate(nil)
        }
    }
}

app.run()
