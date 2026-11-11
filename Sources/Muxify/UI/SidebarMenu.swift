import AppKit
import SwiftUI

/// An item of a Sidebar context menu: its title, whether it is enabled, and what it starts.
struct SidebarMenuItem {
    let title: String
    var isEnabled = true
    var isDestructive = false
    /// The accessibility identifier of the SwiftUI Button, nil for none.
    var identifier: String?
    let perform: @MainActor () -> Void
}

/// A Sidebar context menu: groups of items, with a divider between two groups. The AppKit and the SwiftUI views read one
/// menu (ADR 0074). A SwiftUI view draws it as Buttons in `.contextMenu` and `.accessibilityActions`. The AppKit
/// Sessions list makes from it both the menu that a right-click shows and the element's named accessibility actions,
/// so a check of the actions is a check of the menu.
struct SidebarMenu {
    let groups: [[SidebarMenuItem]]

    /// A group with no item takes no divider.
    init(_ groups: [[SidebarMenuItem]]) {
        self.groups = groups.filter { !$0.isEmpty }
    }

    var items: [SidebarMenuItem] { groups.flatMap { $0 } }

    /// The menu that a right-click shows. An item that is not enabled shows and takes no click.
    @MainActor func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group { menu.addItem(SidebarMenuEntry(item)) }
        }
        return menu
    }

    /// The items as named accessibility actions, with the items' titles as their names. SwiftUI gives the Buttons of
    /// `.accessibilityActions` from the last to the first, so these come in that order too. An item that is not
    /// enabled starts nothing.
    @MainActor var accessibilityActions: [NSAccessibilityCustomAction] {
        items.reversed().map { item in
            NSAccessibilityCustomAction(name: item.title) {
                MainActor.assumeIsolated {
                    guard item.isEnabled else { return false }
                    item.perform()
                    return true
                }
            }
        }
    }
}

/// A menu item that starts its Sidebar menu item.
private final class SidebarMenuEntry: NSMenuItem {
    private let item: SidebarMenuItem

    init(_ item: SidebarMenuItem) {
        self.item = item
        super.init(title: item.title, action: #selector(start), keyEquivalent: "")
        // The menu keeps the item, and the item is its own target.
        target = self
        isEnabled = item.isEnabled
        identifier = item.identifier.map { NSUserInterfaceItemIdentifier($0) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func start() {
        MainActor.assumeIsolated { item.perform() }
    }
}

/// The items of a Sidebar menu as SwiftUI Buttons, with a Divider between two groups, for `.contextMenu` and
/// `.accessibilityActions`.
struct SidebarMenuButtons: View {
    let menu: SidebarMenu

    init(_ menu: SidebarMenu) {
        self.menu = menu
    }

    var body: some View {
        ForEach(Array(menu.groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group, id: \.title) { item in
                button(item)
            }
        }
    }

    @ViewBuilder
    private func button(_ item: SidebarMenuItem) -> some View {
        let button = Button(item.title, role: item.isDestructive ? .destructive : nil) { item.perform() }
            .disabled(!item.isEnabled)
        if let identifier = item.identifier {
            button.accessibilityIdentifier(identifier)
        } else {
            button
        }
    }
}
