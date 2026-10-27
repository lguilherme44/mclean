import Foundation

public struct CleanOutcome: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case cleaned, partial, failed, skipped, wouldClean
    }

    public let ruleID: String
    public let status: Status
    public let estimatedBytes: Int64
    public let detail: String
}

public struct CleanReport: Codable, Sendable {
    public let dryRun: Bool
    public let outcomes: [CleanOutcome]
    /// Free-space delta measured by the volume after cleaning, per volume. This, not the
    /// estimate, is what the user got back: APFS clones and open files make estimates lie.
    public let measuredFreedBytes: [String: Int64]
}

/// Abstracted so tests can observe deletions without touching real data.
public protocol FileRemover {
    func remove(_ path: String) throws
}

public struct LiveFileRemover: FileRemover {
    public init() {}
    /// Already gone counts as removed: tools rotate their own files between scan and clean.
    public func remove(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

public struct Cleaner {
    let guardrail: SafetyGuard
    let remover: FileRemover
    let runCommand: ([String]) throws -> ProcessRunner.Result

    public init(
        guardrail: SafetyGuard = SafetyGuard(),
        remover: FileRemover = LiveFileRemover(),
        runCommand: @escaping ([String]) throws -> ProcessRunner.Result = { try ProcessRunner.run($0) }
    ) {
        self.guardrail = guardrail
        self.remover = remover
        self.runCommand = runCommand
    }

    /// Selection: explicit ids win; otherwise every `safe` rule, plus `review` ones if asked.
    public static func select(_ results: [RuleResult], ids: Set<String>?, includeReview: Bool) -> [RuleResult] {
        results.filter { result in
            if let ids { return ids.contains(result.rule.id) }
            return result.rule.safety == .safe || includeReview
        }
    }

    public func clean(_ selected: [RuleResult], dryRun: Bool) -> CleanReport {
        let volumes = Set(selected.flatMap { $0.items.map(\.path) }.compactMap(Self.volume(of:)))
        let before = Dictionary(uniqueKeysWithValues: volumes.compactMap { v in Self.freeBytes(v).map { (v, $0) } })
        let outcomes = selected.map { clean($0, dryRun: dryRun) }
        var measured: [String: Int64] = [:]
        if !dryRun {
            for (volume, freeBefore) in before {
                if let freeAfter = Self.freeBytes(volume) { measured[volume] = freeAfter - freeBefore }
            }
        }
        return CleanReport(dryRun: dryRun, outcomes: outcomes, measuredFreedBytes: measured)
    }

    func clean(_ result: RuleResult, dryRun: Bool) -> CleanOutcome {
        let rule = result.rule
        func outcome(_ status: CleanOutcome.Status, _ detail: String) -> CleanOutcome {
            CleanOutcome(ruleID: rule.id, status: status, estimatedBytes: result.bytes, detail: detail)
        }
        if case .report = rule.action { return outcome(.skipped, "só informativo") }
        if result.timedOut { return outcome(.skipped, "não medido: a análise passou do tempo") }
        if !result.runningBlockers.isEmpty {
            return outcome(.skipped, "feche antes: \(result.runningBlockers.joined(separator: ", "))")
        }
        if let tool = result.missingTool { return outcome(.skipped, "\(tool) não está no PATH") }

        switch rule.action {
        case .report:
            return outcome(.skipped, "só informativo")
        case let .command(argv):
            let line = argv.joined(separator: " ")
            if dryRun { return outcome(.wouldClean, "rodaria: \(line)") }
            do {
                let run = try runCommand(argv)
                let tail = run.output.split(separator: "\n").last.map(String.init) ?? ""
                return run.status == 0
                    ? outcome(.cleaned, line)
                    : outcome(.failed, "\(line) saiu com \(run.status): \(tail)")
            } catch {
                return outcome(.failed, "\(line): \(error.localizedDescription)")
            }
        case .delete:
            if result.items.isEmpty { return outcome(.skipped, "nada encontrado") }
            var removed = 0
            var problems: [String] = []
            for item in result.items {
                if case let .denied(reason) = guardrail.check(item.path) {
                    problems.append("\(item.path): bloqueado (\(reason))")
                    continue
                }
                if dryRun { removed += 1; continue }
                do {
                    try remover.remove(item.path)
                    removed += 1
                } catch {
                    problems.append("\(item.path): \((error as NSError).localizedFailureReason ?? error.localizedDescription)")
                }
            }
            let summary = "\(removed)/\(result.items.count) itens"
                + (problems.isEmpty ? "" : "; " + problems.prefix(3).joined(separator: "; "))
                + (problems.count > 3 ? " (+\(problems.count - 3))" : "")
            if dryRun { return outcome(problems.isEmpty ? .wouldClean : .partial, summary) }
            let status: CleanOutcome.Status = problems.isEmpty ? .cleaned : (removed > 0 ? .partial : .failed)
            return outcome(status, summary)
        }
    }

    public static func volume(of path: String) -> String? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey])
        return values?.volume?.path
    }

    /// Same number `df` shows as available (purgeable space excluded).
    public static func freeBytes(_ volumePath: String) -> Int64? {
        let values = try? URL(fileURLWithPath: volumePath).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
