import AppKit
import Foundation
import os.log

/// Guards against the input method growing without bound.
///
/// An IME is resident for the whole login session and is wired into every app's
/// text input; if it leaks, the machine degrades and the user has no obvious way
/// to connect the two. The 2026 input-method guidelines therefore recommend
/// checking the process footprint whenever a typing session starts and bowing
/// out rather than exhausting memory. macOS restarts the input method on the
/// next keystroke, so the cost of being wrong is a dropped composition.
///
/// vimeu should never come close: the dictionary is `mmap`ed (its pages are
/// file-backed and evictable, and do not count toward the footprint the way
/// malloc'd memory does), so a healthy process sits around 30–60 MB.
enum MemoryWatchdog {
    /// Footprint at which the process gives up.
    static let limit: UInt64 = 1024 * 1024 * 1024

    /// Physical footprint in bytes — the same figure the OS uses for memory
    /// pressure decisions, which is why it is preferred over resident size.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Call at the start of each typing session. Terminates the process if the
    /// footprint has run away.
    static func checkAtSessionStart() {
        let used = footprint()
        guard used > limit else { return }
        let mb = used / (1024 * 1024)
        logger.fault("memory footprint \(mb) MB exceeds the limit; terminating")

        let notification = NSUserNotificationCompatShim(
            title: "Vimeu",
            body: "メモリ使用量が \(mb) MB に達したため、入力プログラムを再起動します。"
        )
        notification.post()
        // activateServer always runs on the main thread; see MainSync.swift.
        mainSync { NSApp.terminate(nil) }
    }
}

/// Minimal user-facing notice. `NSUserNotification` is long deprecated and
/// `UNUserNotificationCenter` needs an authorisation prompt that a background
/// input method has no good moment to ask for, so this posts a distributed
/// notification other processes can surface and always leaves a log entry.
struct NSUserNotificationCompatShim {
    let title: String
    let body: String

    func post() {
        logger.error("\(title, privacy: .public): \(body, privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.vimeu.inputmethod.memoryLimitExceeded"),
            object: nil,
            userInfo: ["title": title, "body": body],
            deliverImmediately: true
        )
    }
}
