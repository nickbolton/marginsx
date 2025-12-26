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
    abstract: "Capture a snapshot of the current source state (no mutation)."
  )

  func run() throws {
    let repoRoot = try gitRepoRoot()
    try ensureCleanGitState(at: repoRoot)

    let commit = try gitCommitHash(at: repoRoot)

    let packages = try discoverPackages(repoRoot: repoRoot)
    let spmFiles = Set(packages.flatMap { $0.sources + $0.tests })

    let (xcodeSources, xcodeTests) = try discoverXcodeOnlySources(
      repoRoot: repoRoot,
      excluding: spmFiles
    )

    let snapshot = SnapshotModel(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      gitCommit: commit,
      repoRoot: repoRoot.path,
      packages: packages,
      xcodeSources: xcodeSources,
      xcodeTests: xcodeTests
    )

    try writeSnapshot(snapshot, repoRoot: repoRoot)

    print("✔ Snapshot captured")
    print("  Commit: \(commit)")
    print("  Packages: \(packages.count)")
    print("  Xcode sources: \(xcodeSources.count)")
    print("  Xcode tests: \(xcodeTests.count)")
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

// MARK: - Snapshot Model

struct SnapshotModel: Codable {
  let timestamp: String
  let gitCommit: String
  let repoRoot: String
  let packages: [PackageSnapshot]
  let xcodeSources: [String]
  let xcodeTests: [String]
}

struct PackageSnapshot: Codable {
  let name: String
  let path: String
  let sources: [String]
  let tests: [String]
}

// MARK: - Package Discovery (SPM)

func discoverPackages(repoRoot: URL) throws -> [PackageSnapshot] {
  let fm = FileManager.default
  let enumerator = fm.enumerator(
    at: repoRoot,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
  )

  var packages: [PackageSnapshot] = []

  while let fileURL = enumerator?.nextObject() as? URL {
    guard fileURL.lastPathComponent == "Package.swift" else { continue }

    let packageDir = fileURL.deletingLastPathComponent()
    let packageName = packageDir.lastPathComponent

    let sourcesDir = packageDir.appendingPathComponent("Sources")
    let testsDir = packageDir.appendingPathComponent("Tests")

    let sources = collectSwiftFiles(root: sourcesDir, repoRoot: repoRoot)
    let tests = collectSwiftFiles(root: testsDir, repoRoot: repoRoot)

    packages.append(
      PackageSnapshot(
        name: packageName,
        path: relativePath(packageDir, base: repoRoot),
        sources: sources.sorted(),
        tests: tests.sorted()
      )
    )
  }

  return packages.sorted { $0.name < $1.name }
}

// MARK: - Xcode-only Source Discovery

func discoverXcodeOnlySources(
  repoRoot: URL,
  excluding spmFiles: Set<String>
) throws -> ([String], [String]) {

  let fm = FileManager.default
  let enumerator = fm.enumerator(
    at: repoRoot,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
  )

  var sources: [String] = []
  var tests: [String] = []

  while let fileURL = enumerator?.nextObject() as? URL {
    guard fileURL.pathExtension == "swift" else { continue }

    let relative = relativePath(fileURL, base: repoRoot)

    // Skip SPM-owned files
    if spmFiles.contains(relative) { continue }

    // Skip snapshot/flatten artifacts
    if relative.hasPrefix(".marginsx/") { continue }

    // Classify tests vs sources
    if isTestPath(relative) {
      tests.append(relative)
    } else {
      sources.append(relative)
    }
  }

  return (sources.sorted(), tests.sorted())
}

func isTestPath(_ path: String) -> Bool {
  path.contains("/Tests/") ||
  path.hasSuffix("Tests.swift") ||
  path.contains("Test/")
}

// MARK: - File Helpers

func collectSwiftFiles(root: URL, repoRoot: URL) -> [String] {
  let fm = FileManager.default
  guard fm.fileExists(atPath: root.path) else { return [] }

  let enumerator = fm.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
  )

  var results: [String] = []

  while let fileURL = enumerator?.nextObject() as? URL {
    guard fileURL.pathExtension == "swift" else { continue }
    results.append(relativePath(fileURL, base: repoRoot))
  }

  return results
}

func relativePath(_ url: URL, base: URL) -> String {
  let basePath = base.standardizedFileURL.path
  let fullPath = url.standardizedFileURL.path

  guard fullPath.hasPrefix(basePath) else {
    return fullPath
  }

  return String(fullPath.dropFirst(basePath.count + 1))
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
    throw ValidationError(
      "Git working tree is dirty. Commit or stash changes before running snapshot."
    )
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
  let snapshotDir = repoRoot
    .appendingPathComponent(".marginsx/snapshot", isDirectory: true)

  try FileManager.default.createDirectory(
    at: snapshotDir,
    withIntermediateDirectories: true
  )

  let fileURL = snapshotDir.appendingPathComponent("snapshot.json")

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

  let data = try encoder.encode(snapshot)
  try data.write(to: fileURL, options: [.atomic])
}

// MARK: - Errors

struct RuntimeError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
