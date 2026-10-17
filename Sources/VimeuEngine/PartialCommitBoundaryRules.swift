import Foundation

/// Which ends of dictionary tokens may border a partial commit. Resolve the
/// POS features once per loaded system dictionary, never by hardcoded IDs.
public struct PartialCommitBoundaryRules: Sendable {
    private let mayStart: [Bool]
    private let mayEnd: [Bool]

    public init(dictionary: DictionarySource) {
        self.init(posNames: (0..<dictionary.posCount).map { dictionary.posName($0) })
    }

    public init(posNames: [String]) {
        mayStart = posNames.map { name in
            let parts = name.split(separator: ",", omittingEmptySubsequences: false)
            guard let major = parts.first else { return false }
            if ["助詞", "助動詞", "BOS/EOS"].contains(major) { return false }
            if parts.count > 1, ["非自立", "接尾", "動詞非自立的"].contains(parts[1]) { return false }
            return true
        }
        mayEnd = posNames.map { !$0.hasPrefix("接頭詞,") && !$0.hasPrefix("BOS/EOS,") }
    }

    public func allows(leftRightID: Int, rightLeftID: Int) -> Bool {
        guard mayEnd.indices.contains(leftRightID), mayStart.indices.contains(rightLeftID) else { return false }
        return mayEnd[leftRightID] && mayStart[rightLeftID]
    }
}
