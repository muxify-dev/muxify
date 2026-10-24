import XCTest
@testable import MuxifyCore

final class GitCredentialPromptTests: XCTestCase {
    func testLazygitsPromptsAndSshsHostQuestionAreMatchedAndSecretsHidden() {
        let prompts: [(String, GitCredentialPrompt.Kind, Bool)] = [
            ("Password:", .password, true),
            ("git@example.com's password:", .password, true),
            ("Password for 'https://alice@example.com':", .password, true),
            ("Username for 'https://example.com':", .username, false),
            ("Enter passphrase for key '/Users/alice/.ssh/id_ed25519':", .passphrase, true),
            ("Enter PIN for ECDSA-SK key /Users/alice/.ssh/id_ecdsa_sk:", .pin, true),
            ("Enter PIN for 'YubiKey':", .pin, true),
            ("Enter your 2FA Token", .token, true),
            ("Are you sure you want to continue connecting (yes/no/[fingerprint])?", .hostKey, false),
            ("Are you sure you want to continue connecting (yes/no)?", .hostKey, false),
        ]
        for (line, kind, isSecret) in prompts {
            let prompt = GitCredentialPrompt.match(line + " ")
            XCTAssertEqual(prompt?.kind, kind, line)
            XCTAssertEqual(prompt?.isSecret, isSecret, line)
            XCTAssertEqual(prompt?.question, line, line)
        }
    }

    func testOtherOutputAndUnfinishedPromptsAreNotQuestions() {
        for line in ["Fetching origin", "remote: Counting objects: 100% (3/3), done.", "Password for 'https://example.com'",
                     "Enter passphrase for key", "From /tmp/origin", "fatal: Authentication failed for 'https://example.com/'",
                     "password:"] {
            XCTAssertNil(GitCredentialPrompt.match(line), line)
        }
    }

    func testAMessageLosesItsProgressEscapesAndAnsweredPrompts() {
        let output = "Fetching origin\r\n"
            + "Username for 'https://example.com': \r\n"
            + "Password for 'https://alice@example.com': remote: Invalid username or password.\r\n"
            + "remote: Enumerating objects: 5, done.\u{1B}[K\r\n"
            + "Receiving objects:  50% (1/2)\rReceiving objects: 100% (2/2), done.\r\n"
            + "Resolving deltas: 100% (1/1), done.\r\n"
            + "\r\n"
            + "fatal: Authentication failed for 'https://example.com/'\r\n"
        XCTAssertEqual(GitTerminalOutput.message(output),
                       "Fetching origin\nremote: Invalid username or password.\nremote: Enumerating objects: 5, done.\n"
                       + "fatal: Authentication failed for 'https://example.com/'")
    }

    @MainActor
    func testTheGitViewAsksASecretHiddenAndTheHostQuestionWithWhatSshSaid() {
        var answered: String?
        var cancelled = false
        let password = GitView.credentialPrompt(GitCredentialPrompt(kind: .password, question: "Password for 'https://example.com':"),
                                                answer: { answered = $0 }, cancel: { cancelled = true })
        XCTAssertTrue(password.isSecret)
        XCTAssertEqual(password.title, "Password for 'https://example.com':")
        XCTAssertTrue(password.accepts(""), "an empty answer is still an answer")
        password.submit("hunter2")
        password.onCancel?()
        XCTAssertEqual(answered, "hunter2")
        XCTAssertTrue(cancelled)
        let host = GitView.credentialPrompt(GitCredentialPrompt(kind: .hostKey, question: "Are you sure you want to continue connecting (yes/no/[fingerprint])?",
                                                                context: ["The authenticity of host 'example.com' can't be established.",
                                                                          "ED25519 key fingerprint is SHA256:abc."]),
                                            answer: { _ in }, cancel: {})
        XCTAssertFalse(host.isSecret)
        XCTAssertEqual(host.subject, .text("The authenticity of host 'example.com' can't be established.\nED25519 key fingerprint is SHA256:abc."))
        let username = GitView.credentialPrompt(GitCredentialPrompt(kind: .username, question: "Username for 'https://example.com':"),
                                                answer: { _ in }, cancel: {})
        XCTAssertFalse(username.isSecret)
    }

    func testARemoteEnvironmentsNetworkCommandGetsARemotePTY() throws {
        let directory = try TestDirectory()
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "Home", host: "home.example.ts.net", username: "user"),
                                temporaryDirectory: directory.url)
        let args = ssh.terminalScript("exec git fetch --all", arguments: ["/repo"]).arguments
        XCTAssertTrue(args.contains("-tt"))
        XCTAssertFalse(args.contains("-T"))
        XCTAssertTrue(args.contains("BatchMode=yes"), "the remote PTY still goes only over the master")
        XCTAssertTrue(args.last!.contains("exec git fetch --all"))
    }
}

final class TerminalCommandTests: XCTestCase {
    private func run(_ script: String, timeout: TimeInterval = 10, onPrompt: @escaping (GitCredentialPrompt, TerminalCommand?) -> Void = { _, _ in })
        throws -> (result: Result<String, Error>?, prompts: [GitCredentialPrompt]) {
        var prompts: [GitCredentialPrompt] = []
        var result: Result<String, Error>?
        let done = expectation(description: "the command ends")
        var command: TerminalCommand?
        command = try TerminalCommand(CommandInvocation(executable: "/bin/sh", arguments: ["-c", script]), timeout: timeout,
                                      onPrompt: { prompt in prompts.append(prompt); onPrompt(prompt, command) },
                                      completion: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 20)
        return (result, prompts)
    }

    func testAPromptOnTheTerminalIsAnsweredWithALineInTheCLocale() throws {
        let script = """
        [ -t 0 ] && [ -t 2 ] || { echo 'not a terminal' >&2; exit 3; }
        printf "Password for 'https://example.com': " > /dev/tty
        read -r answer < /dev/tty
        printf 'answer=%s locale=%s/%s/%s\\n' "$answer" "$LANG" "$LC_ALL" "$LC_MESSAGES"
        """
        let (result, prompts) = try run(script) { _, command in command?.answer("hunter2") }
        XCTAssertEqual(prompts.map(\.kind), [.password])
        XCTAssertEqual(prompts.first?.question, "Password for 'https://example.com':")
        let output = try XCTUnwrap(result).get()
        XCTAssertTrue(output.contains("answer=hunter2 locale=C/C/C"), output)
        XCTAssertFalse(output.contains("hunter2\r\nanswer"), "the terminal echoed the answer")
    }

    func testTheTimeoutWaitsWhileAPromptWaits() throws {
        let script = "printf 'Username for '\\''https://example.com'\\'': '; read -r answer; echo \"got $answer\""
        let (result, _) = try run(script, timeout: 0.5) { _, command in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { command?.answer("alice") }
        }
        XCTAssertTrue(try XCTUnwrap(result).get().contains("got alice"))
    }

    func testACommandThatRunsTooLongTimesOut() throws {
        let (result, _) = try run("sleep 10", timeout: 0.3)
        guard case .failure(TmuxError.timedOut)? = result else { return XCTFail("\(String(describing: result))") }
    }

    func testCancellingAQuestionStopsTheCommand() throws {
        let (result, _) = try run("printf 'Password: '; read -r answer; echo 'should not run'") { _, command in command?.cancel() }
        guard case .failure(TmuxError.cancelled)? = result else { return XCTFail("\(String(describing: result))") }
    }

    func testAFailureIsGitsMessageWithoutProgress() throws {
        let script = """
        printf 'Receiving objects:  50%% (1/2)\\rReceiving objects: 100%% (2/2), done.\\n' >&2
        echo 'fatal: repository not found' >&2
        exit 128
        """
        let (result, _) = try run(script)
        guard case .failure(TmuxError.failed(let status, let message))? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(status, 128)
        XCTAssertEqual(message, "fatal: repository not found")
    }
}
