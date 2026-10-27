@testable import CleanerCore
import Foundation
import Testing

/// Each test gets a throwaway fake home, so nothing here can touch real data.
final class Sandbox {
    let home: String

    init() throws {
        home = NSTemporaryDirectory() + "mclean-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: home) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 8192, age days: Double = 0) throws -> String {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: bytes))
        if days > 0 { try backdate(relative, days: days) }
        return path
    }

    func backdate(_ relative: String, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: home + "/" + relative)
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: home + "/" + relative) }
}

struct NoProcesses: SystemProbe {
    var running: Set<String> = []
    func isRunning(_ processName: String) -> Bool { running.contains(processName) }
    func hasTool(_ name: String) -> Bool { true }
}

func rule(
    _ id: String, _ paths: [String], safety: Safety = .safe, action: RuleAction = .delete,
    minAgeDays: Int? = nil, blockIfRunning: [String] = []
) -> Rule {
    Rule(id: id, name: id, category: "test", paths: paths, safety: safety, action: action,
         minAgeDays: minAgeDays, blockIfRunning: blockIfRunning)
}

@Suite struct RuleSetTests {
    @Test func builtinRulesDecodeAndAreValid() throws {
        let rules = try RuleSet.load(builtin: Data(DefaultRules.json.utf8))
        #expect(rules.count > 20)
        #expect(Set(rules.map(\.id)).count == rules.count)
    }

    @Test func userRuleReplacesBuiltinWithSameID() throws {
        let user = #"[{"id":"trash","name":"Minha lixeira","category":"x","paths":["~/.Trash/*"],"safety":"safe","action":{"type":"delete"}}]"#
        let rules = try RuleSet.load(builtin: Data(DefaultRules.json.utf8), user: Data(user.utf8))
        let trash = try #require(rules.first { $0.id == "trash" })
        #expect(trash.safety == .safe)
        #expect(rules.filter { $0.id == "trash" }.count == 1)
    }

    @Test func preferencesNeedAContentFilter() throws {
        func load(_ filter: String) throws -> [Rule] {
            try RuleSet.load(builtin: Data(#"[{"id":"p","name":"p","category":"t","paths":["~/Library/Preferences/*.plist"],"safety":"review","action":{"type":"delete"}\#(filter)}]"#.utf8))
        }
        #expect(throws: RuleSetError.self) { try load("") }
        #expect(try load(#","filter":"brokenPlist""#).count == 1)
    }

    @Test func broadPatternIsRejectedAtLoad() {
        let bad = #"[{"id":"x","name":"x","category":"x","paths":["~/Library/*"],"safety":"safe","action":{"type":"delete"}}]"#
        #expect(throws: RuleSetError.self) { try RuleSet.load(builtin: Data(bad.utf8)) }
    }

    @Test(arguments: ["~/*", "~/Library/*", "/*", "~/Documents/*", "~/Library/Application Support/*"])
    func tooBroad(pattern: String) {
        #expect(SafetyGuard.isTooBroad(pattern: pattern, home: "/Users/me"))
    }

    @Test(arguments: ["~/Library/Caches/*", "~/.Trash/*", "~/.cache/uv", "~/Library/Developer/Xcode/DerivedData/*"])
    func narrowEnough(pattern: String) {
        #expect(!SafetyGuard.isTooBroad(pattern: pattern, home: "/Users/me"))
    }
}

@Suite struct SafetyGuardTests {
    @Test func protectsRootsUserDataAndOutsidePaths() throws {
        let box = try Sandbox()
        let guardrail = SafetyGuard(home: box.home)
        #expect(guardrail.check(box.home) != .allowed)
        #expect(guardrail.check(box.home + "/Library/Caches") != .allowed)
        #expect(guardrail.check(box.home + "/Library") != .allowed)
        #expect(guardrail.check(box.home + "/Documents/tese.pdf") != .allowed)
        #expect(guardrail.check("/etc/hosts") != .allowed)
        #expect(guardrail.check(box.home + "/Library/Caches/com.foo") == .allowed)
    }

    @Test func symlinkedParentIsJudgedByItsRealLocation() throws {
        let box = try Sandbox()
        try box.file("Documents/importante.txt")
        try FileManager.default.createDirectory(atPath: box.home + "/Library/Caches", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: box.home + "/Library/Caches/atalho", withDestinationPath: box.home + "/Documents")
        let guardrail = SafetyGuard(home: box.home)
        // The link itself may go; something reached THROUGH it may not.
        #expect(guardrail.check(box.home + "/Library/Caches/atalho") == .allowed)
        #expect(guardrail.check(box.home + "/Library/Caches/atalho/importante.txt") != .allowed)
    }
}

@Suite struct ScannerTests {
    @Test func hardLinksAreCountedOnce() throws {
        let box = try Sandbox()
        let original = try box.file("store/a.bin", bytes: 1_048_576)
        try FileManager.default.linkItem(atPath: original, toPath: box.home + "/store/b.bin")
        let size = SizeCalculator().allocatedSize(of: box.home + "/store")
        #expect(size >= 1_048_576)
        #expect(size < 2 * 1_048_576)
    }

    @Test func specificRuleOwnsItsPathsAndGenericRuleSkipsAncestorsAndDescendants() throws {
        let box = try Sandbox()
        try box.file(".cache/uv/wheel.whl")
        try box.file(".cache/puppeteer/chrome/bin")
        try box.file(".cache/outro/x")
        let results = Scanner(home: box.home, probe: NoProcesses()).scan([
            rule("uv", ["~/.cache/uv"]),
            rule("puppeteer", ["~/.cache/puppeteer/*"]),
            rule("generic", ["~/.cache/*"]),
        ])
        #expect(results[0].items.map(\.path) == [box.home + "/.cache/uv"])
        #expect(results[1].items.map(\.path) == [box.home + "/.cache/puppeteer/chrome"])
        #expect(results[2].items.map(\.path) == [box.home + "/.cache/outro"])
    }

    @Test func minAgeKeepsRecentFiles() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/velho.log", age: 30)
        try box.file("Library/Logs/novo.log")
        let result = Scanner(home: box.home, probe: NoProcesses())
            .scan([rule("logs", ["~/Library/Logs/*"], minAgeDays: 7)])[0]
        #expect(result.items.map(\.path) == [box.home + "/Library/Logs/velho.log"])
    }

    @Test func excludesAreHonored() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/CloudKit/db")
        try box.file("Library/Caches/com.app/x")
        let r = Rule(id: "c", name: "c", category: "t", paths: ["~/Library/Caches/*"],
                     exclude: ["~/Library/Caches/CloudKit"], safety: .safe, action: .delete)
        let result = Scanner(home: box.home, probe: NoProcesses()).scan([r])[0]
        #expect(result.items.map(\.path) == [box.home + "/Library/Caches/com.app"])
    }
}

@Suite struct FileRemoverTests {
    /// Tools delete their own files between scan and clean (npm rotates logs): already gone is success.
    @Test func vanishedFileIsNotAFailure() throws {
        let box = try Sandbox()
        try LiveFileRemover().remove(box.home + "/sumiu.log")
    }

    @Test func otherErrorsStillSurface() throws {
        let box = try Sandbox()
        try box.file("trancado/x")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: box.home + "/trancado")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: box.home + "/trancado") }
        #expect(throws: (any Error).self) { try LiveFileRemover().remove(box.home + "/trancado/x") }
    }
}

@Suite struct StaleVersionTests {
    func versions(_ box: Sandbox, _ names: [String]) throws {
        for name in names { try box.file(".local/share/tool/versions/" + name) }
    }

    func scan(_ box: Sandbox, link: String? = nil, newest: Int? = nil) -> [String] {
        let r = Rule(id: "v", name: "v", category: "t", paths: ["~/.local/share/tool/versions/*"],
                     safety: .review, action: .delete, keepActiveLink: link, keepNewest: newest)
        return Scanner(home: box.home, probe: NoProcesses()).scan([r])[0].items
            .map { ($0.path as NSString).lastPathComponent }
    }

    @Test func versionTheLauncherPointsToIsKept() throws {
        let box = try Sandbox()
        try versions(box, ["2.1.308", "2.1.309", "2.1.310"])
        try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
        // Active version is NOT the newest: the guard follows the link, not the version order.
        try FileManager.default.createSymbolicLink(
            atPath: box.home + "/.local/bin/tool", withDestinationPath: box.home + "/.local/share/tool/versions/2.1.309")
        #expect(scan(box, link: "~/.local/bin/tool") == ["2.1.308", "2.1.310"])
    }

    @Test func missingLauncherMatchesNothing() throws {
        let box = try Sandbox()
        try versions(box, ["1.0", "2.0"])
        #expect(scan(box, link: "~/.local/bin/tool").isEmpty)
    }

    /// Backups are named by device id, not version: "most recent" must come from the date.
    @Test func mostRecentByDateIsKept() throws {
        let box = try Sandbox()
        try box.file(".local/share/tool/versions/zzz-velho", age: 90)
        try box.file(".local/share/tool/versions/aaa-recente", age: 2)
        try box.file(".local/share/tool/versions/mmm-medio", age: 30)
        let r = Rule(id: "v", name: "v", category: "t", paths: ["~/.local/share/tool/versions/*"],
                     safety: .review, action: .delete, keepMostRecent: 1)
        let names = Scanner(home: box.home, probe: NoProcesses()).scan([r])[0].items
            .map { ($0.path as NSString).lastPathComponent }
        #expect(names == ["mmm-medio", "zzz-velho"])
    }

    @Test func newestIsComparedNumerically() throws {
        let box = try Sandbox()
        try versions(box, ["2.1.9", "2.1.10", "2.1.8"])
        #expect(scan(box, newest: 1) == ["2.1.8", "2.1.9"])
    }
}

@Suite struct CleanerTests {
    func scan(_ box: Sandbox, _ rules: [Rule], running: Set<String> = []) -> [RuleResult] {
        Scanner(home: box.home, probe: NoProcesses(running: running)).scan(rules)
    }

    @Test func dryRunDeletesNothing() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/app/blob")
        let results = scan(box, [rule("caches", ["~/Library/Caches/*"])])
        let report = Cleaner(guardrail: SafetyGuard(home: box.home)).clean(results, dryRun: true)
        #expect(report.outcomes[0].status == .wouldClean)
        #expect(box.exists("Library/Caches/app/blob"))
    }

    @Test func realRunDeletesMatchesAndKeepsTheParent() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/app/blob")
        let results = scan(box, [rule("caches", ["~/Library/Caches/*"])])
        let report = Cleaner(guardrail: SafetyGuard(home: box.home)).clean(results, dryRun: false)
        #expect(report.outcomes[0].status == .cleaned)
        #expect(!box.exists("Library/Caches/app"))
        #expect(box.exists("Library/Caches"))
    }

    @Test func runningBlockerSkipsTheRule() throws {
        let box = try Sandbox()
        try box.file("Library/Developer/Xcode/DerivedData/Proj/x")
        let results = scan(box, [rule("dd", ["~/Library/Developer/Xcode/DerivedData/*"], blockIfRunning: ["Xcode"])],
                           running: ["Xcode"])
        let report = Cleaner(guardrail: SafetyGuard(home: box.home)).clean(results, dryRun: false)
        #expect(report.outcomes[0].status == .skipped)
        #expect(box.exists("Library/Developer/Xcode/DerivedData/Proj/x"))
    }

    @Test func guardBlocksEvenWhenARuleSaysDelete() throws {
        let box = try Sandbox()
        let precious = try box.file("Documents/tese.pdf")
        let forged = RuleResult(rule: rule("forged", []), items: [ScanItem(path: precious, bytes: 1)],
                                runningBlockers: [], missingTool: nil)
        let report = Cleaner(guardrail: SafetyGuard(home: box.home)).clean([forged], dryRun: false)
        #expect(report.outcomes[0].status == .failed)
        #expect(box.exists("Documents/tese.pdf"))
    }

    @Test func reportRulesAreNeverExecuted() throws {
        let box = try Sandbox()
        try box.file("big.raw")
        let results = scan(box, [rule("docker", ["~/big.raw"], action: .report)])
        let report = Cleaner(guardrail: SafetyGuard(home: box.home)).clean(results, dryRun: false)
        #expect(report.outcomes[0].status == .skipped)
        #expect(box.exists("big.raw"))
    }

    @Test func commandFailureIsReportedNotHidden() throws {
        let box = try Sandbox()
        let results = scan(box, [rule("tool", [], action: .command(["false"]))])
        let cleaner = Cleaner(guardrail: SafetyGuard(home: box.home)) { _ in
            ProcessRunner.Result(status: 3, output: "boom")
        }
        let outcome = cleaner.clean(results, dryRun: false).outcomes[0]
        #expect(outcome.status == .failed)
        #expect(outcome.detail.contains("boom"))
    }

    @Test func selectionDefaultsToSafeOnly() throws {
        let box = try Sandbox()
        let results = scan(box, [rule("a", []), rule("b", [], safety: .review)])
        #expect(Cleaner.select(results, ids: nil, includeReview: false).map(\.rule.id) == ["a"])
        #expect(Cleaner.select(results, ids: nil, includeReview: true).map(\.rule.id) == ["a", "b"])
        #expect(Cleaner.select(results, ids: ["b"], includeReview: false).map(\.rule.id) == ["b"])
    }
}

@Suite struct NodeModulesFinderTests {
    @Test func findsOnlyTopLevelNodeModulesOfIdleProjects() throws {
        let box = try Sandbox()
        try box.file("parado/package.json", age: 60)
        try box.file("parado/node_modules/lodash/node_modules/x/index.js")
        try box.file("ativo/package.json")
        try box.file("ativo/node_modules/react/index.js")
        let found = NodeModulesFinder.find(roots: [box.home], idleDays: 14)
        #expect(found.map(\.path) == [box.home + "/parado/node_modules"])
    }
}

@Suite struct UnreadableTests {
    @Test func unreadableDirectoryIsFlaggedInsteadOfLookingEmpty() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/locked/inner/blob")
        let locked = box.home + "/Library/Caches/locked/inner"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let result = Scanner(home: box.home, probe: NoProcesses()).scan([rule("c", ["~/Library/Caches/*"])])[0]
        #expect(result.unreadableEntries > 0)
    }
}

@Suite struct SpaceLensTests {
    @Test func futureTimestampsDoNotMakeAFolderLookActive() throws {
        let box = try Sandbox()
        try box.file("velho/antigo.bin", age: 300)
        try box.file("velho/relogio-errado.bin")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3 * 86_400)], ofItemAtPath: box.home + "/velho/relogio-errado.bin")
        let root = try #require(SpaceLens.scan(root: box.home, depth: 1))
        let velho = try #require(root.children.first { $0.name == "velho" })
        let days = Date().timeIntervalSince(velho.lastModified ?? .distantPast) / 86_400
        #expect((299...301).contains(days))
    }

    @Test func folderDateIsTheNewestFileInsideEvenBelowKeptDepth() throws {
        let box = try Sandbox()
        try box.file("velho/a/b/c/antigo.bin", age: 400)
        try box.file("velho/a/b/c/menos-antigo.bin", age: 200)
        try box.file("ativo/x.bin")
        // Directory mtimes are "now" (just created): they must not leak into the folder date.
        let root = try #require(SpaceLens.scan(root: box.home, depth: 1))
        let velho = try #require(root.children.first { $0.name == "velho" })
        let ativo = try #require(root.children.first { $0.name == "ativo" })
        let days = { (node: SpaceNode) in Date().timeIntervalSince(node.lastModified ?? .distantPast) / 86_400 }
        #expect((199...201).contains(days(velho)))
        #expect(days(ativo) < 1)
        #expect(root.lastModified == ativo.lastModified)
    }

    @Test func aggregatesSizesAndKeepsNodesOnlyToDepth() throws {
        let box = try Sandbox()
        try box.file("a/big.bin", bytes: 1_048_576)
        try box.file("a/deep/deeper/x.bin", bytes: 524_288)
        try box.file("b/small.bin", bytes: 4096)
        let root = try #require(SpaceLens.scan(root: box.home, depth: 2))
        #expect(root.children.map(\.name) == ["a", "b"])
        let a = root.children[0]
        #expect(a.bytes >= 1_048_576 + 524_288)
        let deep = try #require(a.children.first { $0.name == "deep" })
        // Level 3 ("deeper") is beyond depth 2: not kept, but its bytes are in "deep".
        #expect(deep.children.isEmpty)
        #expect(deep.isTruncated)
        #expect(deep.bytes >= 524_288)
        #expect(root.bytes >= a.bytes + root.children[1].bytes)
    }

    @Test func hardLinksCountOnce() throws {
        let box = try Sandbox()
        let original = try box.file("x/a.bin", bytes: 1_048_576)
        try FileManager.default.linkItem(atPath: original, toPath: box.home + "/x/b.bin")
        let root = try #require(SpaceLens.scan(root: box.home + "/x", depth: 1))
        #expect(root.bytes < 2 * 1_048_576)
    }

    @Test func cancellationStopsTheScan() throws {
        let box = try Sandbox()
        try box.file("a/b.bin")
        #expect(SpaceLens.scan(root: box.home, isCancelled: { true }) == nil)
    }

    @Test func trashGuardAllowsUserFilesButNotStructureOrCredentials() throws {
        let box = try Sandbox()
        let guardrail = SafetyGuard(home: box.home)
        #expect(guardrail.checkTrash(box.home + "/Downloads/video.mov") == .allowed)
        #expect(guardrail.checkTrash(box.home + "/Downloads") != .allowed)
        #expect(guardrail.checkTrash(box.home + "/Library") != .allowed)
        #expect(guardrail.checkTrash(box.home + "/.ssh/id_ed25519") != .allowed)
        #expect(guardrail.checkTrash("/Applications/Foo.app") != .allowed)
    }
}

@Suite struct SpaceLensUnreadableTests {
    /// Home has TCC-protected folders; fts reports them as FTS_DNR instead of FTS_DP.
    @Test func unreadableSubdirectoryDoesNotBreakTheTree() throws {
        let box = try Sandbox()
        try box.file("ok/a.bin", bytes: 65_536)
        try box.file("locked/b.bin")
        let locked = box.home + "/locked"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let root = try #require(SpaceLens.scan(root: box.home, depth: 2))
        #expect(root.path.hasSuffix(box.home.split(separator: "/").last.map(String.init) ?? ""))
        #expect(root.children.contains { $0.name == "ok" })
        #expect(root.bytes >= 65_536)
    }
}

@Suite struct NodeModulesGitActivityTests {
    func git(_ args: [String], in dir: String) throws {
        let result = try ProcessRunner.run(["/usr/bin/git", "-C", dir] + args)
        #expect(result.status == 0, "\(args): \(result.output)")
    }

    func repo(_ box: Sandbox, _ name: String, idleDays: Double) throws {
        let dir = box.home + "/" + name
        try box.file("\(name)/package.json")
        try box.file("\(name)/node_modules/x/index.js", bytes: 2_000_000)
        try git(["init", "-q"], in: dir)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"], in: dir)
        if idleDays > 0 {
            try box.backdate("\(name)/.git/logs/HEAD", days: idleDays)
            try box.backdate("\(name)/package.json", days: idleDays)
        }
    }

    @Test func usesGitActivityAndIgnoresBuildOutputAndTinyWorkspaceLinks() throws {
        let box = try Sandbox()
        try repo(box, "parado", idleDays: 60)
        try repo(box, "ativo", idleDays: 0)
        // Build output inside an idle project: not a project of its own.
        try box.file("parado/.output/server/node_modules/y/index.js")
        let found = NodeModulesFinder.discover(roots: [box.home], idleDays: 14).map(\.path)
        #expect(found == [box.home + "/parado/node_modules"])
    }

    @Test func gitWorktreeFileIsFollowed() throws {
        let box = try Sandbox()
        try repo(box, "main", idleDays: 0)
        try git(["worktree", "add", "-q", box.home + "/wt", "-b", "wt"], in: box.home + "/main")
        try box.file("wt/package.json", age: 60)
        try box.file("wt/node_modules/z/index.js")
        // The worktree's gitdir lives in main/.git/worktrees/wt; backdate its HEAD log.
        try box.backdate("main/.git/worktrees/wt/logs/HEAD", days: 60)
        let found = NodeModulesFinder.discover(roots: [box.home + "/wt"], idleDays: 14).map(\.path)
        #expect(found == [box.home + "/wt/node_modules"])
    }
}

@Suite struct TreemapTests {
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 300)

    func node(_ name: String, _ bytes: Int64) -> SpaceNode {
        SpaceNode(path: "/r/" + name, isDirectory: true, bytes: bytes, children: [], isTruncated: false)
    }

    @Test(arguments: [[6.0, 6, 4, 3, 2, 2, 1], [1.0], [100, 1, 1, 1], [5, 5, 5, 5, 5, 5, 5, 5, 5]])
    func tilesFillTheBoundsWithoutOverlapAndKeepProportions(_ values: [Double]) {
        let rects = Treemap.squarify(values, in: bounds)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            let expected = Double(bounds.width * bounds.height) * value / total
            #expect(abs(Double(rect.width * rect.height) - expected) < 0.5)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func tilesStayCloseToSquare() {
        let rects = Treemap.squarify([6, 6, 4, 3, 2, 2, 1], in: bounds)
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 3)
    }

    @Test func longTailFoldsIntoOneOtherTile() {
        let children = [node("a", 900), node("b", 80)] + (0..<20).map { node("t\($0)", 1) }
        let entries = Treemap.layout(children, in: bounds)
        #expect(entries.map(\.tile) == [.node(path: "/r/a"), .node(path: "/r/b"), .other(count: 20)])
        #expect(entries.last?.bytes == 20)
    }

    @Test func singleLeftoverKeepsItsName() {
        let entries = Treemap.layout([node("a", 990), node("b", 5)], in: bounds)
        #expect(entries.map(\.tile) == [.node(path: "/r/a"), .node(path: "/r/b")])
    }

    @Test func ageBandsHaveTheDocumentedEdges() {
        let now = Date()
        let ago = { (days: Double) in now.addingTimeInterval(-days * 86_400) }
        #expect(AgeBand(lastModified: ago(29), now: now) == .underMonth)
        #expect(AgeBand(lastModified: ago(31), now: now) == .months1to6)
        #expect(AgeBand(lastModified: ago(200), now: now) == .months6to12)
        #expect(AgeBand(lastModified: ago(400), now: now) == .years1to2)
        #expect(AgeBand(lastModified: ago(800), now: now) == .over2Years)
    }
}

@Suite struct ProcessRunnerTests {
    /// pnpm picks the store of the cwd's VOLUME: run from the SSD, `pnpm store prune` would prune
    /// the SSD store instead of ~/Library/pnpm. Rule commands must not depend on where mclean ran.
    @Test func commandsRunFromHomeNotFromTheCallersDirectory() throws {
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(NSTemporaryDirectory())
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        let result = try ProcessRunner.run(["/bin/pwd"])
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == SafetyGuard.canonical(NSHomeDirectory()))
    }
}

@Suite struct DeletionPlannerTests {
    func node(_ box: Sandbox, _ relative: String, _ bytes: Int64) -> SpaceNode {
        SpaceNode(path: box.home + "/" + relative, isDirectory: true, bytes: bytes, children: [], isTruncated: false)
    }

    @Test func nestedSelectionsCollapseIntoTheOutermostFolder() throws {
        let box = try Sandbox()
        let plan = DeletionPlanner.plan(
            [node(box, "proj/build/cache", 10), node(box, "proj", 100), node(box, "proj/build", 50),
             node(box, "projeto-irmao", 7), node(box, "proj", 100)],
            guardrail: SafetyGuard(home: box.home))
        // "projeto-irmao" shares a string prefix with "proj" but is NOT inside it.
        #expect(plan.units.map(\.path) == [box.home + "/proj", box.home + "/projeto-irmao"])
        #expect(plan.totalBytes == 107)
        let unchecked = plan.excluding([box.home + "/proj"])
        #expect(unchecked.units.map(\.path) == [box.home + "/projeto-irmao"])
        #expect(unchecked.totalBytes == 7)
    }

    @Test func guardedItemsAreListedWithTheReasonNotSilentlyDropped() throws {
        let box = try Sandbox()
        let plan = DeletionPlanner.plan([node(box, ".ssh", 5), node(box, "Downloads/x", 9)],
                                        guardrail: SafetyGuard(home: box.home))
        #expect(plan.units.map(\.path) == [box.home + "/Downloads/x"])
        #expect(plan.blocked.map(\.unit.path) == [box.home + "/.ssh"])
        #expect(plan.blocked.first?.reason.isEmpty == false)
        #expect(plan.totalBytes == 9)
    }

    @Test func oneFailureDoesNotStopTheRest() throws {
        let box = try Sandbox()
        let plan = DeletionPlanner.plan([node(box, "a", 3), node(box, "b", 2), node(box, "c", 1)],
                                        guardrail: SafetyGuard(home: box.home))
        var trashed: [String] = []
        let outcomes = DeletionPlanner.execute(plan) { path in
            if path.hasSuffix("/b") { throw CocoaError(.fileWriteNoPermission) }
            trashed.append(path)
        }
        #expect(trashed == [box.home + "/a", box.home + "/c"])
        #expect(outcomes.filter { $0.error != nil }.map(\.unit.path) == [box.home + "/b"])
    }
}

@Suite struct DiskBreakdownTests {
    @Test func segmentsAddUpToTheTotal() {
        let b = DiskBreakdown(total: 100, free: 10, purgeable: 5, selected: 20)
        #expect(b.otherUsed == 65)
        #expect(b.selected == 20)
        #expect(b.otherUsed + b.selected + b.purgeable + b.free == 100)
        #expect(b.freeAfterRemoval == 30)
    }

    /// A selection can never claim more than what is in use (stale sizes, other volume rounding).
    @Test func selectionIsClampedToUsedSpace() {
        let b = DiskBreakdown(total: 100, free: 60, purgeable: 30, selected: 50)
        #expect(b.selected == 10)
        #expect(b.otherUsed == 0)
        #expect(b.otherUsed + b.selected + b.purgeable + b.free == 100)
    }
}

@Suite struct HistoryTests {
    let gb: Int64 = 1_000_000_000
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }

    /// 1 GB/day consumed for 10 days, starting at 30 GB free.
    func steady(_ history: inout History) {
        for n in 0...10 {
            history.record(History.Sample(date: day(Double(n)), freeBytes: 30 * gb - Int64(n) * gb, totalBytes: 245 * gb))
        }
    }

    @Test func steadyConsumptionPredictsWhenTheDiskFills() throws {
        var history = History()
        steady(&history)
        let forecast = try #require(Forecast.make(history, now: day(10)))
        #expect(abs(forecast.bytesPerDay + Double(gb)) < Double(gb) * 0.01)
        #expect(abs((forecast.daysUntilFull ?? 0) - 20) < 0.5)
    }

    @Test func recordedCleanupIsNotMistakenForAReversedTrend() throws {
        var history = History()
        for n in 0...10 {
            let freed: Int64 = n >= 5 ? 10 * gb : 0
            history.record(History.Sample(date: day(Double(n)), freeBytes: 30 * gb - Int64(n) * gb + freed, totalBytes: 245 * gb))
        }
        history.record(History.Cleanup(date: day(4.5), source: "Limpeza", freedBytes: 10 * gb, items: ["npm-cache"]))
        let forecast = try #require(Forecast.make(history, now: day(10)))
        #expect(abs(forecast.bytesPerDay + Double(gb)) < Double(gb) * 0.01)
    }

    /// Cleaning most days makes jumps the MAJORITY of daily changes: only the correction by the
    /// recorded cleanups keeps the real 1 GB/day consumption visible.
    @Test func frequentCleanupsStillShowTheRealConsumption() throws {
        var history = History()
        var freed: Int64 = 0
        for n in 0...5 {
            if [1, 2, 4].contains(n) {
                freed += 3 * gb
                history.record(History.Cleanup(date: day(Double(n) - 0.5), source: "Limpeza", freedBytes: 3 * gb, items: []))
            }
            history.record(History.Sample(date: day(Double(n)), freeBytes: 30 * gb - Int64(n) * gb + freed, totalBytes: 245 * gb))
        }
        let forecast = try #require(Forecast.make(history, now: day(5)))
        #expect(abs(forecast.bytesPerDay + Double(gb)) < Double(gb) * 0.01)
    }

    /// Emptying the Trash or deleting in Finder leaves an unexplained jump: one jump must not flip the trend.
    @Test func unrecordedJumpBarelyMovesTheRate() throws {
        var history = History()
        for n in 0...12 {
            let jump: Int64 = n >= 6 ? 8 * gb : 0
            history.record(History.Sample(date: day(Double(n)), freeBytes: 30 * gb - Int64(n) * gb + jump, totalBytes: 245 * gb))
        }
        let forecast = try #require(Forecast.make(history, now: day(12)))
        #expect(forecast.bytesPerDay < -0.8 * Double(gb))
    }

    @Test func tooLittleDataGivesNoForecast() {
        var history = History()
        history.record(History.Sample(date: day(0), freeBytes: 10 * gb, totalBytes: 245 * gb))
        history.record(History.Sample(date: day(0.5), freeBytes: 9 * gb, totalBytes: 245 * gb))
        #expect(Forecast.make(history, now: day(0.5)) == nil)
    }

    @Test func samplesCloserThanTheIntervalReplaceEachOther() {
        var history = History()
        history.record(History.Sample(date: start, freeBytes: 10, totalBytes: 100))
        history.record(History.Sample(date: start.addingTimeInterval(600), freeBytes: 12, totalBytes: 100))
        history.record(History.Sample(date: start.addingTimeInterval(7_200), freeBytes: 13, totalBytes: 100))
        #expect(history.samples.map(\.freeBytes) == [12, 13])
    }

    @Test func storeRoundTripsAndSurvivesACorruptFile() throws {
        let box = try Sandbox()
        let store = HistoryStore(url: URL(fileURLWithPath: box.home + "/h/history.json"))
        var history = History()
        steady(&history)
        try store.save(history)
        #expect(store.load() == history)
        try Data("{ quebrado".utf8).write(to: store.url)
        #expect(store.load() == History())
        // The unreadable file is kept aside, not overwritten with an empty history.
        #expect(FileManager.default.fileExists(atPath: box.home + "/h/history.json.corrompido"))
    }
}

@Suite struct MatchFilterTests {
    func scan(_ box: Sandbox, _ pattern: String, _ filter: MatchFilter) -> [String] {
        let r = Rule(id: "f", name: "f", category: "t", paths: [pattern], safety: .review, action: .delete, filter: filter)
        return Scanner(home: box.home, probe: NoProcesses()).scan([r])[0].items.map { ($0.path as NSString).lastPathComponent }
    }

    @Test func onlyReadableButUnparseablePlistsAreBroken() throws {
        let box = try Sandbox()
        let prefs = box.home + "/Library/Preferences/"
        try box.file("Library/Preferences/quebrado.plist")  // 8 KB of 0x07: not a plist
        try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: prefs + "bom-binario.plist"))
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)
            .write(to: URL(fileURLWithPath: prefs + "bom-xml.plist"))
        // Protected (TCC/permissions) is NOT broken: deleting it would wipe a working app's settings.
        try box.file("Library/Preferences/protegido.plist")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: prefs + "protegido.plist")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prefs + "protegido.plist") }
        #expect(scan(box, "~/Library/Preferences/*.plist", .brokenPlist) == ["quebrado.plist"])
    }

    /// Found on this Mac: opening com.apple.Music.plist blocks in open() waiting for a TCC
    /// (media library) prompt and hung the whole scan. A FIFO blocks open() the same way.
    @Test func aFileWhoseOpenBlocksDoesNotHangTheScan() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(atPath: box.home + "/Library/Preferences", withIntermediateDirectories: true)
        #expect(mkfifo(box.home + "/Library/Preferences/bloqueia.plist", 0o600) == 0)
        try box.file("Library/Preferences/quebrado.plist")
        let started = Date()
        #expect(scan(box, "~/Library/Preferences/*.plist", .brokenPlist) == ["quebrado.plist"])
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func applePreferencesAreNeverJudged() throws {
        let box = try Sandbox()
        try box.file("Library/Preferences/com.apple.Music.plist")   // garbage content, but Apple's
        #expect(scan(box, "~/Library/Preferences/*.plist", .brokenPlist).isEmpty)
    }

    @Test func launchAgentIsBrokenOnlyWhenItsAbsoluteProgramIsGone() throws {
        let box = try Sandbox()
        let agents = box.home + "/Library/LaunchAgents/"
        try FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        func agent(_ name: String, _ plist: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: agents + name))
        }
        try agent("orfao.plist", ["Label": "o", "ProgramArguments": ["/Applications/Sumiu.app/Contents/MacOS/x", "-d"]])
        try agent("ok.plist", ["Label": "k", "Program": "/bin/ls"])
        // Resolved through PATH at launch: we cannot tell it is gone.
        try agent("path.plist", ["Label": "p", "ProgramArguments": ["node", "x.js"]])
        // Lives on a volume that is just not mounted now: not broken.
        try agent("externo.plist", ["Label": "e", "Program": "/Volumes/NaoMontado/bin/tool"])
        #expect(scan(box, "~/Library/LaunchAgents/*.plist", .missingProgram) == ["orfao.plist"])
    }
}

@Suite struct UninstallerTests {
    let app = InstalledApp(path: "/Applications/Super Notes.app", bundleID: "com.acme.supernotes", name: "Super Notes", version: "2.1")

    @Test(arguments: [
        ("Super Notes", true), ("super-notes", true), ("SuperNotes Data", false), ("Super Notes Helper", true),
        ("Notes", false), ("Super", false), ("Super Notes 3", false), ("Super Notes 2.0.1", false),
    ])
    func nameMatchNeedsEveryWordAndIgnoresOtherVersions(_ resource: String, _ expected: Bool) {
        #expect(LeftoverFinder.nameMatches(resource: resource, appName: app.name) == expected)
    }

    @Test func findsLeftoversByIdByNameAndByLaunchAgent() throws {
        let box = try Sandbox()
        let lib = "Library/"
        try box.file(lib + "Application Support/com.acme.supernotes/db.sqlite")
        try box.file(lib + "Application Support/Super Notes/cache.bin")
        try box.file(lib + "Application Support/Notes/outro-app.bin")            // shares one word: not ours
        try box.file(lib + "Caches/com.acme.supernotes/x")
        try box.file(lib + "Containers/com.acme.supernotes.share-extension/Data/x") // extension of the app
        try box.file(lib + "Group Containers/ABCDE12345.com.acme.supernotes/x")
        try box.file(lib + "Preferences/com.acme.supernotes.plist")
        try box.file(lib + "Preferences/com.acme.supernotesbeta.plist")             // other bundle id
        try box.file(lib + "Saved Application State/com.acme.supernotes.savedState/w")
        try box.file(lib + "HTTPStorages/com.acme.supernotes.binarycookies")
        try FileManager.default.createDirectory(atPath: box.home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.acme.updater", "AssociatedBundleIdentifiers": ["com.acme.supernotes"]],
                                           format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: box.home + "/Library/LaunchAgents/com.acme.updater.plist"))

        let found = LeftoverFinder(home: box.home).leftovers(of: app)
        let byPath = Dictionary(uniqueKeysWithValues: found.map { (String($0.path.dropFirst(box.home.count + 1)), $0.match) })
        #expect(byPath == [
            "Library/Application Support/com.acme.supernotes": .bundleID,
            "Library/Application Support/Super Notes": .name,
            "Library/Caches/com.acme.supernotes": .bundleID,
            "Library/Containers/com.acme.supernotes.share-extension": .bundleID,
            "Library/Group Containers/ABCDE12345.com.acme.supernotes": .bundleID,
            "Library/Preferences/com.acme.supernotes.plist": .bundleID,
            "Library/Saved Application State/com.acme.supernotes.savedState": .bundleID,
            "Library/HTTPStorages/com.acme.supernotes.binarycookies": .bundleID,
            "Library/LaunchAgents/com.acme.updater.plist": .launchAgent,
        ])
    }

    /// Found on a real Mac: uninstalling an app with a short name suggested the folder of ANOTHER
    /// installed app whose name contains that word. The more specific installed name wins.
    @Test func nameMatchOwnedByAMoreSpecificInstalledAppIsSkipped() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/Toolbox/x")
        try box.file("Library/Application Support/Cleaner_5_Toolbox/x")
        let toolbox = InstalledApp(path: "/Applications/Toolbox.app", bundleID: "com.x.toolbox", name: "Toolbox", version: nil)
        let cleaner = InstalledApp(path: "/Applications/Toolbox/Cleaner.app", bundleID: "com.y.cleaner", name: "Cleaner_5_Toolbox", version: nil)
        let found = LeftoverFinder(home: box.home).leftovers(of: toolbox, installed: [toolbox, cleaner]).map { ($0.path as NSString).lastPathComponent }
        #expect(found == ["Toolbox"])
        let forCleaner = LeftoverFinder(home: box.home).leftovers(of: cleaner, installed: [toolbox, cleaner]).map { ($0.path as NSString).lastPathComponent }
        #expect(forCleaner == ["Cleaner_5_Toolbox"])
    }

    @Test func appleAppsAndShortNamesAreNotMatchedByName() {
        #expect(LeftoverFinder.nameMatches(resource: "Arc", appName: "Arc") == false)
        let apple = InstalledApp(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", name: "Safari", version: nil)
        #expect(apple.isApple)
    }
}

@Suite struct UninstallPlannerTests {
    @Test func planHasTheAppAndItsLeftoversAndBlocksWhatTheGuardsRefuse() throws {
        let box = try Sandbox()
        let app = InstalledApp(path: box.home + "/Applications/Foo.app", bundleID: "com.x.foo", name: "Foo Bar", version: nil)
        let leftovers = [Leftover(path: box.home + "/Library/Caches/com.x.foo", match: .bundleID),
                         Leftover(path: box.home + "/.ssh/foo", match: .name)]
        let plan = UninstallPlanner.plan(app: app, leftovers: leftovers, appFolders: [box.home + "/Applications"],
                                         guardrail: SafetyGuard(home: box.home), size: { _ in 10 })
        #expect(plan.units.map(\.path) == [app.path, box.home + "/Library/Caches/com.x.foo"])
        #expect(plan.blocked.map(\.unit.path) == [box.home + "/.ssh/foo"])
    }

    @Test(arguments: [
        ("/Applications/Safari.app", "com.apple.Safari"),         // Apple
        ("/System/Applications/Notes.app", "com.foo.notes"),      // outside the app folders
        ("/Applications", "com.foo.bar"),                         // the folder itself
        ("/Applications/Foo.app/Contents", "com.foo.bar"),        // not a bundle
        ("/Applications/Xcode.app/Nested.app", "com.foo.nested"), // bundle inside another bundle
    ])
    func appGuardOnlyAllowsThirdPartyBundlesInAppFolders(_ path: String, _ id: String) {
        let app = InstalledApp(path: path, bundleID: id, name: "X", version: nil)
        let plan = UninstallPlanner.plan(app: app, leftovers: [], appFolders: ["/Applications"], size: { _ in 1 })
        #expect(plan.units.isEmpty)
        #expect(plan.blocked.count == 1)
    }
}

@Suite struct AppActivityTests {
    /// Spotlight has no "last used" for many apps (Docker, Cursor here): the data folders the app
    /// writes while running are the fallback. Name matches do not count (they may be someone else's).
    @Test func activityIsTheNewestOfSpotlightAndBundleIdLeftovers() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/com.x.app/db", age: 3)
        try box.backdate("Library/Application Support/com.x.app", days: 3)
        try box.file("Library/Application Support/X App/z", age: 1)
        try box.backdate("Library/Application Support/X App", days: 1)
        let leftovers = [Leftover(path: box.home + "/Library/Application Support/com.x.app", match: .bundleID),
                         Leftover(path: box.home + "/Library/Application Support/X App", match: .name)]
        let date = try #require(AppInventory.lastActivity(spotlight: nil, leftovers: leftovers))
        #expect((2.9...3.1).contains(Date().timeIntervalSince(date) / 86_400))
        let spotlight = Date().addingTimeInterval(-3_600)
        #expect(AppInventory.lastActivity(spotlight: spotlight, leftovers: leftovers) == spotlight)
        #expect(AppInventory.lastActivity(spotlight: nil, leftovers: []) == nil)
    }
}

/// The SHIPPED rules (not test doubles) against a fake home that has what Full Disk Access would
/// reveal on a real Mac: proves the rules match the right things once the permission exists.
@Suite struct BuiltinRulesEndToEndTests {
    func scan(_ box: Sandbox, _ ids: Set<String>) throws -> [String: [String]] {
        let rules = try RuleSet.load(builtin: Data(DefaultRules.json.utf8)).filter { ids.contains($0.id) }
        var out: [String: [String]] = [:]
        for result in Scanner(home: box.home, probe: NoProcesses()).scan(rules) {
            out[result.rule.id] = result.items.map { String($0.path.dropFirst(box.home.count + 1)) }.sorted()
        }
        return out
    }

    @Test func fullDiskAccessRulesMatchTheRightItems() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/MobileSync/Backup/IPHONE-VELHO/Manifest.db", age: 200)
        try box.backdate("Library/Application Support/MobileSync/Backup/IPHONE-VELHO", days: 200)
        try box.file("Library/Application Support/MobileSync/Backup/IPHONE-ATUAL/Manifest.db", age: 3)
        try box.backdate("Library/Application Support/MobileSync/Backup/IPHONE-ATUAL", days: 3)
        try box.file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1/contrato.pdf", age: 90)
        try box.backdate("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1", days: 90)
        try box.file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/B2/hoje.pdf")
        try box.file(".Trash/apagado.zip")
        let found = try scan(box, ["ios-backups", "mail-downloads", "trash"])
        #expect(found["ios-backups"] == ["Library/Application Support/MobileSync/Backup/IPHONE-VELHO"])
        #expect(found["mail-downloads"] == ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1"])
        #expect(found["trash"] == [".Trash/apagado.zip"])
    }

    @Test func brokenPreferenceAndOrphanAgentRulesMatchOnlyTheBrokenOnes() throws {
        let box = try Sandbox()
        try box.file("Library/Preferences/com.x.corrompido.plist")
        try PropertyListSerialization.data(fromPropertyList: ["k": 1], format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: box.home + "/Library/Preferences/com.x.bom.plist"))
        try FileManager.default.createDirectory(atPath: box.home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "o", "Program": "/Applications/Sumiu.app/x"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: box.home + "/Library/LaunchAgents/com.x.orfao.plist"))
        let found = try scan(box, ["broken-preferences", "broken-launch-agents"])
        #expect(found["broken-preferences"] == ["Library/Preferences/com.x.corrompido.plist"])
        #expect(found["broken-launch-agents"] == ["Library/LaunchAgents/com.x.orfao.plist"])
    }
}

@Suite struct VolumeTrashTests {
    let uid = String(getuid())

    @Test func guardAllowsOnlyMyTrashOnOtherVolumes() {
        let g = SafetyGuard()
        #expect(g.check("/Volumes/SSD/.Trashes/\(uid)/arquivo.zip") == .allowed)
        #expect(g.check("/Volumes/SSD/.Trashes/\(uid)") != .allowed)          // the trash folder itself
        #expect(g.check("/Volumes/SSD/.Trashes/0/arquivo.zip") != .allowed)   // another user's trash
        #expect(g.check("/Volumes/SSD/projeto/arquivo.zip") != .allowed)
        #expect(g.check("/Volumes/SSD/.Trashes/\(uid)/../../projeto") != .allowed)
    }

    @Test func uidTokenExpandsAndOnlyTheTrashShapeEscapesTheBroadCheck() {
        #expect(SafetyGuard.isTooBroad(pattern: "/Volumes/*/.Trashes/$UID/*") == false)
        #expect(SafetyGuard.isTooBroad(pattern: "/Volumes/*/*") == true)
        #expect(SafetyGuard.isTooBroad(pattern: "/Volumes/*/.Trashes/*/*") == true)
        #expect(PathExpander.substitutingTokens("/Volumes/*/.Trashes/$UID/*") == "/Volumes/*/.Trashes/\(uid)/*")
    }
}

@Suite struct OrphanFinderTests {
    @Test func embeddedHelpersCountAsInstalled() throws {
        let box = try Sandbox()
        let helper = box.home + "/Apps/Main.app/Contents/Library/LoginItems/Helper.app/Contents"
        try FileManager.default.createDirectory(atPath: helper, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "net.other.helper"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: helper + "/Info.plist"))
        #expect(AppInventory.embeddedBundleIDs(in: box.home + "/Apps/Main.app") == ["net.other.helper"])
    }

    @Test func findsDataOfAppsNoLongerInstalledAndNothingElse() throws {
        let box = try Sandbox()
        let lib = "Library/"
        try box.file(lib + "Containers/com.gone.app/Data/x")
        try box.file(lib + "Group Containers/ABCDE12345.com.gone.app/x")
        try box.file(lib + "Preferences/com.gone.app.plist")
        try box.file(lib + "Caches/com.gone.app/x")
        try box.file(lib + "Containers/com.inst.app.share-extension/Data/x")   // extension of an installed app
        try box.file(lib + "Caches/com.inst.app.ShipIt/x")                      // updater of an installed app
        try box.file(lib + "Caches/com.apple.Safari/x")
        try box.file(lib + "Application Support/com.elsewhere.app/x")           // app on another disk
        try box.file(lib + "Application Support/Nome Humano/x")                 // not an id: not judged here
        try box.file(lib + "Application Scripts/243LU875E5.groups.com.apple.podcasts/x")  // Apple behind team + groups prefix
        try box.file(lib + "Preferences/systemgroup.com.apple.icloud.searchpartyd.sharedsettings.plist")
        try box.file(lib + "Preferences/group.com.apple.mail.plist")
        try box.file(lib + "Application Scripts/QWERTY1234.com.inst.app/x")     // installed app behind its team id
        let finder = OrphanFinder(home: box.home, installedIDs: ["com.inst.app"],
                                  isRegistered: { $0 == "com.elsewhere.app" })
        let groups = finder.find()
        #expect(groups.map(\.bundleID) == ["com.gone.app"])
        let rel = groups[0].items.map { String($0.path.dropFirst(box.home.count + 1)) }.sorted()
        #expect(rel == [lib + "Caches/com.gone.app", lib + "Containers/com.gone.app",
                        lib + "Group Containers/ABCDE12345.com.gone.app", lib + "Preferences/com.gone.app.plist"])
        // Only regenerable stuff is suggested by default; app data waits for the user.
        #expect(groups[0].items.filter(\.isRegenerable).map { ($0.path as NSString).lastPathComponent } == ["com.gone.app"])
    }
}

/// Found on this Mac, from the app: `simctl delete unavailable` and the external-trash glob blocked
/// for minutes in open(), waiting for a macOS "removable volume" prompt. Nothing may block forever.
@Suite struct DeadlineTests {
    @Test func commandThatOutlivesItsDeadlineIsKilledAndReported() throws {
        let started = Date()
        let result = try ProcessRunner.run(["/bin/sleep", "30"], timeout: 1)
        #expect(result.timedOut)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func fastCommandIsUnaffected() throws {
        let result = try ProcessRunner.run(["/bin/echo", "ok"], timeout: 5)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }

    @Test func ruleThatOutlivesItsDeadlineIsMarkedAndTheScanGoesOn() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/a/x")
        let scanner = Scanner(home: box.home, probe: NoProcesses(), ruleDeadline: 1) { rule, home in
            if rule.id == "lento" { Thread.sleep(forTimeInterval: 10) }
            return PathExpander.matches(for: rule, home: home)
        }
        let started = Date()
        let results = scanner.scan([rule("lento", ["~/nada/*"]), rule("caches", ["~/Library/Caches/*"])])
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(results[0].timedOut && results[0].items.isEmpty)
        #expect(!results[1].timedOut && results[1].items.count == 1)
    }
}

@Suite(.serialized) struct CommandTimeoutOverrideTests {
    /// The real CLI ignored MCLEAN_COMMAND_TIMEOUT: `sleep 30` ran to the end with a 2 s setting.
    @Test func defaultCleanerHonorsTheTimeoutSetting() throws {
        setenv("MCLEAN_COMMAND_TIMEOUT", "1", 1)
        defer { unsetenv("MCLEAN_COMMAND_TIMEOUT") }
        let box = try Sandbox()
        let results = Scanner(home: box.home, probe: NoProcesses())
            .scan([rule("lento", [], action: .command(["/bin/sleep", "20"]))])
        let started = Date()
        let outcome = Cleaner(guardrail: SafetyGuard(home: box.home)).clean(results, dryRun: false).outcomes[0]
        #expect(Date().timeIntervalSince(started) < 6)
        #expect(outcome.status == .failed)
        #expect(outcome.detail.contains("tempo esgotado"))
    }
}

@Suite(.serialized) struct HibernatorTests {
    /// A real (tiny) signed bundle, so the codesign check on the copy is the real one.
    @discardableResult
    func makeApp(_ box: Sandbox, _ name: String, id: String, extra: (String) throws -> Void = { _ in }) throws -> InstalledApp {
        let app = box.home + "/Applications/\(name).app"
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: app + "/Contents/Resources", withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: app + "/Contents/MacOS/run"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app + "/Contents/MacOS/run")
        try Data(repeating: 1, count: 300_000).write(to: URL(fileURLWithPath: app + "/Contents/Resources/peso.bin"))
        try Data("icone".utf8).write(to: URL(fileURLWithPath: app + "/Contents/Resources/AppIcon.icns"))
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": "run",
                                   "CFBundlePackageType": "APPL", "CFBundleIconFile": "AppIcon"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        try extra(app)
        let sign = try ProcessRunner.run(["/usr/bin/codesign", "--force", "--sign", "-", app])
        #expect(sign.status == 0, "codesign: \(sign.output)")
        return InstalledApp(path: app, bundleID: id, name: name, version: "1.0")
    }

    func hibernator(_ box: Sandbox) -> Hibernator {
        Hibernator(registryURL: URL(fileURLWithPath: box.home + "/registro/hibernated.json"),
                   appFolders: [box.home + "/Applications"])
    }

    @Test func eligibilityBlocksWhatCannotLeaveApplications() throws {
        let box = try Sandbox()
        let ok = try makeApp(box, "Livre", id: "com.x.livre")
        let mas = try makeApp(box, "Loja", id: "com.x.loja") { app in
            try FileManager.default.createDirectory(atPath: app + "/Contents/_MASReceipt", withIntermediateDirectories: true)
            try Data("r".utf8).write(to: URL(fileURLWithPath: app + "/Contents/_MASReceipt/receipt"))
        }
        let vpn = try makeApp(box, "Vpn", id: "com.x.vpn") { app in
            try FileManager.default.createDirectory(atPath: app + "/Contents/Library/SystemExtensions/x.systemextension", withIntermediateDirectories: true)
        }
        let helper = try makeApp(box, "Helper", id: "com.x.helper") { app in
            try FileManager.default.createDirectory(atPath: app + "/Contents/Library/LaunchServices", withIntermediateDirectories: true)
            try Data("h".utf8).write(to: URL(fileURLWithPath: app + "/Contents/Library/LaunchServices/com.x.helper.priv"))
        }
        let h = hibernator(box)
        #expect(h.ineligibility(of: ok, isRunning: false) == nil)
        #expect(h.ineligibility(of: ok, isRunning: true) != nil)
        #expect(h.ineligibility(of: mas, isRunning: false) != nil)
        #expect(h.ineligibility(of: vpn, isRunning: false) != nil)
        #expect(h.ineligibility(of: helper, isRunning: false) != nil)
        // Found on this Mac: Docker showed only "está aberto", hiding that it can never move.
        #expect(h.ineligibility(of: helper, isRunning: true)?.contains("helper") == true)
        #expect(h.ineligibility(of: InstalledApp(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", name: "Safari", version: nil), isRunning: false) != nil)
    }

    @Test func hibernateLeavesAStubAndWakeRestoresTheRealApp() throws {
        let box = try Sandbox()
        let app = try makeApp(box, "Editor", id: "com.x.editor")
        let store = box.home + "/Volume/MClean Hibernados"
        let h = hibernator(box)
        let entry = try h.hibernate(app, to: store)

        // On the disk: the real, still-valid app.
        #expect(Hibernator.signatureIsValid(entry.storedPath))
        // In Applications: a tiny stub that knows where the app went.
        let stubInfo = try #require(NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist") as? [String: Any])
        #expect((stubInfo["CFBundleIdentifier"] as? String)?.hasPrefix("dev.lellis.mclean.stub.") == true)
        #expect(stubInfo["MCleanHibernatedTarget"] as? String == entry.storedPath)
        #expect(FileManager.default.fileExists(atPath: app.path + "/Contents/Resources/AppIcon.icns"))
        #expect(!FileManager.default.fileExists(atPath: app.path + "/Contents/Resources/peso.bin"))
        let script = try String(contentsOfFile: app.path + "/Contents/MacOS/stub", encoding: .utf8)
        #expect(script.contains(entry.storedPath))
        #expect(try ProcessRunner.run(["/bin/sh", "-n", app.path + "/Contents/MacOS/stub"]).status == 0)
        #expect(h.list().map(\.bundleID) == ["com.x.editor"])

        try h.wake(entry)
        let info = try #require(NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist") as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "com.x.editor")
        #expect(Hibernator.signatureIsValid(app.path))
        #expect(FileManager.default.fileExists(atPath: app.path + "/Contents/Resources/peso.bin"))
        #expect(!FileManager.default.fileExists(atPath: entry.storedPath))
        #expect(h.list().isEmpty)
    }

    /// A copy that does not verify must never cost the original.
    @Test func badCopyAbortsAndKeepsTheOriginal() throws {
        let box = try Sandbox()
        let app = try makeApp(box, "Frágil", id: "com.x.fragil")
        var h = hibernator(box)
        h.copy = { from, to in
            _ = try ProcessRunner.run(["/usr/bin/ditto", from, to])
            try FileManager.default.removeItem(atPath: to + "/Contents/Resources/peso.bin")  // lost a file
        }
        #expect(throws: (any Error).self) { try h.hibernate(app, to: box.home + "/Volume/MClean Hibernados") }
        #expect(Hibernator.signatureIsValid(app.path))
        #expect(FileManager.default.fileExists(atPath: app.path + "/Contents/Resources/peso.bin"))
        #expect(h.list().isEmpty)
    }

    @Test func wakeWithTheDiskMissingFailsAndKeepsTheStub() throws {
        let box = try Sandbox()
        let app = try makeApp(box, "Longe", id: "com.x.longe")
        let h = hibernator(box)
        let entry = try h.hibernate(app, to: box.home + "/Volume/MClean Hibernados")
        try FileManager.default.moveItem(atPath: box.home + "/Volume", toPath: box.home + "/Desmontado")
        #expect(throws: (any Error).self) { try h.wake(entry) }
        let info = try #require(NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist") as? [String: Any])
        #expect((info["CFBundleIdentifier"] as? String)?.hasPrefix("dev.lellis.mclean.stub.") == true)
        #expect(h.list().count == 1)
    }
}

@Suite(.serialized) struct HibernatorWakeGuardTests {
    /// Found in the real run: the stub had launched the app FROM the disk; waking then would
    /// delete the copy the running app is using.
    @Test func wakeRefusesWhileTheAppRuns() throws {
        let box = try Sandbox()
        let tests = HibernatorTests()
        let app = try tests.makeApp(box, "Rodando", id: "com.x.rodando")
        let h = tests.hibernator(box)
        let entry = try h.hibernate(app, to: box.home + "/Volume/MClean Hibernados")
        #expect(throws: (any Error).self) { try h.wake(entry, isRunning: true) }
        #expect(FileManager.default.fileExists(atPath: entry.storedPath))
    }

    /// If the user reinstalled the app meanwhile, "Acordar" must not overwrite the new install.
    @Test func wakeRefusesToReplaceSomethingThatIsNotOurStub() throws {
        let box = try Sandbox()
        let tests = HibernatorTests()
        let app = try tests.makeApp(box, "Reinstalado", id: "com.x.reinst")
        let h = tests.hibernator(box)
        let entry = try h.hibernate(app, to: box.home + "/Volume/MClean Hibernados")
        try FileManager.default.removeItem(atPath: app.path)
        try tests.makeApp(box, "Reinstalado", id: "com.x.reinst")      // fresh install in its place
        #expect(throws: (any Error).self) { try h.wake(entry) }
        let info = try #require(NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist") as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "com.x.reinst")
        #expect(FileManager.default.fileExists(atPath: entry.storedPath))
    }
}

@Suite(.serialized) struct HibernatorLeftoverTests {
    /// Found for real: macOS denied deleting the disk copy during wake; `try?` hid it, leaving an
    /// unregistered copy that then blocked hibernating the same app again ("já existe").
    @Test func wakeReportsACopyItCouldNotDelete() throws {
        let box = try Sandbox()
        let tests = HibernatorTests()
        let app = try tests.makeApp(box, "Teimoso", id: "com.x.teimoso")
        var h = tests.hibernator(box)
        let entry = try h.hibernate(app, to: box.home + "/Volume/MClean Hibernados")
        h.remove = { path in
            if path == entry.storedPath { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(atPath: path)
        }
        let leftover = try h.wake(entry)
        #expect(leftover == entry.storedPath)
        #expect(Hibernator.signatureIsValid(app.path))
        #expect(h.list().isEmpty)
    }

    @Test func anUnregisteredCopyOnTheDiskDoesNotBlockHibernating() throws {
        let box = try Sandbox()
        let tests = HibernatorTests()
        let app = try tests.makeApp(box, "Repetido", id: "com.x.repetido")
        let store = box.home + "/Volume/MClean Hibernados"
        try FileManager.default.createDirectory(atPath: store + "/Repetido.app", withIntermediateDirectories: true)
        let entry = try tests.hibernator(box).hibernate(app, to: store)
        #expect(entry.storedPath != store + "/Repetido.app")
        #expect(FileManager.default.fileExists(atPath: store + "/Repetido.app"))   // old copy untouched
        #expect(Hibernator.signatureIsValid(entry.storedPath))
    }
}
