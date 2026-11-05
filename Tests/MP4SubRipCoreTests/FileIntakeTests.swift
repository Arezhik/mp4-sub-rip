import XCTest
@testable import MP4SubRipCore

final class FileIntakeTests: XCTestCase {
    private let accepted: Set<String> = ["in"]

    /// A fake disk: folders map to their children.
    private func listing(_ tree: [String: [String]], unreadable: Set<String> = []) -> DirectoryListing {
        DirectoryListing(
            isDirectory: { tree[$0] != nil || unreadable.contains($0) },
            children: { path in
                if unreadable.contains(path) { throw CocoaError(.fileReadNoPermission) }
                return tree[path] ?? []
            }
        )
    }

    func testFolderIsWalkedIncludingSubfolders() {
        let disk = listing([
            "/m": ["/m/a.in", "/m/notes.txt", "/m/sub"],
            "/m/sub": ["/m/sub/b.IN"]
        ])
        let result = FileIntake.collect(paths: ["/m/"], accepted: accepted, listing: disk)
        XCTAssertEqual(result.sourcePaths, ["/m/a.in", "/m/sub/b.IN"])
        XCTAssertEqual(result.notices, [])
    }

    func testUnsupportedFileBecomesANotice() {
        let result = FileIntake.collect(paths: ["/x/photo.jpg"], accepted: accepted, listing: listing([:]))
        XCTAssertEqual(result.sourcePaths, [])
        XCTAssertEqual(result.notices, [.unsupported(path: "/x/photo.jpg")])
    }

    func testEmptyAndUnreadableFolders() {
        let disk = listing(["/empty": []], unreadable: ["/locked"])
        let result = FileIntake.collect(paths: ["/empty", "/locked"], accepted: accepted, listing: disk)
        XCTAssertEqual(result.notices, [.noMatchingFiles(folderName: "empty"), .unreadableFolder(folderName: "locked")])
    }

    func testDuplicatesAreAddedOnce() {
        let disk = listing(["/m": ["/m/a.in"]])
        let result = FileIntake.collect(paths: ["/m/a.in", "/m"], accepted: accepted, listing: disk)
        XCTAssertEqual(result.sourcePaths, ["/m/a.in"])
    }
}
