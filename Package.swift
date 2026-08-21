// swift-tools-version:6.2
import PackageDescription

// vimeu has no external package dependencies on purpose: the whole IME is a
// single process linking nothing but system frameworks. See DESIGN.md §1.
let package = Package(
    name: "vimeu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VimeuIME", targets: ["VimeuIME"]),
        .executable(name: "vimeu-dictbuild", targets: ["vimeu-dictbuild"]),
        .executable(name: "vimeu-eval", targets: ["vimeu-eval"]),
        .executable(name: "vimeu-preview", targets: ["vimeu-preview"]),
        .library(name: "VimeuEngine", targets: ["VimeuEngine"]),
    ],
    targets: [
        // ── Portable core (Foundation only, no AppKit) ───────────────────────
        // On-disk dictionary format: writer (build time) and mmap reader (runtime).
        .target(name: "VimeuDict"),

        // Lattice construction + Mozc's Viterbi and an exact backward-A* n-best.
        // The cost model is Mozc's, unchanged: word cost plus connection cost,
        // with no tuning coefficients of our own (DESIGN.md §3).
        .target(name: "VimeuEngine", dependencies: ["VimeuDict", "VimeuUserDict"]),

        // The user's dictionary edits and their on-disk form (sorted TSV).
        .target(name: "VimeuUserDict"),

        // Romaji automaton and composing buffer. Independent of the engine.
        .target(name: "VimeuInput"),

        // ── macOS layer ─────────────────────────────────────────────────────
        // Candidate panel. MainActor by default: every AppKit touch is main-thread.
        .target(
            name: "VimeuUI",
            dependencies: ["VimeuEngine", "VimeuUserDict"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        // IMKit input controller. Thin: state machine + calls into the core.
        //
        // Deliberately NOT MainActor-by-default: IMKInputController comes from an
        // unaudited ObjC header, so its methods are nonisolated and a MainActor
        // override of them is rejected. IMK does call them on the main thread, so
        // the controller reaches MainActor state through `mainSync` instead
        // (see MainSync.swift).
        .executableTarget(
            name: "VimeuIME",
            dependencies: ["VimeuEngine", "VimeuInput", "VimeuUI"],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("AppKit"),
            ]
        ),

        // ── Build-time / evaluation tools ───────────────────────────────────
        .executableTarget(name: "vimeu-dictbuild", dependencies: ["VimeuDict"]),
        .executableTarget(name: "vimeu-eval", dependencies: ["VimeuEngine"]),

        // Opens the tuning window outside the IME. The input method's own
        // windows are only reachable through the input menu and the process
        // cannot be debugged, so this is the only way to iterate on that UI.
        .executableTarget(
            name: "vimeu-preview",
            dependencies: ["VimeuEngine", "VimeuUI", "VimeuUserDict"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),

        // ── Tests ───────────────────────────────────────────────────────────
        // An IME process cannot be debugged with breakpoints (they freeze the
        // desktop), so library-level tests are the only practical verification.
        .testTarget(name: "VimeuDictTests", dependencies: ["VimeuDict"]),
        .testTarget(name: "VimeuEngineTests", dependencies: ["VimeuEngine"]),
        .testTarget(name: "VimeuUserDictTests", dependencies: ["VimeuUserDict"]),
        .testTarget(name: "VimeuInputTests", dependencies: ["VimeuInput"]),
        .testTarget(name: "VimeuUITests", dependencies: ["VimeuUI"]),
    ]
)
