import Foundation
import MuxifyCore

@MainActor enum EnvironmentWatchCommand {
    static func run(server: TmuxServer) async throws {
        let marker = ProcessInfo.processInfo.environment["MUXIFY_REMOTE_MARKER"]
        let transport: any TmuxRunning = try marker.map { try AttachedTmuxServer(server: server, marker: $0) } ?? server
        if marker != nil { signal(SIGHUP, SIG_IGN) }
        await withCheckedContinuation { continuation in
            let watch = EnvironmentWatch(server: transport, rulesScope: .local(socketPath: server.socketPath),
                                         controlServer: server) { continuation.resume() }
            EnvironmentWatchLines.read(from: .standardInput, as: EnvironmentWatchInput.self,
                receive: { result in DispatchQueue.main.async {
                    switch result {
                    case .success(let input): watch.receive(input)
                    case .failure: watch.close()
                    }
                } }, ended: { DispatchQueue.main.async { watch.close() } })
        }
    }
}
