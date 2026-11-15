import SwiftUI

/// What an App Window's hosting view shows.
struct AppWindowView: View {
    let id: UUID
    let store: WorkspaceStore
    let windows: AppWindows

    var body: some View {
        ContentView(store: store, configStore: windows.configStore)
            .onChange(of: store.activeEnvironment) { _, _ in windows.updateEnvironment(for: id) }
            #if DEBUG
            .overlay(alignment: .bottomTrailing) { IdleClockCost() }
            #endif
    }
}
