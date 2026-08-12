import Foundation

/// Reads and writes the user's edits as TSV in one directory.
///
/// Why text and not SQLite: the data is small (edits are explicit, and there is
/// no automatic learning filling it up), it is the user's own work, and keeping
/// it as sorted TSV makes it inspectable, diffable, and portable — backing it up
/// or moving it to another machine is a file copy. It also keeps the core free
/// of libsqlite3, and of the `sqlite3_finalize` leak that a long-lived input
/// method would otherwise have to be careful about.
///
/// Writes rewrite the whole file through a temporary file and `rename`, so a
/// crash mid-save leaves the previous version intact rather than a truncated
/// one. At a few thousand rows the file is under 100 KB and the rewrite is not
/// worth optimising into a diff.
public final class UserDictionaryStore: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var words: [WordKey: WordEdit]
        public var collocations: [CollocationKey: CollocationEdit]
        public var connections: [ConnectionKey: ConnectionEdit]

        public init(
            words: [WordKey: WordEdit] = [:],
            collocations: [CollocationKey: CollocationEdit] = [:],
            connections: [ConnectionKey: ConnectionEdit] = [:]
        ) {
            self.words = words
            self.collocations = collocations
            self.connections = connections
        }

        public var isEmpty: Bool {
            words.isEmpty && collocations.isEmpty && connections.isEmpty
        }
    }

    public let directory: URL

    private let wordHeader = "reading\tsurface\tcost\tdisabled\tupdated_at"
    private let collocationHeader = "left\tright\tupdated_at"
    private let connectionHeader = "left_pos\tright_pos\tcost\tdisabled\tupdated_at"

    public init(directory: URL) {
        self.directory = directory
    }

    /// The per-user location. Under App Sandbox this resolves inside the app's
    /// container automatically, so it needs no entitlement.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VimeuIME", isDirectory: true)
    }

    private var wordURL: URL { directory.appendingPathComponent("user_word.tsv") }
    private var collocationURL: URL { directory.appendingPathComponent("user_collocation.tsv") }
    private var connectionURL: URL { directory.appendingPathComponent("user_connection.tsv") }

    // MARK: - Load

    /// Load everything. Missing files mean "no edits yet", not an error — that
    /// is the state every user starts in.
    public func load() throws -> Snapshot {
        var snapshot = Snapshot()

        for fields in try rows(of: wordURL) {
            guard fields.count >= 4 else { continue }
            let edit = WordEdit(
                reading: fields[0],
                surface: fields[1],
                cost: parseOptionalCost(fields[2]),
                disabled: fields[3] == "1",
                updatedAt: fields.count > 4 ? (Int64(fields[4]) ?? 0) : 0
            )
            guard !edit.reading.isEmpty, !edit.surface.isEmpty else { continue }
            snapshot.words[edit.key] = edit
        }

        for fields in try rows(of: collocationURL) {
            guard fields.count >= 2 else { continue }
            let edit = CollocationEdit(
                left: fields[0],
                right: fields[1],
                updatedAt: fields.count > 2 ? (Int64(fields[2]) ?? 0) : 0
            )
            guard !edit.left.isEmpty, !edit.right.isEmpty else { continue }
            snapshot.collocations[edit.key] = edit
        }

        for fields in try rows(of: connectionURL) {
            guard fields.count >= 4 else { continue }
            let edit = ConnectionEdit(
                left: fields[0],
                right: fields[1],
                cost: parseOptionalCost(fields[2]),
                disabled: fields[3] == "1",
                updatedAt: fields.count > 4 ? (Int64(fields[4]) ?? 0) : 0
            )
            // A row with neither a cost nor the hidden flag has nothing to say;
            // dropping it here keeps `OverlaidDictionary` from having to.
            guard !edit.left.isEmpty, !edit.right.isEmpty,
                  edit.effectiveCost != nil else { continue }
            snapshot.connections[edit.key] = edit
        }

        return snapshot
    }

    /// Tab-separated rows of a file, header skipped. A missing file is empty.
    private func rows(of url: URL) throws -> [[String]] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// An empty field means "no value" — for a word that is a hide-only edit
    /// with no cost of its own.
    private func parseOptionalCost(_ s: String) -> Int32? {
        s.isEmpty ? nil : Int32(s)
    }

    // MARK: - Save

    public func saveWords(_ words: [WordKey: WordEdit]) throws {
        let sorted = words.values.sorted {
            $0.reading != $1.reading
                ? UserDict.utf8Less($0.reading, $1.reading)
                : UserDict.utf8Less($0.surface, $1.surface)
        }
        var out = wordHeader + "\n"
        for e in sorted {
            let cost = e.cost.map(String.init) ?? ""
            out += "\(e.reading)\t\(e.surface)\t\(cost)\t\(e.disabled ? 1 : 0)\t\(e.updatedAt)\n"
        }
        try writeAtomically(out, to: wordURL)
    }

    public func saveCollocations(_ pairs: [CollocationKey: CollocationEdit]) throws {
        let sorted = pairs.values.sorted {
            $0.left != $1.left
                ? UserDict.utf8Less($0.left, $1.left)
                : UserDict.utf8Less($0.right, $1.right)
        }
        var out = collocationHeader + "\n"
        for e in sorted {
            out += "\(e.left)\t\(e.right)\t\(e.updatedAt)\n"
        }
        try writeAtomically(out, to: collocationURL)
    }

    public func saveConnections(_ connections: [ConnectionKey: ConnectionEdit]) throws {
        let sorted = connections.values.sorted {
            $0.left != $1.left
                ? UserDict.utf8Less($0.left, $1.left)
                : UserDict.utf8Less($0.right, $1.right)
        }
        var out = connectionHeader + "\n"
        for e in sorted {
            let cost = e.cost.map(String.init) ?? ""
            out += "\(e.left)\t\(e.right)\t\(cost)\t\(e.disabled ? 1 : 0)\t\(e.updatedAt)\n"
        }
        try writeAtomically(out, to: connectionURL)
    }

    /// Write through a temporary file in the same directory and `rename` over
    /// the target, so the file is never observed half-written.
    private func writeAtomically(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
