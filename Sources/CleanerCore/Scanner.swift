import Foundation

public struct ScanItem: Codable, Sendable {
    public let path: String
    public let bytes: Int64
}

public struct RuleResult: Codable, Sendable {
    public let rule: Rule
    public let items: [ScanItem]
    /// Processes from `blockIfRunning` currently alive; `clean` skips the rule while non-empty.
    public let runningBlockers: [String]
    /// Executable of a `command` action not found in PATH.
    public let missingTool: String?
    /// Entries that could not be read (usually permissions): `bytes` is then a lower bound.
    public var unreadableEntries = 0
    /// Matching/sizing did not finish within the scan deadline (usually a pending macOS
    /// permission prompt for an external disk): not measured, never cleaned.
    public var timedOut = false

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public init(rule: Rule, items: [ScanItem], runningBlockers: [String], missingTool: String?) {
        self.rule = rule
        self.items = items
        self.runningBlockers = runningBlockers
        self.missingTool = missingTool
    }

    /// Same result with blockers re-checked now: apps may have opened since the scan.
    public func refreshingBlockers(probe: SystemProbe = LiveSystemProbe()) -> RuleResult {
        var copy = RuleResult(rule: rule, items: items,
                              runningBlockers: rule.blockIfRunning.filter(probe.isRunning), missingTool: missingTool)
        copy.unreadableEntries = unreadableEntries
        copy.timedOut = timedOut
        return copy
    }
}

/// Injected so tests do not depend on what runs on the machine.
public protocol SystemProbe {
    func isRunning(_ processName: String) -> Bool
    func hasTool(_ name: String) -> Bool
}

public struct LiveSystemProbe: SystemProbe {
    public init() {}

    public func isRunning(_ processName: String) -> Bool {
        let result = try? ProcessRunner.run(["/usr/bin/pgrep", "-x", processName])
        return result?.status == 0
    }

    public func hasTool(_ name: String) -> Bool {
        ProcessRunner.resolve(name) != nil
    }
}

public struct Scanner {
    let home: String
    let probe: SystemProbe
    let ruleDeadline: TimeInterval
    let matcher: @Sendable (Rule, String) -> [String]

    /// `ruleDeadline`: a rule whose matching+sizing does not finish in time is reported as
    /// `timedOut` and the scan moves on. Seen on a real Mac: touching an external disk from the
    /// app blocked in open() for minutes, waiting for a macOS permission prompt.
    public init(home: String = NSHomeDirectory(), probe: SystemProbe = LiveSystemProbe(),
                ruleDeadline: TimeInterval = 90,
                matcher: @escaping @Sendable (Rule, String) -> [String] = { PathExpander.matches(for: $0, home: $1) }) {
        self.home = home
        self.probe = probe
        self.ruleDeadline = ruleDeadline
        self.matcher = matcher
    }

    /// A path belongs to the first rule matching it. Later rules skip it, its descendants AND
    /// its ancestors: a generic `~/.cache/*` must neither recount nor delete `~/.cache/puppeteer`
    /// when a specific rule owns `~/.cache/puppeteer/*`.
    public func scan(_ rules: [Rule], progress: ((Rule) -> Void)? = nil) -> [RuleResult] {
        var claimed: [String] = []
        return rules.map { rule in
            progress?(rule)
            let measured = measure(rule, claimed: claimed)
            claimed += measured?.items.map(\.path) ?? []
            var missingTool: String?
            if case let .command(argv) = rule.action, !probe.hasTool(argv[0]) { missingTool = argv[0] }
            var result = RuleResult(
                rule: rule,
                items: measured?.items ?? [],
                runningBlockers: rule.blockIfRunning.filter(probe.isRunning),
                missingTool: missingTool
            )
            result.unreadableEntries = measured?.unreadable ?? 0
            result.timedOut = measured == nil
            return result
        }
    }

    /// nil when the deadline passed. The abandoned work keeps its own calculator, so a late
    /// finish cannot race with the rules that follow.
    private func measure(_ rule: Rule, claimed: [String]) -> (items: [ScanItem], unreadable: Int)? {
        final class Box: @unchecked Sendable { var value: (items: [ScanItem], unreadable: Int)? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let matcher = self.matcher
        let home = self.home
        // Dedicated thread so the deadline times the work, not the wait for a pool thread.
        Thread.detachNewThread {
            let paths = matcher(rule, home).filter { path in
                !claimed.contains {
                    SafetyGuard.isSameOrDescendant(path, of: $0) || SafetyGuard.isSameOrDescendant($0, of: path)
                }
            }
            let sizer = SizeCalculator()
            let items = paths.map { ScanItem(path: $0, bytes: sizer.allocatedSize(of: $0)) }
            box.value = (items, sizer.unreadable)
            done.signal()
        }
        return done.wait(timeout: .now() + ruleDeadline) == .success ? box.value : nil
    }
}
