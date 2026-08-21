import Foundation

public final class CandidateViewModel: ObservableObject {
    public static let pageSize = 10

    @Published public var candidates: [String] = []
    @Published public var selectedIndex: Int = 0

    public init() {}

    public var visibleIndices: Range<Int> {
        guard !candidates.isEmpty else { return 0..<0 }
        let pageStart = (selectedIndex / Self.pageSize) * Self.pageSize
        return pageStart..<min(pageStart + Self.pageSize, candidates.count)
    }

    public func update(candidates: [String], selected: Int) {
        self.candidates = candidates
        self.selectedIndex = selected
    }
}
