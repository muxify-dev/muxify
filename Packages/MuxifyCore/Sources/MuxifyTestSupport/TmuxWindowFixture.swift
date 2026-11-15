import Foundation
// TmuxWindow's memberwise initializer is internal. Only test builds link this module, and they build MuxifyCore for testing.
@testable import MuxifyCore

extension TmuxWindow {
    /// A Window for a test: the fields the test names, and a plain zsh Window of Session `$1` for the rest. The home
    /// directory and host name are TmuxWindow's own unless the test names them.
    public static func fixture(
        id: String = "@1", sessionID: String = "$1", sessionName: String = "s", index: Int = 0, name: String = "shell",
        paneTitle: String = "", path: String = "/work", command: String = "zsh", isActive: Bool = true, paneCount: Int = 1,
        hasBell: Bool = false, sessionActivity: Int = 0, agent: String = "", storedBrowser: StoredBrowser = StoredBrowser(),
        openRequests: [String] = [], homeDirectory: String? = nil, hostName: String? = nil, isRemote: Bool = false,
        sourceID: String = "", topicID: String? = nil, savedSessionID: String = "", lockOrder: Double? = nil,
        sessionPath: String = "", activePaneID: String = "", startCommand: String = "", sessionCreated: Int = 0,
        layout: String = "", isZoomed: Bool = false
    ) -> TmuxWindow {
        var window = TmuxWindow(id: id, sessionID: sessionID, sessionName: sessionName, index: index, name: name,
                                paneTitle: paneTitle, path: path, command: command, isActive: isActive, paneCount: paneCount,
                                hasBell: hasBell, sessionActivity: sessionActivity, agent: agent, storedBrowser: storedBrowser,
                                openRequests: openRequests)
        if let homeDirectory { window.homeDirectory = homeDirectory }
        if let hostName { window.hostName = hostName }
        window.isRemote = isRemote
        window.sourceID = sourceID
        window.topicID = topicID
        window.savedSessionID = savedSessionID
        window.lockOrder = lockOrder
        window.sessionPath = sessionPath
        window.activePaneID = activePaneID
        window.startCommand = startCommand
        window.sessionCreated = sessionCreated
        window.layout = layout
        window.isZoomed = isZoomed
        return window
    }
}
