import Foundation

public final class CandidateViewModel: ObservableObject {
    @Published public var candidates: [String] = []
    @Published public var selectedIndex: Int = 0

    public init() {}

    public func update(candidates: [String], selected: Int) {
        self.candidates = candidates
        self.selectedIndex = selected
    }
}
