import Foundation

/// The links the Git View's `o` opens: the hosting service of a remote's git host, and the page it names. The
/// providers, patterns and templates are lazygit's (`pkg/commands/hosting_service`, v0.61.1).
public enum GitHosting {
    public enum Provider: String, CaseIterable {
        case github, gitlab, bitbucket, bitbucketServer, azuredevops, gitea, codeberg

        /// The page that creates a pull request from `branch`, the escaped upstream branch (`{{.From}}`).
        func pullRequestPage(from branch: String) -> String {
            switch self {
            case .github: return "/compare/\(branch)?expand=1"
            case .gitlab: return "/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(branch)"
            case .bitbucket: return "/pull-requests/new?source=\(branch)&t=1"
            case .bitbucketServer: return "/pull-requests?create&sourceBranch=\(branch)"
            case .azuredevops: return "/pullrequestcreate?sourceRef=\(branch)"
            case .gitea, .codeberg: return "/compare/\(branch)"
            }
        }

        /// The page of a commit, from its full hash (`{{.CommitHash}}`).
        func commitPage(_ hash: String) -> String {
            switch self {
            case .github, .azuredevops, .gitea, .codeberg: return "/commit/\(hash)"
            case .gitlab: return "/-/commit/\(hash)"
            case .bitbucket, .bitbucketServer: return "/commits/\(hash)"
            }
        }

        /// The patterns that read a remote URL, tried in order, and the repository's path on the web domain they
        /// make from their named groups.
        fileprivate var repository: (patterns: [NSRegularExpression], path: ([String: String]) -> String) {
            switch self {
            case .github, .gitlab, .gitea, .codeberg: return (Self.defaultPatterns, { "\($0["owner"]!)/\($0["repo"]!)" })
            case .bitbucket: return (Self.bitbucketPatterns, { "\($0["owner"]!)/\($0["repo"]!)" })
            case .bitbucketServer: return (Self.bitbucketServerPatterns, { "projects/\($0["project"]!)/repos/\($0["repo"]!)" })
            case .azuredevops: return (Self.azurePatterns, { "\($0["org"]!)/\($0["project"]!)/_git/\($0["repo"]!)" })
            }
        }

        private static let defaultPatterns = compile([
            #"^(?:https?|ssh)://[^/]+/(?<owner>.*)/(?<repo>.*?)(?:\.git)?$"#,
            #"^(.*?@)?.*:/*(?<owner>.*)/(?<repo>.*?)(?:\.git)?$"#,
        ])
        private static let bitbucketPatterns = compile([
            #"^(?:https?|ssh)://.*/(?<owner>.*)/(?<repo>.*?)(?:\.git)?$"#,
            #"^.*@.*:/*(?<owner>.*)/(?<repo>.*?)(?:\.git)?$"#,
        ])
        private static let bitbucketServerPatterns = compile([
            #"^ssh://git@.*/(?<project>.*)/(?<repo>.*?)(?:\.git)?$"#,
            #"^https://.*/scm/(?<project>.*)/(?<repo>.*?)(?:\.git)?$"#,
        ])
        private static let azurePatterns = compile([
            #"^.+@vs-ssh\.visualstudio\.com[:/](?:v3/)?(?<org>[^/]+)/(?<project>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$"#,
            #"^git@ssh.dev.azure.com.*/(?<org>.*)/(?<project>.*)/(?<repo>.*?)(?:\.git)?$"#,
            #"^https://.*@dev.azure.com/(?<org>.*?)/(?<project>.*?)/_git/(?<repo>.*?)(?:\.git)?$"#,
            #"^https://.*/(?<org>.*?)/(?<project>.*?)/_git/(?<repo>.*?)(?:\.git)?$"#,
        ])

        private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
            patterns.map { try! NSRegularExpression(pattern: $0) }
        }
    }

    /// A git host and the service behind it: the web domain, which may carry a `:port`, is where the pages are.
    public struct Service: Equatable {
        public var host: String
        public var provider: Provider
        public var webDomain: String

        public init(host: String, provider: Provider, webDomain: String) {
            self.host = host
            self.provider = provider
            self.webDomain = webDomain
        }
    }

    /// The hosts that need no Config. A host matches exactly, so `ssh.dev.azure.com` has its own entry, with
    /// the web domain `dev.azure.com`. Bitbucket Server has no built-in host.
    public static let builtIn = [
        Service(host: "github.com", provider: .github, webDomain: "github.com"),
        Service(host: "gitlab.com", provider: .gitlab, webDomain: "gitlab.com"),
        Service(host: "bitbucket.org", provider: .bitbucket, webDomain: "bitbucket.org"),
        Service(host: "dev.azure.com", provider: .azuredevops, webDomain: "dev.azure.com"),
        Service(host: "ssh.dev.azure.com", provider: .azuredevops, webDomain: "dev.azure.com"),
        Service(host: "try.gitea.io", provider: .gitea, webDomain: "try.gitea.io"),
        Service(host: "codeberg.org", provider: .codeberg, webDomain: "codeberg.org"),
    ]

    /// What `o` says when it opens nothing, as lazygit words it.
    public enum Failure: Error, Equatable {
        case noUpstream, noOrigin, unsupportedService, unparsableURL

        public var message: String {
            switch self {
            case .noUpstream: return "Cannot open a pull request for a branch with no upstream"
            case .noOrigin: return "There is no 'origin' remote"
            case .unsupportedService: return "Unsupported git service"
            case .unparsableURL: return "Failed to parse repo information from url"
            }
        }
    }

    /// `<provider>:<web domain>`, the format of lazygit's `services:`, for the git host `host`. A problem is
    /// the sentence for the Config problems banner.
    public static func service(host: String, value: String) -> Result<Service, ServiceProblem> {
        let allowed = Provider.allCases.map(\.rawValue).joined(separator: ", ")
        guard let colon = value.firstIndex(of: ":") else {
            return .failure(ServiceProblem(message: "git_view.services.\(host): expected <provider>:<web domain>, with a provider of \(allowed)"))
        }
        let name = value[..<colon].trimmingCharacters(in: .whitespaces)
        let web = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let provider = Provider(rawValue: name) else {
            return .failure(ServiceProblem(message: "git_view.services.\(host): unknown provider \"\(name)\", expected \(allowed)"))
        }
        guard !host.isEmpty, isWebDomain(web) else {
            return .failure(ServiceProblem(message: "git_view.services.\(host): expected a web domain, with an optional :port, after the provider"))
        }
        return .success(Service(host: host, provider: provider, webDomain: web))
    }

    public struct ServiceProblem: Error, Equatable {
        public let message: String
    }

    /// A host name with an optional `:port`.
    static func isWebDomain(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
        else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy(\.isNumber))
    }

    /// The page that creates a pull request from the upstream branch `branch` of the repository at `remoteURL`,
    /// into its default branch. `services` are tried before the built-in ones.
    public static func pullRequestURL(remoteURL: String, upstreamBranch branch: String, services: [Service]) -> Result<URL, Failure> {
        link(remoteURL: remoteURL, services: services) { $0.provider.pullRequestPage(from: queryEscape(branch)) }
    }

    /// The page of the commit `hash`, its full hash, in the repository at `remoteURL`.
    public static func commitURL(remoteURL: String, hash: String, services: [Service]) -> Result<URL, Failure> {
        link(remoteURL: remoteURL, services: services) { $0.provider.commitPage(hash) }
    }

    /// `https://<web domain>/<owner>/<repo>` and what `page` makes of the service, for the remote's URL.
    private static func link(remoteURL: String, services: [Service], page: (Service) -> String) -> Result<URL, Failure> {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = host(of: url),
              let service = (services + builtIn).first(where: { $0.host == host })
        else { return .failure(.unsupportedService) }
        guard let repository = repositoryPath(of: url, provider: service.provider),
              let link = URL(string: "https://\(service.webDomain)/\(repository)\(page(service))")
        else { return .failure(.unparsableURL) }
        return .success(link)
    }

    /// The host of a remote URL, without its user or port: `github-work` in `git@github-work:org/repo.git`.
    static func host(of url: String) -> String? {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
            rest = rest.prefix { $0 != "/" }
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            rest = rest.prefix { $0 != ":" }
        } else {
            if let at = rest.prefix(while: { $0 != ":" && $0 != "/" }).lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            rest = rest.prefix { $0 != ":" && $0 != "/" }
        }
        return rest.isEmpty ? nil : String(rest)
    }

    /// The repository's path on the web domain, by the provider's patterns. `owner` is greedy, so GitLab
    /// subgroups stay in it.
    static func repositoryPath(of url: String, provider: Provider) -> String? {
        let (patterns, path) = provider.repository
        let names = ["owner", "project", "org", "repo"]
        for pattern in patterns {
            let range = NSRange(url.startIndex..., in: url)
            guard let match = pattern.firstMatch(in: url, range: range) else { continue }
            var groups: [String: String] = [:]
            for name in names where pattern.pattern.contains("(?<\(name)>") {
                guard let found = Range(match.range(withName: name), in: url) else { continue }
                groups[name] = String(url[found])
            }
            return path(groups)
        }
        return nil
    }

    /// Go's `url.QueryEscape`: everything but letters, digits and `-_.~` is `%XX`, and a space is `+`.
    static func queryEscape(_ text: String) -> String {
        var escaped = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                escaped.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                escaped.append("+")
            default:
                escaped += String(format: "%%%02X", byte)
            }
        }
        return escaped
    }
}
