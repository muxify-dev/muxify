import Foundation
import MuxifyCore

let tmux = CommandLine.arguments[1]
let socket = CommandLine.arguments[2]
var calls = 0
var bytes = 0
var lines = 0

let runner = CommandRunner()

func execute(_ arguments: [String]) throws -> String {
    calls += 1
    let output = try runner.run(CommandInvocation(executable: tmux, arguments: ["-S", socket] + arguments))
    bytes += output.utf8.count
    lines += output.filter { $0 == "\n" }.count
    return output
}

while let line = readLine() {
    do {
        let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        var result: [String: Any] = [:]
        if let arguments = request["arguments"] as? [String] {
            result["output"] = try execute(arguments)
        } else {
            var raw = ""
            let inventory = try Tmux.readSnapshot { arguments in
                let output = try execute(arguments)
                raw += output
                return output
            }
            var records: [String: Any] = [:]
            for row in raw.split(separator: "\n") {
                let fields = row.components(separatedBy: Tmux.separator)
                if fields.count > 1 {
                    let key = fields[0] == "W" && fields.count > 2
                        ? "W:\(fields[2]):\(fields[1])" : fields[0] == "C" && fields.count > 4 ? "C:\(fields[4])" : "\(fields[0]):\(fields[1])"
                    records[key] = String(row)
                }
            }
            for pane in inventory.panes {
                records["pane:\(pane.id)"] = ["id": pane.id, "window": pane.windowID,
                    "status": pane.agentStatus, "unread": pane.unread, "agent": pane.agent]
            }
            for window in inventory.windows {
                records["window:\(window.sessionID):\(window.id)"] = ["id": window.id,
                    "session": window.sessionID, "active": window.isActive]
            }
            result["state"] = records
        }
        result["calls"] = calls
        result["tmux_bytes"] = bytes
        result["tmux_lines"] = lines
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    } catch {
        let data = try! JSONSerialization.data(withJSONObject: ["error": error.localizedDescription,
            "calls": calls, "tmux_bytes": bytes, "tmux_lines": lines])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
