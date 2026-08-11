import AppKit
import Carbon
import InputMethodKit
import os.log

// Entry point of the whole IME. Unlike its predecessor there is no helper
// process to launch and no socket to connect to: the conversion engine is a
// library inside this process. See DESIGN.md §1.1.

let logger = Logger(subsystem: "dev.vimeu.inputmethod", category: "ime")

_ = NSApplication.shared

// Self-register with TIS so vimeu shows up in
// System Settings > Keyboard > Input Sources without a separate installer.
TISRegisterInputSource(Bundle.main.bundleURL as CFURL)

// Must match Info.plist exactly; IMKServer reads
// InputMethodServerControllerClass from the bundle to find the controller class.
let connectionName =
    Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "dev.vimeu.inputmethod.VimeuIME_Connection"

let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
logger.info("vimeu started (connection=\(connectionName, privacy: .public))")

// Open the dictionary up front. It is `mmap`ed, so this parses nothing and
// costs microseconds; the pages fault in as conversion touches them.
ConversionService.shared.loadIfNeeded()

NSApp.run()
