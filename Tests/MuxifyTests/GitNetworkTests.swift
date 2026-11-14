import XCTest
@testable import MuxifyCore

/// The Git View's half of a network command: git's and ssh's questions, which come through askpass (ADR 0087), are
/// asked in Git View prompts, and ⎋ cancels the command.
@MainActor
final class GitCredentialPromptTests: XCTestCase {
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
        let host = GitView.credentialPrompt(GitCredentialPrompt(askpass: """
        The authenticity of host 'example.com' can't be established.
        ED25519 key fingerprint is SHA256:abc.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
        """), answer: { _ in }, cancel: {})
        XCTAssertFalse(host.isSecret)
        XCTAssertEqual(host.title, "Are you sure you want to continue connecting (yes/no/[fingerprint])?")
        XCTAssertEqual(host.subject, .text("The authenticity of host 'example.com' can't be established.\nED25519 key fingerprint is SHA256:abc."))
        let username = GitView.credentialPrompt(GitCredentialPrompt(askpass: "Username for 'https://example.com': "),
                                                answer: { _ in }, cancel: {})
        XCTAssertFalse(username.isSecret)
    }

    private func gitView(_ link: FakeEnvironmentLink) -> (WorkspaceStore, GitView) {
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml"), defaults: isolatedDefaults()) { _ in link }
        store.startLinkForTesting()
        let gitView = store.gitView(for: "@1")
        gitView.apply(GitSnapshot(root: "/repo", repositoryName: "repo", head: "master"))
        return (store, gitView)
    }

    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAQuestionOfAFetchIsAskedHiddenAndItsAnswerReachesTheCommand() async throws {
        let link = FakeEnvironmentLink(features: .all)
        var answers: [String?] = []
        link.gitNetworkAnswer = { network, ask in
            XCTAssertEqual(network, .fetch(root: "/repo"))
            let answer = await ask(AskRequest(prompt: "Enter passphrase for key '/k/id': ", secret: true, operation: "o"))
            answers.append(answer)
            guard answer != nil else { throw TmuxError.cancelled }
            return ""
        }
        let (store, gitView) = gitView(link)
        defer { withExtendedLifetime(store) {} }

        gitView.fetch()
        try await wait("the passphrase was not asked") { gitView.prompt != nil }
        XCTAssertEqual(gitView.prompt?.title, "Enter passphrase for key '/k/id':")
        XCTAssertTrue(gitView.prompt?.isSecret == true)
        XCTAssertEqual(gitView.networkActivity, [GitView.fetching])
        gitView.promptText = "right"
        gitView.submitPrompt()
        try await wait("the fetch did not end") { gitView.networkActivity.isEmpty }
        XCTAssertNil(gitView.writeError)

        // ⎋ cancels the command, and the banner says so.
        gitView.fetch()
        try await wait("the passphrase was not asked again") { gitView.prompt != nil }
        gitView.closePrompt()
        try await wait("the fetch did not end") { gitView.networkActivity.isEmpty }
        XCTAssertEqual(gitView.writeError, "Fetch cancelled.")
        XCTAssertEqual(answers, ["right", nil])
    }

    func testAQuestionStillOpenWhenItsCommandEndsIsClosedAndRefused() async throws {
        let link = FakeEnvironmentLink(features: .all)
        let refused = Box()
        link.gitNetworkAnswer = { _, ask in
            Task { @MainActor in refused.answer = await ask(AskRequest(prompt: "Password: ", secret: true, operation: "o")) ?? "refused" }
            try await Task.sleep(nanoseconds: 200_000_000)
            throw TmuxError.failed(status: 128, stderr: "fatal: Authentication failed")
        }
        let (store, gitView) = gitView(link)
        defer { withExtendedLifetime(store) {} }

        gitView.fetch()
        try await wait("the password was not asked") { gitView.prompt != nil }
        try await wait("the fetch did not end") { gitView.networkActivity.isEmpty }
        XCTAssertNil(gitView.prompt, "a question that nothing waits for stays open")
        XCTAssertEqual(gitView.writeError, "fatal: Authentication failed")
        try await wait("the question was never answered") { refused.answer == "refused" }
    }
}

@MainActor
private final class Box {
    var answer: String?
}
