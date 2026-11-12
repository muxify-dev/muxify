import AppKit
import MuxifyCore

/// The context menus of the Topics list and the named accessibility actions they give, which both versions of the list
/// read (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): the SwiftUI views draw them with
/// `SidebarMenuButtons`, and the AppKit list makes from each an `NSMenu` and the element's named actions
/// (`SidebarMenu`). Each item starts what it names; the items that ask for something open their step in the palette's
/// view (ADR 0014). An item that changes a Topic is off while a Topic change runs.
///
/// A Topic card's header gives another list than the card's menu: no Settle Topic…, no Reopen and no Start Fresh, and
/// another order. Unifying the two is a later change.
@MainActor enum TopicsListMenus {
    // MARK: Topic cards

    /// The menu of a Topic card in the Topics list, which is also the card's named actions: Go to Topic; for a Dormant
    /// Topic Reopen and Start Fresh, then Forget Topic… and Settle Topic…; Rename Topic…, Set Topic Note…, Clear Topic
    /// Note for a Topic with a Note, and Add a Session…; Pin or Unpin, Make a Guest or Bench, Move Up and Move Down.
    /// A card that is no Topic offers Go to Topic only. `steps` are what Move Up and Move Down do to the card.
    static func topicCard(_ row: TopicsModel.Row, steps: CardSteps, store: WorkspaceStore) -> SidebarMenu {
        let goTo = SidebarMenuItem(title: "Go to Topic", identifier: "go-to-topic") { store.goToTopic(row.id) }
        guard case .topic(let id) = row.id else { return SidebarMenu([[goTo]]) }
        let enabled = !store.changingTopic
        let reopen = row.state == .dormant ? [
            SidebarMenuItem(title: "Reopen", isEnabled: enabled, identifier: "reopen-topic-" + id) { store.reopenTopic(id, .reopen) },
            SidebarMenuItem(title: "Start Fresh", isEnabled: enabled, identifier: "start-fresh-topic-" + id) {
                store.reopenTopic(id, .startFresh)
            },
        ] : []
        return SidebarMenu([
            [goTo],
            reopen + [forget(id, store: store, identifier: "forget-topic"),
                      SidebarMenuItem(title: "Settle Topic…", isEnabled: enabled, identifier: "settle-topic") { store.presentSettleTopic(id) }],
            [SidebarMenuItem(title: "Rename Topic…", isEnabled: enabled, identifier: "rename-topic") { renameTopic(id, store: store) }]
                + note(row, id, store: store) + [addSession(id, store: store, identifier: "add-topic-sessionPath")],
            [pin(row, id, store: store)] + guest(.topic(id), store: store) + move(.topic(id), steps: steps, store: store),
        ])
    }

    /// The named actions of a Topic card's header in the Topics list: Go to Topic, Forget Topic…, Pin or Unpin, Make a
    /// Guest or Bench, Move Up and Move Down, Rename Topic…, the Note items and Add a Session…. A card that is no Topic
    /// offers Go to Topic only.
    static func topicHeader(_ row: TopicsModel.Row, steps: CardSteps, store: WorkspaceStore) -> SidebarMenu {
        let goTo = SidebarMenuItem(title: "Go to Topic") { store.goToTopic(row.id) }
        guard case .topic(let id) = row.id else { return SidebarMenu([[goTo]]) }
        let rename = SidebarMenuItem(title: "Rename Topic…", isEnabled: !store.changingTopic) {
            DispatchQueue.main.async { renameTopic(id, store: store) }
        }
        return SidebarMenu([[goTo, forget(id, store: store), pin(row, id, store: store)] + guest(.topic(id), store: store)
                            + move(.topic(id), steps: steps, store: store) + [rename] + note(row, id, store: store)
                            + [addSession(id, store: store)]])
    }

    /// The menu of a card in the Settled group, which is also the card's and its header's named actions: Forget Topic….
    static func settledCard(_ row: TopicsModel.Row, store: WorkspaceStore) -> SidebarMenu {
        guard case .topic(let id) = row.id else { return SidebarMenu([]) }
        return SidebarMenu([[forget(id, store: store)]])
    }

    // MARK: Locked cards

    /// The menu of a Locked card: Go to Session, then the Actions of the Locked Session (`lockedActions`).
    static func lockedCard(_ row: TopicsModel.Row, sessionID: String, steps: CardSteps, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([[goToSession(row, store: store)], lockedActions(row, sessionID: sessionID, steps: steps, store: store)])
    }

    /// The named actions of a Locked card's header, the same items as its menu.
    static func lockedHeader(_ row: TopicsModel.Row, sessionID: String, steps: CardSteps, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([[goToSession(row, store: store)] + lockedActions(row, sessionID: sessionID, steps: steps, store: store)])
    }

    // MARK: Session lines

    /// The menu of a Session line in an open Topic card: its order items (`sessionLineActions`), then the Topic
    /// membership items for the Session.
    static func sessionLine(_ order: SessionLineOrder?, window: TmuxWindow?, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([orderItems(order, store: store), window.map { TopicMembershipMenu.items(store: store, source: .session($0)) } ?? []])
    }

    /// The named actions of a Session line: Move Up, Move Down and, while the Topic keeps an order the user gave, Sort
    /// Sessions by Creation. None for a line that does not move.
    static func sessionLineActions(_ order: SessionLineOrder?, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([orderItems(order, store: store)])
    }

    // MARK: Topic rows

    /// The menu of a Window row in the Topics list: the Topic membership items for the Window.
    static func window(_ window: TmuxWindow, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([TopicMembershipMenu.items(store: store, source: .window(window))])
    }

    /// The named actions of a Window row in the Topics list: Move Window to Topic…, which is never off.
    static func windowActions(_ window: TmuxWindow, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([[TopicMembershipMenu.moveItem(store: store, source: .window(window))]])
    }

    // MARK: The items

    private static func forget(_ id: String, store: WorkspaceStore, identifier: String? = nil) -> SidebarMenuItem {
        SidebarMenuItem(title: "Forget Topic…", isEnabled: !store.changingTopic, identifier: identifier) { store.presentForgetTopic(id) }
    }

    private static func addSession(_ id: String, store: WorkspaceStore, identifier: String? = nil) -> SidebarMenuItem {
        SidebarMenuItem(title: "Add a Session…", isEnabled: !store.changingTopic, identifier: identifier) {
            store.presentAddSession(toTopic: id)
        }
    }

    /// Rename Topic… opens the Topic's title in the palette's text step.
    private static func renameTopic(_ id: String, store: WorkspaceStore) {
        guard let topic = store.topicWatcher.records.first(where: { $0.id == id }) else { return }
        store.palette.begin(.text(.renameTopic(topic)), text: topic.title ?? "")
    }

    /// Set Topic Note…, and Clear Topic Note for a Topic with a Note.
    private static func note(_ row: TopicsModel.Row, _ id: String, store: WorkspaceStore) -> [SidebarMenuItem] {
        let enabled = !store.changingTopic
        let set = SidebarMenuItem(title: "Set Topic Note…", isEnabled: enabled, identifier: "set-topic-note") {
            DispatchQueue.main.async { store.presentSetTopicNote(of: id) }
        }
        guard row.note != nil else { return [set] }
        return [set, SidebarMenuItem(title: "Clear Topic Note", isEnabled: enabled, identifier: "clear-topic-note") {
            store.setTopicNote(of: id, nil)
        }]
    }

    private static func pin(_ row: TopicsModel.Row, _ id: String, store: WorkspaceStore) -> SidebarMenuItem {
        SidebarMenuItem(title: row.isPinned ? "Unpin Topic" : "Pin Topic", isEnabled: !store.changingTopic, identifier: "pin-topic") {
            store.pinTopic(id, !row.isPinned)
        }
    }

    /// Make a Guest on a Benched Topic, Bench on an In Play Topic, while the Config sets `topics.in_play`.
    private static func guest(_ card: WorkspaceStore.GuestCard, store: WorkspaceStore) -> [SidebarMenuItem] {
        let enabled = !store.changingTopic
        var items: [SidebarMenuItem] = []
        if store.guestState(of: card) == false {
            items.append(SidebarMenuItem(title: "Make a Guest", isEnabled: enabled, identifier: "make-guest") { store.makeGuest(card) })
        }
        if store.canBench(card) {
            items.append(SidebarMenuItem(title: "Bench", isEnabled: enabled, identifier: "bench") { store.bench(card) })
        }
        return items
    }

    /// Move Up and Move Down of a Topic or Locked card: the Sidebar's own order change, which the palette does not show.
    private static func move(_ id: TopicListID, steps: CardSteps, store: WorkspaceStore) -> [SidebarMenuItem] {
        [SidebarMenuItem(title: "Move Up", isEnabled: steps.canMove(.up) && !store.changingTopic) { store.moveCard(id, .up) },
         SidebarMenuItem(title: "Move Down", isEnabled: steps.canMove(.down) && !store.changingTopic) { store.moveCard(id, .down) }]
    }

    private static func goToSession(_ row: TopicsModel.Row, store: WorkspaceStore) -> SidebarMenuItem {
        SidebarMenuItem(title: "Go to Session") { store.goToTopic(row.id) }
    }

    /// The Actions of a Locked Session. It is not a Topic, so it has no Settle, Pin or Forget. With `topics.in_play`
    /// it is a Guest, and its Unlock is Bench. Rename Session… and Kill Session… are never off.
    private static func lockedActions(_ row: TopicsModel.Row, sessionID: String, steps: CardSteps,
                                      store: WorkspaceStore) -> [SidebarMenuItem] {
        let enabled = !store.changingTopic
        var items = [SidebarMenuItem(title: row.isGuest ? "Bench" : "Unlock Session", isEnabled: enabled) {
            if row.isGuest { store.bench(.session(sessionID)) } else { store.setLock(ofSession: sessionID, false) }
        }]
        if let window = row.sessions.first?.windows.first {
            items += [
                SidebarMenuItem(title: "Rename Session…") { store.palette.begin(.text(.renameSession(window)), text: window.sessionName) },
                SidebarMenuItem(title: "Move to Topic…", isEnabled: enabled) { store.palette.openMove(window, scope: .session) },
                SidebarMenuItem(title: "New Topic from this Session", isEnabled: enabled) { store.palette.openMove(window, scope: .session) },
                SidebarMenuItem(title: "Kill Session…", isDestructive: true) {
                    store.palette.begin(.confirm(PaletteConfirmation(.killSession(window))))
                },
            ]
        }
        return items + move(.lock(sessionID: sessionID), steps: steps, store: store)
    }

    /// Move Up and Move Down of a Session within its Topic, each off at its end, and Sort Sessions by Creation while
    /// the Topic keeps an order the user gave.
    private static func orderItems(_ order: SessionLineOrder?, store: WorkspaceStore) -> [SidebarMenuItem] {
        guard let order else { return [] }
        let enabled = !store.changingTopic
        let id = order.sessionID
        var items = [SidebarMenuItem(title: "Move Up", isEnabled: order.above != nil && enabled) { store.moveSession(id, to: .up) },
                     SidebarMenuItem(title: "Move Down", isEnabled: order.below != nil && enabled) { store.moveSession(id, to: .down) }]
        if order.isManual {
            items.append(SidebarMenuItem(title: "Sort Sessions by Creation", isEnabled: enabled) {
                store.sortSessionsByCreation(ofTopic: order.topicID)
            })
        }
        return items
    }
}

/// Where a Session line of an open Topic card moves within its Topic, by Move Up, Move Down and a drag.
struct SessionLineOrder: Equatable {
    let topicID: String
    let sessionID: String
    /// The Sessions right above and below this one, where Move Up and Move Down put it.
    let above: String?
    let below: String?
    /// The Topic keeps an order the user gave, which Sort Sessions by Creation ends.
    let isManual: Bool
}

extension SessionLineOrder {
    /// Nil for a line that does not move: in a Settled Topic, in a card that is no Topic, or of a Session the card does
    /// not list.
    @MainActor init?(_ row: TopicsModel.Row, sessionID: String, store: WorkspaceStore) {
        guard row.kind == .open, case .topic(let id) = row.id else { return nil }
        let order = row.sessions.map(\.id.session)
        guard let index = order.firstIndex(of: sessionID) else { return nil }
        topicID = id
        self.sessionID = sessionID
        above = index > 0 ? order[index - 1] : nil
        below = index + 1 < order.count ? order[index + 1] : nil
        isManual = store.topicWatcher.records.first { $0.id == id }?.hasManualSessionOrder ?? false
    }
}
