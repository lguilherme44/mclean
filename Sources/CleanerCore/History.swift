import Foundation

/// Free space of the Mac's disk over time plus every cleanup, so the app can show whether
/// cleanups hold and when the disk fills up at the current pace.
public struct History: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public let date: Date
        public let freeBytes: Int64
        public let totalBytes: Int64

        public init(date: Date, freeBytes: Int64, totalBytes: Int64) {
            self.date = date
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
        }
    }

    public struct Cleanup: Codable, Sendable, Equatable {
        public let date: Date
        /// Where it came from: "Limpeza", "Space Lens", "node_modules", "CLI".
        public let source: String
        /// Measured on the Mac's disk (`df` delta), not estimated. Zero for moves to the Trash.
        public let freedBytes: Int64
        /// Rule ids or paths, for the cleanup log.
        public let items: [String]

        public init(date: Date, source: String, freedBytes: Int64, items: [String]) {
            self.date = date
            self.source = source
            self.freedBytes = freedBytes
            self.items = items
        }
    }

    public private(set) var samples: [Sample] = []
    public private(set) var cleanups: [Cleanup] = []

    /// Two years of hourly samples would be ~17k points; keep the file small and the chart fast.
    public static let maxSamples = 2_000
    public static let maxCleanups = 500
    /// Opening the app twice in ten minutes adds one point, not two.
    public static let minSampleInterval: TimeInterval = 3_600

    public init() {}

    public mutating func record(_ sample: Sample) {
        if let last = samples.last, sample.date.timeIntervalSince(last.date) < Self.minSampleInterval {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    public mutating func record(_ cleanup: Cleanup) {
        cleanups.append(cleanup)
        if cleanups.count > Self.maxCleanups { cleanups.removeFirst(cleanups.count - Self.maxCleanups) }
    }
}

/// Pace of disk consumption and the date it runs out, from the history.
public struct Forecast: Equatable, Sendable {
    /// Negative = the disk is filling up.
    public let bytesPerDay: Double
    /// nil when free space is stable or growing.
    public let daysUntilFull: Double?
    public let samplesUsed: Int

    public static let window: TimeInterval = 14 * 86_400

    /// Needs at least 5 samples over 2+ days in the last 14 days. Free space is first corrected by
    /// the recorded cleanups (a 10 GB cleanup is not a "trend"), reduced to one point per day, and
    /// the pace is the MEDIAN of day-to-day changes: an unrecorded jump (emptying the Trash, a
    /// Finder delete) is one change among many, so it barely moves the result. A regression or
    /// Theil–Sen would not hold: a jump mid-series sits between half of all point pairs.
    public static func make(_ history: History, now: Date = Date(), calendar: Calendar = .current) -> Forecast? {
        let recent = history.samples.filter { now.timeIntervalSince($0.date) <= window }
        guard recent.count >= 5, let first = recent.first, let last = recent.last,
              last.date.timeIntervalSince(first.date) >= 2 * 86_400 else { return nil }

        var daily: [(date: Date, bytes: Double)] = []
        for sample in recent {
            let freedBefore = history.cleanups.filter { $0.date <= sample.date }.reduce(Int64(0)) { $0 + $1.freedBytes }
            let point = (date: sample.date, bytes: Double(sample.freeBytes - freedBefore))
            if let previous = daily.last, calendar.isDate(previous.date, inSameDayAs: sample.date) {
                daily[daily.count - 1] = point
            } else {
                daily.append(point)
            }
        }
        var changes: [Double] = []
        for (a, b) in zip(daily, daily.dropFirst()) {
            let days = b.date.timeIntervalSince(a.date) / 86_400
            if days > 0 { changes.append((b.bytes - a.bytes) / days) }
        }
        guard changes.count >= 2 else { return nil }
        changes.sort()
        let mid = changes.count / 2
        let slope = changes.count % 2 == 0 ? (changes[mid - 1] + changes[mid]) / 2 : changes[mid]

        // Under ~50 MB/day is noise (swap, caches breathing): call it stable.
        let filling = slope < -50_000_000
        return Forecast(
            bytesPerDay: slope,
            daysUntilFull: filling ? Double(last.freeBytes) / -slope : nil,
            samplesUsed: recent.count)
    }
}

public struct HistoryStore: Sendable {
    public let url: URL

    public init(url: URL = HistoryStore.defaultURL) { self.url = url }

    /// `MCLEAN_HISTORY_FILE` overrides it (visual QA with fixture data).
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["MCLEAN_HISTORY_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MClean/history.json")
    }

    /// Missing file = empty history. An unreadable one is moved aside (never silently overwritten).
    public func load() -> History {
        guard let data = try? Data(contentsOf: url) else { return History() }
        do {
            return try Self.decoder.decode(History.self, from: data)
        } catch {
            let aside = url.appendingPathExtension("corrompido")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return History()
        }
    }

    public func save(_ history: History) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(history).write(to: url, options: .atomic)
    }

    /// Load, change, save: the app and the CLI both write here.
    public func update(_ change: (inout History) -> Void) {
        var history = load()
        change(&history)
        try? save(history)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension HistoryStore {
    /// One call for "measured the disk now": app launch, `mclean status`, after any cleanup.
    @discardableResult
    public func recordSample(_ status: DiskStatus, at date: Date = Date()) -> History {
        var result = History()
        update { history in
            history.record(History.Sample(date: date, freeBytes: status.freeBytes, totalBytes: status.totalBytes))
            result = history
        }
        return result
    }

    /// `freedByVolume` is the measured `df` delta per volume; the history follows the Mac's disk (`/`).
    @discardableResult
    public func recordCleanup(source: String, freedByVolume: [String: Int64], items: [String],
                              status: DiskStatus, at date: Date = Date()) -> History {
        var result = History()
        update { history in
            history.record(History.Cleanup(date: date, source: source, freedBytes: max(freedByVolume["/"] ?? 0, 0), items: items))
            history.record(History.Sample(date: date, freeBytes: status.freeBytes, totalBytes: status.totalBytes))
            result = history
        }
        return result
    }
}
