import CoreGraphics
import XCTest
@testable import InkBridgeCore

final class StorageTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ib-storage-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.appendingPathComponent("ro").path)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func saveSession(_ store: ProjectStore, _ project: String, _ id: String, title: String = "Untitled") throws {
        let mapper = CoordinateMapper(canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 100, height: 100))
        let meta = SessionMetadata(id: id, title: title, startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil,
                                   mapper: mapper, strokeCount: 0)
        try SessionArchive.writeStrokes([], metadata: meta, to: store.sessionDir(project, id))
    }

    func testProjectLifecycle() throws {
        let store = ProjectStore(root: tmp)
        let a = try store.createProject("System Design")
        XCTAssertThrowsError(try store.createProject("System Design")) { XCTAssertEqual($0 as? StorageError, .nameTaken("System Design")) }
        XCTAssertThrowsError(try store.createProject("../etc")) { XCTAssertEqual($0 as? StorageError, .invalidName("../etc")) }
        XCTAssertThrowsError(try store.createProject(".hidden"))
        try saveSession(store, a, "s1", title: "Payments flow")

        let renamed = try store.renameProject(a, to: "Architecture")
        XCTAssertEqual(store.listProjects().map(\.name), ["Architecture"])
        XCTAssertEqual(store.listSessions(renamed).map(\.title), ["Payments flow"], "sessions move with the project")

        let copy = try store.duplicateProject(renamed)
        XCTAssertEqual(copy, "Architecture copy")
        XCTAssertEqual(store.listProjects().count, 2)
        XCTAssertEqual(store.search("copy").map(\.name), ["Architecture copy"])

        try store.renameSession(renamed, id: "s1", title: "Checkout")
        XCTAssertEqual(store.listSessions(renamed, query: "check").map(\.title), ["Checkout"])
        XCTAssertEqual(store.recentSessions().count, 2)

        try store.deleteProject(copy)
        XCTAssertEqual(store.listProjects().map(\.name), ["Architecture"], "deleted projects go to the Trash")
    }

    func testMigrationMovesProjectsWithoutOverwriting() throws {
        let old = ProjectStore(root: tmp.appendingPathComponent("old"))
        let new = ProjectStore(root: tmp.appendingPathComponent("new"))
        try saveSession(old, try old.createProject("A"), "s1")
        try saveSession(old, try old.createProject("B"), "s2")
        _ = try new.createProject("A")  // name clash at the destination
        let moved = try old.migrate(to: new.root)
        XCTAssertEqual(Set(moved), ["A (moved)", "B"])
        XCTAssertTrue(old.listProjects().isEmpty)
        XCTAssertEqual(new.listSessions("A (moved)").map(\.id), ["s1"], "data intact after the move")
        XCTAssertEqual(new.listProjects().count, 3)
    }

    func testInvalidAndReadOnlyDestinationsAreRejectedWithUsefulMessages() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("a-file")
        try Data().write(to: file)
        XCTAssertThrowsError(try ProjectStore.validateDestination(file)) { XCTAssertEqual($0 as? StorageError, .notADirectory(file.path)) }

        let ro = tmp.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        XCTAssertThrowsError(try ProjectStore.validateDestination(ro)) { error in
            XCTAssertEqual(error as? StorageError, .notWritable(ro.path))
            XCTAssertTrue(error.localizedDescription.contains("permissions"), "says what to do")
        }
        let ok = tmp.appendingPathComponent("fresh/nested")
        XCTAssertNotNil(try ProjectStore.validateDestination(ok), "creates the folder and reports free space")
    }

    func testDiskFullMapsToAnActionableMessage() {
        let e = StorageError.from(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), path: "/Volumes/X")
        XCTAssertEqual(e, .diskFull("/Volumes/X"))
        XCTAssertTrue(e.localizedDescription.contains("full"))
        XCTAssertEqual(StorageError.from(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), path: "/p"), .diskFull("/p"))
    }

    /// A crash mid-save leaves either the old or the new file, never a torn one:
    /// SessionArchive writes each file atomically (temp + rename).
    func testInterruptedSaveLeavesTheLastGoodVersionLoadable() throws {
        let store = ProjectStore(root: tmp)
        let p = try store.createProject("P")
        try saveSession(store, p, "s1", title: "Good")
        // Simulate a crash that left a stray temp file next to the real one.
        try Data("{ partial".utf8).write(to: store.sessionDir(p, "s1").appendingPathComponent(".session.json.tmp"))
        let (meta, _) = try SessionArchive.load(from: store.sessionDir(p, "s1"))
        XCTAssertEqual(meta.title, "Good")
    }
}
