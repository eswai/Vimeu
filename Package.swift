// swift-tools-version:6.2
import PackageDescription

// vimeu has no external package dependencies on purpose: the whole IME is a
// single process linking nothing but system frameworks. See DESIGN.md §1.
let package = Package(
    name: "vimeu",
    // The installed macOS 27 SDK does not define a macOS 25 deployment target;
    // v26 is the lowest buildable target in this toolchain.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "vimeu-dictbuild", targets: ["vimeu-dictbuild"]),
        .executable(name: "vimeu-eval", targets: ["vimeu-eval"]),
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

        // Framework-neutral input session: the state machine of DESIGN.md §4.1
        // driven by abstract keys, used by the Linux fcitx5 addon (§8).
        .target(name: "VimeuSession", dependencies: ["VimeuEngine", "VimeuInput", "VimeuDict", "VimeuUserDict"]),

        // ── Build-time / evaluation tools ───────────────────────────────────
        .executableTarget(name: "vimeu-dictbuild", dependencies: ["VimeuDict"]),
        .executableTarget(name: "vimeu-eval", dependencies: ["VimeuEngine"]),

        // ── Tests ───────────────────────────────────────────────────────────
        // An IME process cannot be debugged with breakpoints (they freeze the
        // desktop), so library-level tests are the only practical verification.
        .testTarget(name: "VimeuDictTests", dependencies: ["VimeuDict"]),
        .testTarget(name: "VimeuEngineTests", dependencies: ["VimeuEngine"]),
        .testTarget(name: "VimeuUserDictTests", dependencies: ["VimeuUserDict"]),
        .testTarget(name: "VimeuInputTests", dependencies: ["VimeuInput"]),
        .testTarget(name: "VimeuSessionTests", dependencies: ["VimeuSession", "VimeuEngine", "VimeuDict"]),
    ]
)

// ── Linux layer ─────────────────────────────────────────────────────────────
// C ABI for the fcitx5 addon (linux/fcitx5, DESIGN.md §8). CVimeu holds only
// the header; VimeuCAPI implements it. The Swift runtime is linked in
// statically so the addon loads into fcitx5 without a Swift installation.
#if os(Linux)
package.products += [
    .library(name: "vimeu", type: .dynamic, targets: ["VimeuCAPI"]),
]
package.targets += [
    .target(name: "CVimeu"),
    .target(
        name: "VimeuCAPI",
        dependencies: ["CVimeu", "VimeuSession", "VimeuInput"],
        linkerSettings: [.unsafeFlags([
            "-static-stdlib",
            // Autolinking stops at libFoundation.a; its own dependencies have
            // to be named for a shared library. -z defs turns any symbol
            // still missing into a link error instead of a dlopen failure.
            // Everything goes through -Xlinker: the driver moves plain -l
            // flags away from the group markers.
            "-Xlinker", "--start-group",
            "-Xlinker", "-lFoundation", "-Xlinker", "-lFoundationInternationalization",
            "-Xlinker", "-lFoundationEssentials", "-Xlinker", "-l_FoundationICU",
            "-Xlinker", "-l_FoundationCollections", "-Xlinker", "-l_FoundationCShims",
            "-Xlinker", "-lCoreFoundation", "-Xlinker", "-lswiftSynchronization",
            "-Xlinker", "--end-group",
            "-Xlinker", "-z", "-Xlinker", "defs",
            "-Xlinker", "--version-script=\(Context.packageDirectory)/linux/libvimeu.map",
        ])]
    ),
]
#endif

// ── macOS layer ─────────────────────────────────────────────────────────────
// IMKit / AppKit targets exist only on macOS.
#if os(macOS)
package.products += [
    .executable(name: "VimeuIME", targets: ["VimeuIME"]),
    .executable(name: "vimeu-preview", targets: ["vimeu-preview"]),
]
package.targets += [
    // Candidate panel. MainActor by default: every AppKit touch is main-thread.
    .target(
        name: "VimeuUI",
        dependencies: ["VimeuEngine", "VimeuUserDict", "VimeuInput"],
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

    // Opens the tuning window outside the IME. The input method's own
    // windows are only reachable through the input menu and the process
    // cannot be debugged, so this is the only way to iterate on that UI.
    .executableTarget(
        name: "vimeu-preview",
        dependencies: ["VimeuEngine", "VimeuUI", "VimeuUserDict"],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        linkerSettings: [.linkedFramework("AppKit")]
    ),
    .testTarget(name: "VimeuIMETests", dependencies: ["VimeuIME"]),
    .testTarget(
        name: "VimeuUITests",
        dependencies: ["VimeuUI", "VimeuDict", "VimeuEngine", "VimeuUserDict"]
    ),
]
#endif
