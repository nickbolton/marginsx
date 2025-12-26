import Foundation

// MARK: - Git Helpers

enum Git {

  static func repoRoot() throws -> URL {
    let output = try run(["rev-parse", "--show-toplevel"])
    return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func commitHash(at repoRoot: URL) throws -> String {
    try run(["rev-parse", "HEAD"], cwd: repoRoot)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func ensureCleanWorkingTree(at repoRoot: URL) throws {
    let status = try run(["status", "--porcelain"], cwd: repoRoot)
    if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw GitError.dirtyWorkingTree
    }
  }

  // MARK: - Private

  private static func run(
    _ args: [String],
    cwd: URL? = nil
  ) throws -> String {

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + args
    process.currentDirectoryURL = cwd

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)

    if process.terminationStatus != 0 {
      throw GitError.commandFailed(output)
    }

    return output
  }
}

// MARK: - Errors

enum GitError: Error, CustomStringConvertible {
  case dirtyWorkingTree
  case commandFailed(String)

  var description: String {
    switch self {
    case .dirtyWorkingTree:
      return "Git working tree is dirty. Commit or stash changes before proceeding."
    case .commandFailed(let output):
      return output
    }
  }
}
