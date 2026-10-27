import Foundation

public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        /// Killed after the deadline (e.g. blocked on a macOS permission prompt).
        public var timedOut = false

        public init(status: Int32, output: String, timedOut: Bool = false) {
            self.status = status
            self.output = output
            self.timedOut = timedOut
        }
    }

    /// Runs argv (first element resolved through PATH) from `directory` and captures stdout+stderr.
    /// Home by default: tools like pnpm act on the store of the cwd's volume, so the result must
    /// not depend on where mclean was started.
    /// `timeout`: SIGTERM after it, SIGKILL 2 s later; reported as `timedOut`, never awaited forever.
    public static func run(_ argv: [String], in directory: String = NSHomeDirectory(),
                           timeout: TimeInterval = defaultTimeout) throws -> Result {
        guard let executable = argv[0].hasPrefix("/") ? argv[0] : resolve(argv[0]) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: argv[0]])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        final class Output: @unchecked Sendable { var data = Data() }
        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = drained.wait(timeout: .now() + 2)
            return Result(status: -1, output: "tempo esgotado após \(Int(timeout)) s (o macOS pode estar pedindo permissão)",
                          timedOut: true)
        }
        _ = drained.wait(timeout: .now() + 5)
        return Result(status: process.terminationStatus, output: String(decoding: output.data, as: UTF8.self))
    }

    /// 180 s, or `MCLEAN_COMMAND_TIMEOUT` seconds (so the kill path can be exercised for real).
    public static var defaultTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MCLEAN_COMMAND_TIMEOUT"].flatMap(TimeInterval.init) ?? 180
    }

    public static func resolve(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
