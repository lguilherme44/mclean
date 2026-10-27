import Foundation

/// How confident we are that a rule's targets are disposable.
/// `safe` rules are selected by default; `review` rules only run when named explicitly.
public enum Safety: String, Codable, Sendable {
    case safe
    case review
}

/// What `clean` does with a rule's targets.
public enum RuleAction: Codable, Sendable, Equatable {
    /// Delete every matched path (they are regenerable caches/logs).
    case delete
    /// Run the owning tool's own cleaner; matched paths are only used to estimate size.
    case command([String])
    /// Never touched by `clean`; shown so the user knows where the space is and what to do.
    case report

    private enum CodingKeys: String, CodingKey { case type, argv }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "delete": self = .delete
        case "report": self = .report
        case "command":
            let argv = try c.decode([String].self, forKey: .argv)
            guard !argv.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .argv, in: c, debugDescription: "empty argv")
            }
            self = .command(argv)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown action \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delete: try c.encode("delete", forKey: .type)
        case .report: try c.encode("report", forKey: .type)
        case let .command(argv):
            try c.encode("command", forKey: .type)
            try c.encode(argv, forKey: .argv)
        }
    }
}

public struct Rule: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    /// Glob patterns; `~` expands to the home directory, braces are supported.
    public let paths: [String]
    /// fnmatch patterns matched against the full expanded path; matches are skipped.
    public let exclude: [String]
    public let safety: Safety
    public let action: RuleAction
    /// Only paths whose modification date is older than this many days are matched.
    public let minAgeDays: Int?
    /// Process names (`pgrep -x`) that must not be running for `clean` to touch this rule.
    public let blockIfRunning: [String]
    /// Symlink to the version in use (e.g. `~/.local/bin/claude`): the match it resolves into is
    /// kept, every other match is stale. If the link does not resolve, nothing matches.
    public let keepActiveLink: String?
    /// Keeps the N highest versions by name, compared numerically (`2.1.10` > `2.1.9`).
    public let keepNewest: Int?
    /// Keeps the N most recently modified matches (backups: never pre-select the latest one).
    public let keepMostRecent: Int?
    /// Content check applied after the glob (see `MatchFilter`).
    public let filter: MatchFilter?
    public let note: String?

    public init(
        id: String, name: String, category: String, paths: [String], exclude: [String] = [],
        safety: Safety, action: RuleAction, minAgeDays: Int? = nil, blockIfRunning: [String] = [],
        keepActiveLink: String? = nil, keepNewest: Int? = nil, keepMostRecent: Int? = nil,
        filter: MatchFilter? = nil, note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.paths = paths
        self.exclude = exclude
        self.safety = safety
        self.action = action
        self.minAgeDays = minAgeDays
        self.blockIfRunning = blockIfRunning
        self.keepActiveLink = keepActiveLink
        self.keepNewest = keepNewest
        self.keepMostRecent = keepMostRecent
        self.filter = filter
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, category, paths, exclude, safety, action, minAgeDays, blockIfRunning, keepActiveLink, keepNewest, keepMostRecent, filter, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(String.self, forKey: .category)
        paths = try c.decode([String].self, forKey: .paths)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        safety = try c.decode(Safety.self, forKey: .safety)
        action = try c.decode(RuleAction.self, forKey: .action)
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays)
        blockIfRunning = try c.decodeIfPresent([String].self, forKey: .blockIfRunning) ?? []
        keepActiveLink = try c.decodeIfPresent(String.self, forKey: .keepActiveLink)
        keepNewest = try c.decodeIfPresent(Int.self, forKey: .keepNewest)
        keepMostRecent = try c.decodeIfPresent(Int.self, forKey: .keepMostRecent)
        filter = try c.decodeIfPresent(MatchFilter.self, forKey: .filter)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

public enum RuleSetError: Error, CustomStringConvertible {
    case duplicateID(String)
    case unsafePattern(rule: String, pattern: String)

    public var description: String {
        switch self {
        case let .duplicateID(id): "regra duplicada: \(id)"
        case let .unsafePattern(rule, pattern): "regra \(rule): padrão perigoso '\(pattern)'"
        }
    }
}

public enum RuleSet {
    /// Decodes and validates rules. User rules with the same id replace built-in ones.
    public static func load(builtin: Data, user: Data? = nil) throws -> [Rule] {
        let decoder = JSONDecoder()
        var rules = try decoder.decode([Rule].self, from: builtin)
        try validate(rules)
        if let user {
            let overrides = try decoder.decode([Rule].self, from: user)
            try validate(overrides)
            let ids = Set(overrides.map(\.id))
            rules = rules.filter { !ids.contains($0.id) } + overrides
        }
        return rules
    }

    public static func loadDefault(userRulesURL: URL? = defaultUserRulesURL) throws -> [Rule] {
        let user = userRulesURL.flatMap { try? Data(contentsOf: $0) }
        return try load(builtin: Data(DefaultRules.json.utf8), user: user)
    }

    /// `MCLEAN_RULES_FILE` points at another rules file (tests and experiments without touching
    /// the real `~/.config/mclean/rules.json`).
    public static var defaultUserRulesURL: URL {
        if let override = ProcessInfo.processInfo.environment["MCLEAN_RULES_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mclean/rules.json")
    }

    static func validate(_ rules: [Rule]) throws {
        var seen = Set<String>()
        for rule in rules {
            guard seen.insert(rule.id).inserted else { throw RuleSetError.duplicateID(rule.id) }
            for (name, value) in [("keepNewest", rule.keepNewest), ("keepMostRecent", rule.keepMostRecent)] {
                if let value, value < 1 { throw RuleSetError.unsafePattern(rule: rule.id, pattern: "\(name) \(value)") }
            }
            for pattern in rule.paths where SafetyGuard.isTooBroad(pattern: pattern)
                || (rule.filter == nil && SafetyGuard.requiresFilter(pattern: pattern)) {
                throw RuleSetError.unsafePattern(rule: rule.id, pattern: pattern)
            }
        }
    }
}
