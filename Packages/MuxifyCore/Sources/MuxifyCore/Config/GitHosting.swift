import Foundation

/// The links the Git View's `o` opens: the hosting service of a remote's git host, and the page it names. The
/// providers, patterns and templates are lazygit's (`pkg/commands/hosting_service`, v0.61.1).
public enum GitHosting {
    public enum Provider: String, CaseIterable {
        case github

        /// `{{.From}}`, the escaped upstream branch, goes after this.
        var pullRequestPath: String {
            switch self {
            case .github: return "/compare/"
            }
        }

        var pullRequestSuffix: String {
            switch self {
            case .github: return "?expand=1"
            }
        }

        /// The full hash goes after this.
        var commitPath: String {
            switch self {
            case .github: return "/commit/"
            }
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

    /// The hosts that need no Config. A host matches exactly, so `ssh.dev.azure.com` would need its own entry.
    public static let builtIn = [
        Service(host: "github.com", provider: .github, webDomain: "github.com"),
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
        link(remoteURL: remoteURL, services: services) { "\($0.provider.pullRequestPath)\(queryEscape(branch))\($0.provider.pullRequestSuffix)" }
    }

    /// The page of the commit `hash`, its full hash, in the repository at `remoteURL`.
    public static func commitURL(remoteURL: String, hash: String, services: [Service]) -> Result<URL, Failure> {
        link(remoteURL: remoteURL, services: services) { "\($0.provider.commitPath)\(hash)" }
    }

    /// `https://<web domain>/<owner>/<repo>` and what `page` makes of the service, for the remote's URL.
    private static func link(remoteURL: String, services: [Service], page: (Service) -> String) -> Result<URL, Failure> {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = host(of: url),
              let service = (services + builtIn).first(where: { $0.host == host })
        else { return .failure(.unsupportedService) }
        guard let repository = repositoryPath(of: url),
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

    /// `<owner>/<repo>` by lazygit's two default patterns. `owner` is greedy, so subgroups stay in it.
    static func repositoryPath(of url: String) -> String? {
        for pattern in defaultPatterns {
            let range = NSRange(url.startIndex..., in: url)
            guard let match = pattern.firstMatch(in: url, range: range),
                  let owner = Range(match.range(withName: "owner"), in: url),
                  let repo = Range(match.range(withName: "repo"), in: url)
            else { continue }
            return "\(url[owner])/\(url[repo])"
        }
        return nil
    }

    private static let defaultPatterns = [
        #"^(?:https?|ssh)://[^/]+/(?<owner>.*)/(?<repo>.*?)(?:\.git)?$"#,
        #"^(.*?@)?.*:/*(?<owner>.*)/(?<repo>.*?)(?:\.git)?$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

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
