import Foundation

/// Locates the cross-language fixtures in `protocol/fixtures` at the repo root.
/// The Kotlin tests read the same files, which is what keeps the two
/// implementations of the protocol in agreement.
enum Fixtures {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // InkBridgeCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // macos
    .deletingLastPathComponent()  // apps
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("protocol/fixtures")

  static func files(_ dir: String) throws -> [URL] {
    try FileManager.default
      .contentsOfDirectory(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  static func data(_ path: String) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(path))
  }
}
