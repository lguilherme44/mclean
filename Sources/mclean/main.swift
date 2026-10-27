import AppKit
import CleanerCore
import Foundation

let usage = """
mclean — limpeza de disco do Mac, regras explícitas, nada apagado sem --yes.

  mclean status                         espaço livre, swap, snapshots locais
  mclean rules                          lista as regras (embutidas + ~/.config/mclean/rules.json)
  mclean scan [--all] [--json]          mede o que cada regra encontraria
  mclean clean [--ids a,b] [--review] [--yes] [--json]
                                        sem --yes é simulação. Padrão: regras "safe".
                                        --review inclui as regras "review"; --ids escolhe à mão.
  mclean node-modules <dir>... [--days N] [--list-only] [--yes]
                                        node_modules de projetos parados há N dias (padrão 14)
  mclean apps [--json]                  apps instalados (sem os da Apple) e as sobras de cada um
  mclean uninstall <nome|bundle id> [--yes]
                                        mostra o que sai; com --yes move app e sobras para a Lixeira
  mclean hibernated                     apps hibernados (movidos para outro disco, com app-fantasma no lugar)
  mclean hibernate <nome> [--to /Volumes/X] [--yes]
                                        move o app para o disco externo e deixa um app-fantasma que o abre
  mclean wake <nome> [--yes]            traz o app hibernado de volta
  mclean orphans [--yes] [--include-data]
                                        sobras de apps JÁ removidos; --yes move os caches para a Lixeira
                                        (--include-data inclui também os dados: Containers, Preferences...)
"""

struct Options {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ args: ArraySlice<String>) {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "--ids" || arg == "--days" {
                values[arg] = iterator.next()
            } else if arg.hasPrefix("--") {
                flags.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }
}

func human(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(value))
    print()
}

func stderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func scanWithProgress(_ rules: [Rule], quiet: Bool) -> [RuleResult] {
    Scanner().scan(rules) { rule in
        if !quiet { stderr("  medindo \(rule.name)…") }
    }
}

func printScan(_ results: [RuleResult], showEmpty: Bool) {
    let visible = results.filter { showEmpty || !$0.items.isEmpty || $0.rule.paths.isEmpty || $0.timedOut }
    for result in visible.sorted(by: { $0.bytes > $1.bytes }) {
        let rule = result.rule
        let size = rule.paths.isEmpty ? "?" : human(result.bytes)
        var flags: [String] = [rule.safety.rawValue]
        if case .report = rule.action { flags = ["info"] }
        if !result.runningBlockers.isEmpty { flags.append("aberto: \(result.runningBlockers.joined(separator: ","))") }
        if let tool = result.missingTool { flags.append("sem \(tool)") }
        if result.unreadableEntries > 0 { flags.append("\(result.unreadableEntries) ilegíveis: tamanho mínimo") }
        if result.timedOut { flags.append("NÃO MEDIDO: passou do tempo (pedido de permissão do macOS pendente?)") }
        print("\(pad(size, 10)) \(pad(rule.id, 26)) \(rule.name) [\(flags.joined(separator: "; "))]")
        if let note = rule.note, result.bytes > 0 || rule.paths.isEmpty { print("           ↳ \(note)") }
    }
    let selectable = results.filter { if case .report = $0.rule.action { false } else { true } }
    let safe = selectable.filter { $0.rule.safety == .safe }.reduce(0) { $0 + $1.bytes }
    let review = selectable.filter { $0.rule.safety == .review }.reduce(0) { $0 + $1.bytes }
    print("\nestimativa: \(human(safe)) em regras safe, +\(human(review)) em review (hardlinks contados uma vez)")
    if !Permissions.hasFullDiskAccess {
        let blocked = results.filter { Permissions.fullDiskAccessRules.contains($0.rule.id) && $0.bytes == 0 }.map(\.rule.id)
        if !blocked.isEmpty {
            print("sem Acesso Total ao Disco: \(blocked.joined(separator: ", ")) NÃO foram medidas (dê a permissão ao terminal)")
        }
    }
}

func run() throws -> Int32 {
    let args = CommandLine.arguments
    guard args.count > 1 else { print(usage); return 0 }
    let options = Options(args.dropFirst(2))
    let json = options.flags.contains("--json")

    switch args[1] {
    case "status":
        let status = DiskStatus.current()
        HistoryStore().recordSample(status)
        if json { try printJSON(status); return 0 }
        print("livre: \(human(status.freeBytes)) de \(human(status.totalBytes))")
        print("swap em uso: \(human(status.swapUsedBytes)) (os swapfiles ocupam disco)")
        print("snapshots locais: \(status.localSnapshots.count)")
        for snapshot in status.localSnapshots { print("  \(snapshot)") }

    case "rules":
        let rules = try RuleSet.loadDefault()
        if json { try printJSON(rules); return 0 }
        for rule in rules {
            print("\(pad(rule.id, 26)) \(pad(rule.safety.rawValue, 7)) \(pad(rule.category, 7)) \(rule.name)")
        }

    case "scan":
        let results = scanWithProgress(try RuleSet.loadDefault(), quiet: json)
        if json { try printJSON(results); return 0 }
        printScan(results, showEmpty: options.flags.contains("--all"))

    case "clean":
        let rules = try RuleSet.loadDefault()
        let ids = options.values["--ids"].map { Set($0.split(separator: ",").map(String.init)) }
        if let ids {
            let unknown = ids.subtracting(rules.map(\.id))
            guard unknown.isEmpty else {
                stderr("regra desconhecida: \(unknown.sorted().joined(separator: ", "))")
                return 2
            }
        }
        let dryRun = !options.flags.contains("--yes")
        let results = scanWithProgress(rules, quiet: json)
        let selected = Cleaner.select(results, ids: ids, includeReview: options.flags.contains("--review"))
        let report = Cleaner().clean(selected, dryRun: dryRun)
        let cleaned = report.outcomes.filter { [.cleaned, .partial].contains($0.status) }.map(\.ruleID)
        if !dryRun && !cleaned.isEmpty {
            HistoryStore().recordCleanup(source: "CLI", freedByVolume: report.measuredFreedBytes, items: cleaned,
                                         status: DiskStatus.current())
        }
        if json { try printJSON(report); return 0 }
        for outcome in report.outcomes {
            print("\(pad(outcome.status.rawValue, 11)) \(pad(human(outcome.estimatedBytes), 10)) \(pad(outcome.ruleID, 26)) \(outcome.detail)")
        }
        let estimate = report.outcomes.filter { [.cleaned, .partial, .wouldClean].contains($0.status) }
            .reduce(0) { $0 + $1.estimatedBytes }
        if dryRun {
            print("\nSIMULAÇÃO — nada foi apagado. Estimativa: \(human(estimate)). Rode de novo com --yes.")
        } else {
            for (volume, freed) in report.measuredFreedBytes.sorted(by: { $0.key < $1.key }) {
                print("\nliberado de verdade em \(volume): \(human(freed)) (estimativa era \(human(estimate)))")
            }
        }

    case "apps":
        let finder = LeftoverFinder()
        let installed = AppInventory.installed()
        let rows = installed.filter { !$0.isApple }.map { app -> (InstalledApp, Int64, [Leftover], Int64) in
            let leftovers = finder.leftovers(of: app, installed: installed)
            let sizer = SizeCalculator()
            return (app, sizer.allocatedSize(of: app.path), leftovers,
                    leftovers.reduce(0) { $0 + sizer.allocatedSize(of: $1.path) })
        }
        for (app, bytes, leftovers, leftoverBytes) in rows.sorted(by: { $0.1 + $0.3 > $1.1 + $1.3 }) {
            let byName = leftovers.filter { $0.match == .name }.count
            print("\(pad(human(bytes), 10)) +\(pad(human(leftoverBytes), 10)) \(pad(app.name, 30)) \(leftovers.count) sobras"
                  + (byName > 0 ? " (\(byName) por nome)" : "") + "  \(app.bundleID)")
        }

    case "uninstall":
        guard let query = options.positional.first else { stderr("informe o nome ou bundle id do app"); return 2 }
        let installed = AppInventory.installed()
        let matches = installed.filter {
            $0.bundleID.caseInsensitiveCompare(query) == .orderedSame || $0.name.caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1, let app = matches.first else {
            stderr(matches.isEmpty ? "app não encontrado: \(query)" : "mais de um app com esse nome; use o bundle id")
            return 2
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
            stderr("\(app.name) está aberto: feche antes de desinstalar")
            return 3
        }
        let leftovers = LeftoverFinder().leftovers(of: app, installed: installed)
        // Name matches are only suggestions: the CLI removes them only with --include-name.
        let chosen = options.flags.contains("--include-name") ? leftovers : leftovers.filter { $0.match != .name }
        let plan = UninstallPlanner.plan(app: app, leftovers: chosen)
        for unit in plan.units { print("\(pad(human(unit.bytes), 10)) \(unit.path)") }
        for item in plan.blocked { print("bloqueado  \(item.unit.path) (\(item.reason))") }
        for leftover in leftovers where leftover.match == .name && !chosen.contains(leftover) {
            print("por nome   \(leftover.path) (fora; inclua com --include-name)")
        }
        guard options.flags.contains("--yes") else {
            print("\nSIMULAÇÃO — \(human(plan.totalBytes)) iriam para a Lixeira. Rode de novo com --yes.")
            return 0
        }
        let outcomes = DeletionPlanner.execute(plan)
        for outcome in outcomes where outcome.error != nil { print("falhou     \(outcome.unit.path): \(outcome.error ?? "")") }
        let moved = outcomes.filter { $0.error == nil }
        HistoryStore().recordCleanup(source: "Desinstalador", freedByVolume: [:], items: moved.map(\.unit.path),
                                     status: DiskStatus.current())
        print("\n\(moved.count)/\(outcomes.count) itens na Lixeira (\(human(moved.reduce(0) { $0 + $1.unit.bytes }))). Esvazie a Lixeira para liberar o espaço.")

    case "hibernated":
        let entries = Hibernator().list()
        if entries.isEmpty { print("nenhum app hibernado") }
        for entry in entries {
            let online = FileManager.default.fileExists(atPath: entry.storedPath) ? "disco conectado" : "DISCO DESCONECTADO"
            print("\(pad(human(entry.bytes), 10)) \(pad(entry.name, 28)) \(online)  \(entry.storedPath)")
        }

    case "hibernate":
        guard let query = options.positional.first else { stderr("informe o nome do app"); return 2 }
        let matches = AppInventory.installed().filter {
            $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.bundleID.caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1, let app = matches.first else { stderr("app não encontrado (ou ambíguo): \(query)"); return 2 }
        let volumes = options.values["--to"].map { [$0] } ?? Hibernator.candidateVolumes()
        guard volumes.count == 1, let volume = volumes.first, Hibernator.volumeCanHoldApps(volume) else {
            stderr(volumes.isEmpty ? "nenhum disco externo APFS/HFS+ gravável conectado" : "escolha o disco com --to: \(volumes.joined(separator: ", "))")
            return 2
        }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
        let hibernator = Hibernator()
        if let reason = hibernator.ineligibility(of: app, isRunning: running) { stderr("\(app.name) não pode hibernar: \(reason)"); return 3 }
        let folder = Hibernator.storeFolder(onVolume: volume)
        print("\(human(SizeCalculator().allocatedSize(of: app.path))) \(app.path) → \(folder)")
        guard options.flags.contains("--yes") else { print("\nSIMULAÇÃO — rode de novo com --yes."); return 0 }
        let before = Cleaner.freeBytes("/") ?? 0
        let entry = try hibernator.hibernate(app, to: folder, isRunning: running)
        let freed = (Cleaner.freeBytes("/") ?? 0) - before
        HistoryStore().recordCleanup(source: "Hibernar", freedByVolume: ["/": freed], items: [entry.originalPath],
                                     status: DiskStatus.current())
        print("hibernado: \(entry.storedPath)\nliberado de verdade em /: \(human(freed))")

    case "wake":
        guard let query = options.positional.first else { stderr("informe o nome do app"); return 2 }
        let hibernator = Hibernator()
        guard let entry = hibernator.list().first(where: {
            $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.bundleID.caseInsensitiveCompare(query) == .orderedSame
        }) else { stderr("não há app hibernado com esse nome: \(query)"); return 2 }
        print("\(entry.storedPath) → \(entry.originalPath)")
        guard options.flags.contains("--yes") else { print("\nSIMULAÇÃO — rode de novo com --yes."); return 0 }
        let leftover = try hibernator.wake(entry, isRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).isEmpty)
        print("acordado: \(entry.originalPath)")
        if let leftover { print("aviso: a cópia em \(leftover) não pôde ser apagada; apague à mão ou dê permissão ao terminal") }

    case "orphans":
        let installedApps = AppInventory.installed()
        let ids = installedApps.map(\.bundleID) + installedApps.flatMap { AppInventory.embeddedBundleIDs(in: $0.path) }
        let groups = OrphanFinder(installedIDs: ids).find()
        let sizer = SizeCalculator()
        let includeData = options.flags.contains("--include-data")
        var chosen: [SpaceNode] = []
        for group in groups {
            let sizes = group.items.map { ($0, sizer.allocatedSize(of: $0.path)) }
            print("\(pad(human(sizes.reduce(0) { $0 + $1.1 }), 10)) \(group.bundleID)")
            for (item, bytes) in sizes {
                let take = item.isRegenerable || includeData
                print("           \(take ? "x" : " ") \(pad(human(bytes), 10)) \(item.path)")
                if take { chosen.append(SpaceNode(path: item.path, isDirectory: true, bytes: bytes, children: [], isTruncated: false)) }
            }
        }
        // The Trash guard still applies: credentials, iCloud and structural folders stay.
        let guarded = DeletionPlanner.plan(chosen)
        guard options.flags.contains("--yes") else {
            print("\nSIMULAÇÃO — \(human(guarded.totalBytes)) marcados (x) iriam para a Lixeira. Rode de novo com --yes.")
            return 0
        }
        let outcomes = DeletionPlanner.execute(guarded)
        let moved = outcomes.filter { $0.error == nil }
        HistoryStore().recordCleanup(source: "Sobras de apps removidos", freedByVolume: [:], items: moved.map(\.unit.path),
                                     status: DiskStatus.current())
        print("\n\(moved.count)/\(outcomes.count) itens na Lixeira.")

    case "node-modules":
        guard !options.positional.isEmpty else { stderr("informe ao menos um diretório"); return 2 }
        let days = Int(options.values["--days"] ?? "14") ?? 14
        if options.flags.contains("--list-only") {
            for item in NodeModulesFinder.discover(roots: options.positional, idleDays: days) { print(item.path) }
            return 0
        }
        let candidates = NodeModulesFinder.find(roots: options.positional, idleDays: days)
        if json { try printJSON(candidates); return 0 }
        let formatter = RelativeDateTimeFormatter()
        for candidate in candidates {
            let age = formatter.localizedString(for: candidate.lastActivity, relativeTo: Date())
            print("\(pad(human(candidate.bytes), 10)) \(pad(age, 16)) \(candidate.path)")
        }
        let total = candidates.reduce(0) { $0 + $1.bytes }
        guard options.flags.contains("--yes") else {
            print("\n\(candidates.count) node_modules, \(human(total)). SIMULAÇÃO — rode com --yes para apagar.")
            return 0
        }
        let guardrail = SafetyGuard()
        let volume = Cleaner.volume(of: options.positional[0]) ?? "/"
        let freeBefore = Cleaner.freeBytes(volume) ?? 0
        var failures = 0
        for candidate in candidates {
            guard guardrail.check(candidate.path) == .allowed else { failures += 1; continue }
            do { try FileManager.default.removeItem(atPath: candidate.path) } catch {
                failures += 1
                stderr("falhou: \(candidate.path): \(error.localizedDescription)")
            }
        }
        print("apagados \(candidates.count - failures)/\(candidates.count); livre em \(volume): \(human((Cleaner.freeBytes(volume) ?? 0) - freeBefore)) a mais")

    case "help", "--help", "-h":
        print(usage)

    default:
        stderr("comando desconhecido: \(args[1])\n\n\(usage)")
        return 2
    }
    return 0
}

do {
    exit(try run())
} catch {
    stderr("erro: \(error)")
    exit(1)
}
