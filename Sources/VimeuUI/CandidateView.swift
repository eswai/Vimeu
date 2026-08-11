import SwiftUI

public struct CandidateView: View {
    /// Shared with `CandidatePanel`, which measures candidate text with this
    /// size to work out how wide the panel has to be.
    static let textSize: CGFloat = 14

    @ObservedObject var model: CandidateViewModel

    public init(model: CandidateViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.candidates.enumerated()), id: \.offset) { index, text in
                candidateRow(index: index, text: text)
            }
        }
        .padding(4)
        .background(.regularMaterial)
        .cornerRadius(8)
        .shadow(radius: 4)
    }

    @ViewBuilder
    private func candidateRow(index: Int, text: String) -> some View {
        let isSelected = index == model.selectedIndex
        HStack(spacing: 4) {
            // 1–9 select directly; beyond that the number is just a position hint.
            Text("\(index + 1)")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(text)
                .font(.system(size: Self.textSize))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(4)
    }
}
