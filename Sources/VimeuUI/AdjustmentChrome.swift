import AppKit
import Combine
import SwiftUI

/// The window's title bar and toolbar.
///
/// The pane switcher lives here, not in the content — the same place Calendar
/// puts 日/週/月/年 and Finder puts its view modes. Putting it in a unified
/// toolbar is most of what makes the window read as a standard macOS window,
/// and it takes the switcher out of the content so the reading field below it
/// cannot be pushed around when a pane changes height.
public final class AdjustmentChrome: NSObject, NSToolbarDelegate {
    private static let tabsItem = NSToolbarItem.Identifier("dev.vimeu.tabs")

    private let model: AdjustmentViewModel
    private let segmented: NSSegmentedControl
    private var observer: AnyCancellable?

    public init(window: NSWindow, model: AdjustmentViewModel) {
        self.model = model
        segmented = NSSegmentedControl(
            labels: AdjustmentViewModel.Tab.allCases.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init()

        segmented.target = self
        segmented.action = #selector(tabChanged(_:))
        segmented.selectedSegment = index(of: model.tab)
        observer = model.$tab.sink { [weak self] tab in
            guard let self else { return }
            segmented.selectedSegment = self.index(of: tab)
        }

        let toolbar = NSToolbar(identifier: "dev.vimeu.adjustment")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.tabsItem]
        toolbar.allowsUserCustomization = false

        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // The pane switcher already says what the window is showing, and the
        // extra title line only steals height — the same call Calendar makes.
        window.titleVisibility = .hidden
    }

    private func index(of tab: AdjustmentViewModel.Tab) -> Int {
        AdjustmentViewModel.Tab.allCases.firstIndex(of: tab) ?? 0
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let tabs = AdjustmentViewModel.Tab.allCases
        guard tabs.indices.contains(sender.selectedSegment) else { return }
        model.tab = tabs[sender.selectedSegment]
    }

    // MARK: - NSToolbarDelegate

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabsItem, .flexibleSpace]
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsItem, .flexibleSpace]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.tabsItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = segmented
        item.label = "表示"
        item.isNavigational = true
        return item
    }
}
