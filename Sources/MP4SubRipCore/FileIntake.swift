import Foundation

// Copied from PGS2SRT (PGSCore/FileIntake.swift) and generalized to any set of
// extensions. Folders are walked, including subfolders (issue #11), symlink loops
// are skipped, hidden files are ignored, and everything that is not accepted
// becomes a polite notice instead of an error.

/// How the window looks at files and folders that were dropped or opened.
public struct DirectoryListing: Sendable {
    public var isDirectory: @Sendable (String) -> Bool
    /// Names inside a directory. Each entry is a full path. Throw when the folder cannot be read.
    public var children: @Sendable (String) throws -> [String]
    /// A stable identity so a symbolic link back to a parent does not loop.
    public var identity: @Sendable (String) -> String

    public init(
        isDirectory: @escaping @Sendable (String) -> Bool,
        children: @escaping @Sendable (String) throws -> [String],
        identity: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.isDirectory = isDirectory
        self.children = children
        self.identity = identity
    }

    public static let live: DirectoryListing = DirectoryListing(
        isDirectory: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        children: { path in
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            return names
                .filter { !$0.hasPrefix(".") }
                .map { (path as NSString).appendingPathComponent($0) }
        },
        identity: { path in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
    )
}

/// A file or folder the person dropped that is not added to the queue.
public enum IntakeNotice: Equatable, Sendable {
    case unsupported(path: String)
    case noMatchingFiles(folderName: String)
    case unreadableFolder(folderName: String)

    public var message: String {
        switch self {
        case let .unsupported(path):
            return "\(FileIntake.lastComponent(path)) is not a \(AppIdentity.inputDescription) file, so it was skipped."
        case let .noMatchingFiles(folderName):
            return "No \(AppIdentity.inputDescription) files were found in \(folderName)."
        case let .unreadableFolder(folderName):
            return "Could not look inside \(folderName)."
        }
    }
}

/// Files to add, plus notes for everything else.
public struct IntakeResult: Equatable, Sendable {
    public var sourcePaths: [String]
    public var notices: [IntakeNotice]

    public init(sourcePaths: [String], notices: [IntakeNotice]) {
        self.sourcePaths = sourcePaths
        self.notices = notices
    }
}

/// Sorts dropped paths into accepted files, folders of accepted files, and notes.
public enum FileIntake {
    public static func collect(
        paths: [String],
        accepted: Set<String> = AppIdentity.inputExtensions,
        listing: DirectoryListing
    ) -> IntakeResult {
        let accepted = Set(accepted.map { $0.lowercased() })
        var sourcePaths: [String] = []
        var notices: [IntakeNotice] = []
        var seenSources: Set<String> = []
        var seenDirectories: Set<String> = []
        for path in paths {
            let cleaned = trimTrailingSlash(path)
            if cleaned.isEmpty { continue }
            if listing.isDirectory(cleaned) {
                let before = sourcePaths.count
                let seenBefore = seenDirectories.contains(listing.identity(cleaned))
                walk(
                    cleaned,
                    accepted: accepted,
                    listing: listing,
                    sourcePaths: &sourcePaths,
                    seenSources: &seenSources,
                    seenDirectories: &seenDirectories,
                    notices: &notices
                )
                let unreadable = notices.contains { notice in
                    if case let .unreadableFolder(name) = notice { return name == lastComponent(cleaned) }
                    return false
                }
                if !seenBefore && sourcePaths.count == before && !unreadable {
                    notices.append(.noMatchingFiles(folderName: lastComponent(cleaned)))
                }
            } else if isAccepted(cleaned, accepted) {
                appendSource(cleaned, sourcePaths: &sourcePaths, seenSources: &seenSources)
            } else {
                notices.append(.unsupported(path: cleaned))
            }
        }
        return IntakeResult(sourcePaths: sourcePaths, notices: notices)
    }

    private static func walk(
        _ directory: String,
        accepted: Set<String>,
        listing: DirectoryListing,
        sourcePaths: inout [String],
        seenSources: inout Set<String>,
        seenDirectories: inout Set<String>,
        notices: inout [IntakeNotice]
    ) {
        let key = listing.identity(directory)
        if seenDirectories.contains(key) { return }
        seenDirectories.insert(key)
        let children: [String]
        do {
            children = try listing.children(directory)
        } catch {
            notices.append(.unreadableFolder(folderName: lastComponent(directory)))
            return
        }
        for child in children {
            let cleaned = trimTrailingSlash(child)
            if listing.isDirectory(cleaned) {
                walk(
                    cleaned,
                    accepted: accepted,
                    listing: listing,
                    sourcePaths: &sourcePaths,
                    seenSources: &seenSources,
                    seenDirectories: &seenDirectories,
                    notices: &notices
                )
            } else if isAccepted(cleaned, accepted) {
                appendSource(cleaned, sourcePaths: &sourcePaths, seenSources: &seenSources)
            }
        }
    }

    private static func appendSource(_ path: String, sourcePaths: inout [String], seenSources: inout Set<String>) {
        if seenSources.insert(path).inserted {
            sourcePaths.append(path)
        }
    }

    static func isAccepted(_ path: String, _ accepted: Set<String>) -> Bool {
        accepted.contains((path as NSString).pathExtension.lowercased())
    }

    static func lastComponent(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
