import Foundation

/// Where editable work lives on the Mac (the authoritative storage host).
///
///     <root>/                        default ~/Documents/InkBridge
///       Projects/<Project>/
///         project.json               name, created
///         sessions/<session-id>/     session.json + strokes.json (SessionArchive)
///         exports/                   default export folder for this project
///       Backups/                     copies kept before a destructive operation
///
/// Exports are configured separately (`StorageConfig.exportsPath`), so
/// project storage and export destination never get mixed up.
public struct StorageConfig: Codable, Equatable, Sendable {
    public var rootPath: String
    /// nil: ask in the save panel, starting in the active project's `exports/`.
    public var exportsPath: String?
    public var activeProject: String
    /// Locations used before, offered to the tablet (it cannot browse the Mac's disk).
    public var recentRoots: [String]

    public init(rootPath: String, exportsPath: String? = nil, activeProject: String = ProjectStore.defaultProject, recentRoots: [String] = []) {
        self.rootPath = rootPath
        self.exportsPath = exportsPath
        self.activeProject = activeProject
        self.recentRoots = recentRoots
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("InkBridge")
    }
}

/// The save state shown on both devices. `saved` is only ever set after the
/// files were written and renamed into place.
public enum SaveStatus: Equatable, Sendable {
    /// A new session nobody has drawn in: nothing to save, nothing at risk.
    case empty
    case saved(Date)
    case saving
    case unsaved
    case failed(String)

    public var wire: String {
        switch self {
        case .empty: return "empty"
        case .saved: return "saved"
        case .saving: return "saving"
        case .unsaved: return "unsaved"
        case .failed: return "failed"
        }
    }
}

public struct ProjectInfo: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var sessionCount: Int
    public var modified: Date?
}

public struct SessionInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var savedAt: Date
    public var strokeCount: Int
}

public enum StorageError: LocalizedError, Equatable {
    case invalidName(String)
    case nameTaken(String)
    case notFound(String)
    case notADirectory(String)
    case notWritable(String)
    case diskFull(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let n): return "“\(n)” can’t be used as a name. Use letters, numbers, spaces, - or _, without / or : and not starting with a dot."
        case .nameTaken(let n): return "There is already a project called “\(n)”."
        case .notFound(let n): return "“\(n)” no longer exists. It may have been moved or deleted in Finder."
        case .notADirectory(let p): return "\(p) is a file, not a folder."
        case .notWritable(let p): return "InkBridge can’t write to \(p). Check the folder’s permissions or choose another folder."
        case .diskFull(let p): return "The disk holding \(p) is full. Free some space or choose a folder on another disk."
        case .failed(let m): return m
        }
    }

    /// Turns Foundation errors into messages that say what to do.
    public static func from(_ error: Error, path: String) -> StorageError {
        if let e = error as? StorageError { return e }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return .diskFull(path)
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError, NSFileReadNoPermissionError: return .notWritable(path)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound(path)
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            if ns.code == Int(ENOSPC) { return .diskFull(path) }
            if ns.code == Int(EACCES) || ns.code == Int(EROFS) || ns.code == Int(EPERM) { return .notWritable(path) }
        }
        return .failed("\(path): \(ns.localizedDescription)")
    }
}

public final class ProjectStore {
    public static let defaultProject = "My Drawings"
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    public var projectsDir: URL { root.appendingPathComponent("Projects") }
    public var backupsDir: URL { root.appendingPathComponent("Backups") }
    public func projectDir(_ name: String) -> URL { projectsDir.appendingPathComponent(name) }
    public func sessionsDir(_ project: String) -> URL { projectDir(project).appendingPathComponent("sessions") }
    public func exportsDir(_ project: String) -> URL { projectDir(project).appendingPathComponent("exports") }
    public func sessionDir(_ project: String, _ id: String) -> URL { sessionsDir(project).appendingPathComponent(id) }

    // MARK: Validation

    /// Checks a folder can hold InkBridge data: exists (or can be created), is a
    /// folder, and accepts a test write. Returns free bytes when known.
    @discardableResult
    public static func validateDestination(_ url: URL) throws -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw StorageError.notADirectory(url.path) }
        } else {
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { throw StorageError.from(error, path: url.path) }
        }
        let probe = url.appendingPathComponent(".inkbridge-write-test-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try fm.removeItem(at: probe)
        } catch {
            throw StorageError.from(error, path: url.path)
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"), !name.contains("\\") else { return nil }
        return name
    }

    // MARK: Projects

    public func listProjects() -> [ProjectInfo] {
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { $0.hasDirectoryPath }.map { url in
            let sessions = (try? fm.contentsOfDirectory(atPath: url.appendingPathComponent("sessions").path))?.filter { !$0.hasPrefix(".") }.count ?? 0
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return ProjectInfo(name: url.lastPathComponent, sessionCount: sessions, modified: modified)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func search(_ query: String) -> [ProjectInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? listProjects() : listProjects().filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    @discardableResult
    public func ensureProject(_ name: String) throws -> URL {
        let dir = projectDir(name)
        do {
            try fm.createDirectory(at: sessionsDir(name), withIntermediateDirectories: true)
            try fm.createDirectory(at: exportsDir(name), withIntermediateDirectories: true)
            let meta = dir.appendingPathComponent("project.json")
            if !fm.fileExists(atPath: meta.path) {
                try JSONEncoder.iso.encode(["name": name, "created": ISO8601DateFormatter().string(from: Date())]).write(to: meta, options: .atomic)
            }
        } catch { throw StorageError.from(error, path: dir.path) }
        return dir
    }

    public func createProject(_ raw: String) throws -> String {
        guard let name = Self.validName(raw) else { throw StorageError.invalidName(raw) }
        guard !fm.fileExists(atPath: projectDir(name).path) else { throw StorageError.nameTaken(name) }
        try ensureProject(name)
        return name
    }

    public func renameProject(_ old: String, to raw: String) throws -> String {
        guard let name = Self.validName(raw) else { throw StorageError.invalidName(raw) }
        guard fm.fileExists(atPath: projectDir(old).path) else { throw StorageError.notFound(old) }
        guard name != old else { return old }
        guard !fm.fileExists(atPath: projectDir(name).path) else { throw StorageError.nameTaken(name) }
        do { try fm.moveItem(at: projectDir(old), to: projectDir(name)) } catch { throw StorageError.from(error, path: projectDir(old).path) }
        return name
    }

    public func duplicateProject(_ name: String) throws -> String {
        guard fm.fileExists(atPath: projectDir(name).path) else { throw StorageError.notFound(name) }
        var n = 2
        var copy = "\(name) copy"
        while fm.fileExists(atPath: projectDir(copy).path) { copy = "\(name) copy \(n)"; n += 1 }
        do { try fm.copyItem(at: projectDir(name), to: projectDir(copy)) } catch { throw StorageError.from(error, path: projectDir(copy).path) }
        return copy
    }

    /// Moves the project to the Trash (recoverable), never a permanent delete.
    public func deleteProject(_ name: String) throws {
        guard fm.fileExists(atPath: projectDir(name).path) else { throw StorageError.notFound(name) }
        do { try fm.trashItem(at: projectDir(name), resultingItemURL: nil) } catch { throw StorageError.from(error, path: projectDir(name).path) }
    }

    // MARK: Sessions

    public func listSessions(_ project: String, query: String = "") -> [SessionInfo] {
        let dirs = (try? fm.contentsOfDirectory(at: sessionsDir(project), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let all: [SessionInfo] = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let meta = try? SessionArchive.decoder.decode(SessionMetadata.self, from: data) else { return nil }
            return SessionInfo(id: dir.lastPathComponent, title: meta.title, savedAt: meta.savedAt, strokeCount: meta.strokeCount)
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// Recent sessions across all projects, newest first.
    public func recentSessions(limit: Int = 10) -> [(project: String, session: SessionInfo)] {
        listProjects().flatMap { p in listSessions(p.name).map { (p.name, $0) } }
            .sorted { $0.1.savedAt > $1.1.savedAt }.prefix(limit).map { $0 }
    }

    public func renameSession(_ project: String, id: String, title raw: String) throws {
        guard let title = Self.validName(raw) else { throw StorageError.invalidName(raw) }
        let url = sessionDir(project, id).appendingPathComponent("session.json")
        do {
            var meta = try SessionArchive.decoder.decode(SessionMetadata.self, from: Data(contentsOf: url))
            meta.title = title
            try SessionArchive.encoder.encode(meta).write(to: url, options: .atomic)
        } catch { throw StorageError.from(error, path: url.path) }
    }

    // MARK: Moving the whole store

    /// Moves every project from this root to `newRoot`. Never overwrites: a
    /// name that exists at the destination gets " (moved)" appended.
    /// Returns the names as they are now at the destination.
    public func migrate(to newRoot: URL) throws -> [String] {
        try Self.validateDestination(newRoot)
        let target = ProjectStore(root: newRoot)
        do { try fm.createDirectory(at: target.projectsDir, withIntermediateDirectories: true) } catch { throw StorageError.from(error, path: newRoot.path) }
        var moved: [String] = []
        for p in listProjects() {
            var name = p.name
            while fm.fileExists(atPath: target.projectDir(name).path) { name += " (moved)" }
            do { try fm.moveItem(at: projectDir(p.name), to: target.projectDir(name)) } catch {
                throw StorageError.from(error, path: target.projectDir(name).path)
            }
            moved.append(name)
        }
        return moved
    }
}
