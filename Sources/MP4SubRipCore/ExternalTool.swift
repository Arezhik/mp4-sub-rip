import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Copied from PGS2SRT (PGSCore/MKVToolNix.swift) and generalized to any command-line
// tool. What it keeps from PGS2SRT:
// - Search order: /opt/homebrew/bin (Apple silicon Homebrew), /usr/local/bin (Intel
//   Homebrew), /Applications/<Prefix>*.app/Contents/MacOS, then PATH. An app launched
//   from Finder gets a short PATH, so the fixed folders must come first.
// - Every executable in the spec must be found. A partial install counts as missing.
// - Each run logs the command, the exit code, and stderr (flattened, cut at 2,000
//   characters). Standard output stays out of the log. PGS2SRT's MKVToolNix v97 failure
//   on an Intel Mac (exit 4, empty stderr) was found from exactly these lines.
// - Cancelling the calling Task kills the process with SIGKILL. terminate() alone was
//   not enough on Linux when called off the launching thread.
// - The version is recorded at launch and in the exported debug log header.

/// What to look for. Edit `ExternalToolSpec.primary` for this app.
public struct ExternalToolSpec: Equatable, Sendable {
    /// Display name, such as "ffmpeg" or "MKVToolNix".
    public var name: String
    /// Every executable the app needs. All must be found.
    public var executables: [String]
    /// App bundles in /Applications whose names start with this, such as "MKVToolNix".
    public var appBundlePrefix: String?
    /// Arguments that print a version on the first line, such as ["--version"] or ["-version"].
    public var versionArguments: [String]

    public init(name: String, executables: [String], appBundlePrefix: String? = nil, versionArguments: [String] = ["--version"]) {
        self.name = name
        self.executables = executables
        self.appBundlePrefix = appBundlePrefix
        self.versionArguments = versionArguments
    }

    public static let primary = ExternalToolSpec(
        name: "ffmpeg",
        executables: ["ffmpeg"],
        appBundlePrefix: "ffmpeg",
        versionArguments: ["-version"]
    )
}

/// Executable name to full path, for every executable in the spec.
public struct ExternalToolPaths: Equatable, Sendable {
    public var paths: [String: String]

    public init(paths: [String: String]) {
        self.paths = paths
    }

    public subscript(_ executable: String) -> String? { paths[executable] }
}

public enum ToolFailure: Error, Equatable, LocalizedError {
    case notInstalled(String)
    case couldNotStart(String)
    case failed(tool: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(name):
            return "\(name) is not installed. Install it with Homebrew or from its website, then try again."
        case let .couldNotStart(name):
            return "\(name) could not be started."
        case let .failed(tool, status):
            return "\(tool) stopped with exit code \(status). Export the debug log for details."
        }
    }
}

/// Path and version from one lookup. The launch line and the debug-log header
/// both print this, so they can't describe two different results.
public struct LocatedTool: Equatable, Sendable {
    public var name: String
    public var path: String
    public var version: String

    public init(name: String, path: String, version: String) {
        self.name = name
        self.path = path
        self.version = version
    }
}

/// Wording shared by the launch log and the exported debug-log header.
public enum ToolDetection {
    public struct Line: Equatable, Sendable {
        public var message: String
        public var isError: Bool

        public init(message: String, isError: Bool) {
            self.message = message
            self.isError = isError
        }
    }

    public static func logLine(spec: ExternalToolSpec, located: LocatedTool?) -> Line {
        guard let located else {
            return Line(message: "\(spec.name) not found", isError: true)
        }
        return Line(
            message: "\(located.name) found \(located.path), version \(located.version)",
            isError: false
        )
    }

    public static func facts(spec: ExternalToolSpec, located: LocatedTool?) -> [DebugFact] {
        [
            DebugFact(spec.name, located?.path ?? "not found"),
            DebugFact("\(spec.name) version", located?.version ?? "not found")
        ]
    }
}

public enum ExternalTool {
    /// Locates the tool and reads its version. Nil when the executable is missing.
    public static func describe(_ spec: ExternalToolSpec = .primary) -> LocatedTool? {
        guard let paths = locate(spec) else { return nil }
        let executable = spec.executables.first ?? spec.name
        guard let path = paths[executable] else { return nil }
        let version = version(of: path, arguments: spec.versionArguments) ?? "unknown"
        return LocatedTool(name: spec.name, path: path, version: version)
    }

    public static func locate(_ spec: ExternalToolSpec = .primary) -> ExternalToolPaths? {
        locateInstalled(
            spec,
            executableExists: isRunnable,
            applicationNames: {
                (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
            },
            searchPath: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
    }

    /// Homebrew and `/usr/local/bin` are checked before `/Applications` is
    /// listed. A hit there returns immediately. Launch on 2026-11-09 logged
    /// ffmpeg missing while the same run's header found `/opt/homebrew/bin/ffmpeg`;
    /// that check used `isExecutableFile` only, after listing `/Applications`.
    /// `access(X_OK)` counts too, including for a relative symlink.
    static func locateInstalled(
        _ spec: ExternalToolSpec,
        executableExists: (String) -> Bool,
        applicationNames: () -> [String],
        searchPath: String
    ) -> ExternalToolPaths? {
        if let found = locate(spec, executableExists: executableExists, applications: [], searchPath: "") {
            return found
        }
        return locate(
            spec,
            executableExists: executableExists,
            applications: applicationNames(),
            searchPath: searchPath
        )
    }

    /// A regular file, or a symlink to one, that can be executed. Directories
    /// are rejected even when they are searchable. `access` follows a relative
    /// symlink (Homebrew's layout) from the link's own directory.
    static func isRunnable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue { return false }
        if access(path, X_OK) == 0 { return true }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// `applications` is the names inside `/Applications`, such as `MKVToolNix.app`.
    public static func locate(
        _ spec: ExternalToolSpec,
        executableExists: (String) -> Bool,
        applications: [String],
        searchPath: String
    ) -> ExternalToolPaths? {
        let bundles: [String]
        if let prefix = spec.appBundlePrefix, !prefix.isEmpty {
            bundles = applications.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".app") }.sorted()
        } else {
            bundles = []
        }
        func find(_ name: String) -> String? {
            for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] where executableExists(path) {
                return path
            }
            for bundle in bundles {
                let path = "/Applications/\(bundle)/Contents/MacOS/\(name)"
                if executableExists(path) { return path }
            }
            for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
                let path = (String(directory) as NSString).appendingPathComponent(name)
                if executableExists(path) { return path }
            }
            return nil
        }
        var found: [String: String] = [:]
        for executable in spec.executables {
            guard let path = find(executable) else { return nil }
            found[executable] = path
        }
        return found.isEmpty ? nil : ExternalToolPaths(paths: found)
    }

    /// The first line the tool prints for its version arguments.
    public static func version(of executable: String, arguments: [String] = ExternalToolSpec.primary.versionArguments) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line, !line.isEmpty else { return nil }
        return line
    }
}

/// One run of an external command.
public struct ToolCommandResult: Equatable, Sendable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(status: Int32, standardOutput: Data, standardError: Data) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ToolCommand {
    /// Runs the tool off the main thread. Cancelling the calling task kills the process.
    public static func run(executable: String, arguments: [String]) async throws -> ToolCommandResult {
        let runner = CommandRunner()
        return try await withTaskCancellationHandler {
            try await runner.start(executable: executable, arguments: arguments)
        } onCancel: {
            runner.cancel()
        }
    }
}

/// Owns the running `Process` so a cancel from another task can terminate it.
private final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process else { return }
        stop(process)
    }

    func start(executable: String, arguments: [String]) async throws -> ToolCommandResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolCommandResult, Error>) in
            let resume = ResumeBox(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.blocking(executable: executable, arguments: arguments) }
                resume.resume(result)
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Stores the process. Returns false when cancel already won.
    private func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    /// `terminate()` is not enough on Linux when it is called off the thread that
    /// launched the tool. SIGKILL makes Cancel stop the tool immediately.
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        if pid > 0 {
            kill(pid, SIGKILL)
        }
    }

    private func forget() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    private func blocking(executable: String, arguments: [String]) throws -> ToolCommandResult {
        let command = ToolCommandFormatting.line(executable: executable, arguments: arguments)
        if isCancelled {
            ToolCommandFormatting.logCancelled(command)
            throw CancellationError()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        guard adopt(process) else {
            ToolCommandFormatting.logCancelled(command)
            throw CancellationError()
        }
        DebugLog.shared.record(.tool, "command \(command)")
        do {
            try process.run()
        } catch {
            forget()
            DebugLog.shared.record(.error, "command \(command) could not start", isError: true)
            throw ToolFailure.couldNotStart((executable as NSString).lastPathComponent)
        }
        if isCancelled {
            stop(process)
        }
        let stdout = PipeReader(stdoutPipe.fileHandleForReading)
        let stderr = PipeReader(stderrPipe.fileHandleForReading)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout.readToEnd()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr.readToEnd()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        let status = process.terminationStatus
        forget()
        let failed = status != 0
        DebugLog.shared.record(.tool, "exit \(status)", isError: failed)
        if let stderrText = ToolCommandFormatting.stderrText(stderr.data) {
            DebugLog.shared.record(.tool, "stderr \(stderrText)", isError: failed)
        } else if failed {
            DebugLog.shared.record(.tool, "stderr was empty", isError: true)
        }
        if isCancelled {
            ToolCommandFormatting.logCancelled(command)
            throw CancellationError()
        }
        return ToolCommandResult(status: status, standardOutput: stdout.data, standardError: stderr.data)
    }
}

/// How a tool invocation is written into the debug log. Standard output stays out.
enum ToolCommandFormatting {
    static func line(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map { part in
            if part.contains(where: { $0 == " " || $0 == "\"" }) {
                return "\"\(part.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return part
        }.joined(separator: " ")
    }

    static func stderrText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let limit = 2000
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    static func logCancelled(_ command: String) {
        DebugLog.shared.record(.tool, "command cancelled \(command)")
    }
}

/// Reads a pipe on a background thread. `Pipe` and `FileHandle` are not sendable, so they stay in here.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() {
        data = (try? handle.readToEnd()) ?? Data()
    }
}

/// Resumes a continuation once. The process thread and a failure path must not both resume it.
private final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
