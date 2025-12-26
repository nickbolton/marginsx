import Foundation
import ArgumentParser

// MARK: - Entry Point

@main
struct MarginsX: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "marginsx",
    abstract: "Flatten and rehydrate large Swift/Xcode projects.",
    subcommands: [
      Snapshot.self,
      Flatten.self,
      Rehydrate.self
    ]
  )
}

// MARK: - Snapshot Command

struct Snapshot: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Capture a filesystem-authoritative snapshot of the repo (no mutation)."
  )

  func run() throws {
    let repoRoot = try gitRepoRoot()
    try ensureCleanGitState(at: repoRoot)

    let commit = try gitCommitHash(at: repoRoot)

    let packages = try discoverPackages(repoRoot: repoRoot)
    let packageRoots = Dictionary(uniqueKeysWithValues: packages.map {
      ($0.rootPath, $0.name)
    })

    let repoFiles = try discoverRepoFiles(
      repoRoot: repoRoot,
      packageRoots: packageRoots
    )

    let snapshot = SnapshotModel(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      gitCommit: commit,
      repoRoot: repoRoot.path,
      packages: packages,
      repoFiles: repoFiles
    )

    try writeSnapshot(snapshot, repoRoot: repoRoot)

    print("✔ Snapshot captured")
    print("  Commit: \(commit)")
    print("  Packages: \(packages.count)")
    print("  Files: \(repoFiles.count)")
  }
}

// MARK: - Flatten Command (stub)

struct Flatten: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Flatten the project using the current snapshot."
  )

  func run() throws {
    print("flatten: not yet implemented")
  }
}

// MARK: - Rehydrate Command (stub)

struct Rehydrate: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Rehydrate the source project from a flattened build."
  )

  func run() throws {
    print("rehydrate: not yet implemented")
  }
}

// MARK: - Snapshot Models

struct SnapshotModel: Codable {
  let timestamp: String
  let gitCommit: String
  let repoRoot: String
  let packages: [PackageSnapshot]
  let repoFiles: [RepoFile]
}

struct PackageSnapshot: Codable {
  let name: String
  let rootPath: String
}

struct RepoFile: Codable {
  let path: String
  let owner: Owner
  let kind: FileKind
}

enum Owner: Codable {
  case package(String)
  case repo
}

enum FileKind: String, Codable {
  case source
  case test
  case resource
  case other
}

// MARK: - Discovery

func discoverPackages(repoRoot: URL) throws -> [PackageSnapshot] {
  let fm = FileManager.default
  let enumerator = fm.enumerator(at: repoRoot, includingPropertiesForKeys: nil)

  var packages: [PackageSnapshot] = []

  while let url = enumerator?.nextObject() as? URL {
    guard url.lastPathComponent == "Package.swift" else { continue }
    let root = url.deletingLastPathComponent()
    packages.append(
      PackageSnapshot(
        name: root.lastPathComponent,
        rootPath: relativePath(root, base: repoRoot)
      )
    )
  }

  return packages.sorted { $0.name < $1.name }
}

func discoverRepoFiles(
  repoRoot: URL,
  packageRoots: [String: String]
) throws -> [RepoFile] {

  let fm = FileManager.default
  let enumerator = fm.enumerator(at: repoRoot, includingPropertiesForKeys: nil)

  var results: [RepoFile] = []

  while let url = enumerator?.nextObject() as? URL {
    let relative = relativePath(url, base: repoRoot)

    // Skip directories
    var isDir: ObjCBool = false
    fm.fileExists(atPath: url.path, isDirectory: &isDir)
    if isDir.boolValue { continue }

    // Skip dot folders
    if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
      continue
    }

    let owner = owningPackage(
      for: relative,
      packageRoots: packageRoots
    )

    let kind = classifyFile(relative)

    results.append(
      RepoFile(
        path: relative,
        owner: owner,
        kind: kind
      )
    )
  }

  return results.sorted { $0.path < $1.path }
}

func owningPackage(
  for path: String,
  packageRoots: [String: String]
) -> Owner {

  var current = path

  while current.contains("/") {
    current = String(current.dropLast(current.count - (current.lastIndex(of: "/")?.utf16Offset(in: current) ?? 0)))
    if let pkg = packageRoots[current] {
      return .package(pkg)
    }
  }

  return .repo
}

// MARK: - Classification

func classifyFile(_ path: String) -> FileKind {
  if path.hasSuffix(".swift") {
    if path.contains("/Tests/") {
      return .test
    }
    return .source
  }

  let resourceExts = [
    "xcassets", "json", "plist",
    "ttf", "otf", "png", "jpg",
    "jpeg", "svg", "strings"
  ]

  if resourceExts.contains(where: { path.hasSuffix(".\($0)") }) {
    return .resource
  }

  return .other
}

// MARK: - Git Helpers

func gitRepoRoot() throws -> URL {
  let output = try runGit(["rev-parse", "--show-toplevel"])
  return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
}

func gitCommitHash(at repoRoot: URL) throws -> String {
  try runGit(["rev-parse", "HEAD"], cwd: repoRoot)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func ensureCleanGitState(at repoRoot: URL) throws {
  let status = try runGit(["status", "--porcelain"], cwd: repoRoot)
  if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw ValidationError("Git working tree is dirty.")
  }
}

func runGit(_ args: [String], cwd: URL? = nil) throws -> String {
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
    throw RuntimeError(output)
  }

  return output
}

// MARK: - Snapshot Writer

func writeSnapshot(_ snapshot: SnapshotModel, repoRoot: URL) throws {
  let dir = repoRoot.appendingPathComponent(".marginsx/snapshot", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

  let data = try encoder.encode(snapshot)
  try data.write(
    to: dir.appendingPathComponent("snapshot.json"),
    options: .atomic
  )
}

// MARK: - Utilities

func relativePath(_ url: URL, base: URL) -> String {
  let basePath = base.standardizedFileURL.path
  let fullPath = url.standardizedFileURL.path
  guard fullPath.hasPrefix(basePath) else { return fullPath }
  return String(fullPath.dropFirst(basePath.count + 1))
}

// MARK: - Errors

struct RuntimeError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
