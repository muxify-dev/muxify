import Foundation
import Darwin

/// One pending state replaces earlier states when the pipe is slow. Replies have a finite admission limit.
final class EnvironmentWatchOutputWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private var replies: [EnvironmentWatchOutput] = []
    private var pending: EnvironmentState?
    private var forceFull = false
    private var stopped = false
    private var exited = false
    private var completion: (() -> Void)?
    private let output: FileHandle
    private let failed: () -> Void
    private var previous: EnvironmentState?

    init(output: FileHandle, failed: @escaping () -> Void) {
        self.output = output
        self.failed = failed
        DispatchQueue(label: "muxify.watch.output").async { [self] in run() }
    }

    func send(_ reply: EnvironmentWatchOutput) {
        condition.lock()
        guard !stopped, replies.count < 256 else {
            condition.unlock()
            failed()
            return
        }
        replies.append(reply)
        condition.signal()
        condition.unlock()
    }

    func publish(_ state: EnvironmentState, full: Bool = false) {
        condition.lock()
        forceFull = forceFull || full || pending != nil
        pending = state
        condition.signal()
        condition.unlock()
    }

    func finish(completion: @escaping () -> Void) {
        condition.lock()
        if exited { condition.unlock(); completion(); return }
        self.completion = completion
        stopped = true
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while replies.isEmpty && pending == nil && !stopped { condition.wait() }
            let message: EnvironmentWatchOutput
            if !replies.isEmpty {
                message = replies.removeFirst()
                if case .full(let state) = message { previous = state }
            }
            else if let state = pending {
                message = !forceFull && previous != nil ? .delta(EnvironmentStateDelta(from: previous!, to: state)) : .full(state)
                previous = state
                pending = nil
                forceFull = false
            } else {
                exited = true
                let completion = completion
                condition.unlock()
                completion?()
                return
            }
            condition.unlock()
            do {
                var data = try JSONEncoder().encode(message)
                data.append(10)
                try output.write(contentsOf: data)
            } catch {
                condition.lock()
                exited = true
                let completion = completion
                condition.unlock()
                failed()
                completion?()
                return
            }
        }
    }
}

public enum EnvironmentWatchLines {
    /// The blocking reader stays off the main actor, where Perform and viewing messages are admitted.
    public static func read<Value: Decodable>(from input: FileHandle, as: Value.Type,
                                              receive: @escaping (Result<Value, Error>) -> Void,
                                              ended: @escaping () -> Void) {
        DispatchQueue(label: "muxify.watch.input").async {
            var buffer = Data()
            do {
                var bytes = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(input.fileDescriptor, &bytes, bytes.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    buffer.append(contentsOf: bytes[..<count])
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        guard line.count <= EnvironmentWatchProtocol.maximumLineBytes else { throw EnvironmentFailure.other("Watch line is too large.") }
                        receive(Result { try JSONDecoder().decode(Value.self, from: line) })
                    }
                    guard buffer.count <= EnvironmentWatchProtocol.maximumLineBytes else { throw EnvironmentFailure.other("Watch line is too large.") }
                }
            } catch { receive(.failure(error)) }
            ended()
        }
    }
}
