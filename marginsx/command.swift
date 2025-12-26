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
    let spmSources = Set(packages.flatMap { $0.sources })
    let spmTests   = Set(packages.flatMap { $0.tests })
    let spmOwned   = spmSources.union(spmTests)

    let xcodeOwned = try discoverXcodeCompiledSwiftFiles(repoRoot: repoRoot)

    let allSwift = try discoverAllSwiftFiles(repoRoot: repoRoot)

    let xcodeSources = xcodeOwned
      .subtracting(spmOwned)
      .filter { !isTestPath($0) }
      .sorted()

    let xcodeTests = xcodeOwned
      .subtracting(spmOwned)
      .filter { isTestPath($0) }
      .sorted()

    let orphanSwiftFiles = allSwift
      .subtracting(spmOwned)
      .subtracting(xcodeOwned)
      .sorted()

    let snapshot = SnapshotModel(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      gitCommit: commit,
      repoRoot: repoRoot.path,
      packages: packages,
      xcodeSources: xcodeSources,
      xcodeTests: xcodeTests,
      orphanSwiftFiles: orphanSwiftFiles
    )

    try writeSnapshot(snapshot, repoRoot: repoRoot)

    print("✔ Snapshot captured")
    print("  Commit: \(commit)")
    print("  Packages: \(packages.count)")
    print("  Xcode sources: \(xcodeSources.count)")
    print("  Xcode tests: \(xcodeTests.count)")
    if !orphanSwiftFiles.isEmpty {
      print("  ⚠️ Orphan Swift files: \(orphanSwiftFiles.count)")
    }
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
  let orphanSwiftFiles: [String]
}

struct PackageSnapshot: Codable {
  let name: String
  let path: String
  let sources: [String]
  let tests: [String]
}

// MARK: - Discovery Layer 0: All Swift Files

func discoverAllSwiftFiles(repoRoot: URL) throws -> Set<String> {
  let fm = FileManager.default
  let enumerator = fm.enumerator(
    at: repoRoot,
    includingPropertiesForKeys: nil,
    options: []
  )

  var results: Set<String> = []

  while let url = enumerator?.nextObject() as? URL {
    guard url.pathExtension == "swift" else { continue }
    let relative = relativePath(url, base: repoRoot)
    guard !relative.hasPrefix(".marginsx/") else { continue }
    results.insert(relative)
  }

  return results
}

// MARK: - Discovery Layer 1: SPM Packages

func discoverPackages(repoRoot: URL) throws -> [PackageSnapshot] {
  let fm = FileManager.default
  let enumerator = fm.enumerator(
    at: repoRoot,
    includingPropertiesForKeys: nil,
    options: []
  )

  var packages: [PackageSnapshot] = []

  while let fileURL = enumerator?.nextObject() as? URL {
    guard fileURL.lastPathComponent == "Package.swift" else { continue }

    let packageDir = fileURL.deletingLastPathComponent()
    let name = packageDir.lastPathComponent

    let sources = collectSwiftFiles(root: packageDir.appendingPathComponent("Sources"), repoRoot: repoRoot)
    let tests = collectSwiftFiles(root: packageDir.appendingPathComponent("Tests"), repoRoot: repoRoot)

    packages.append(
      PackageSnapshot(
        name: name,
        path: relativePath(packageDir, base: repoRoot),
        sources: sources.sorted(),
        tests: tests.sorted()
      )
    )
  }

  return packages.sorted { $0.name < $1.name }
}

// MARK: - Discovery Layer 2: Xcode Compiled Swift Files (PBXProj)

func discoverXcodeCompiledSwiftFiles(repoRoot: URL) throws -> Set<String> {
  let pbxprojURLs = try findPBXProjFiles(repoRoot: repoRoot)
  var results: Set<String> = []

  for pbxprojURL in pbxprojURLs {
    let pbx = try PBXProj.parse(contentsOf: pbxprojURL)

    // Source root for path resolution is the directory containing the .xcodeproj bundle.
    // Example: Foo/Foo.xcodeproj/project.pbxproj -> sourceRoot = Foo/
    let xcodeprojDir = pbxprojURL.deletingLastPathComponent()           // .../Foo.xcodeproj
    let sourceRoot = xcodeprojDir.deletingLastPathComponent()           // .../Foo/

    for swiftPath in pbx.compiledSwiftPaths(sourceRoot: sourceRoot) {
      let fileURL = sourceRoot.appendingPathComponent(swiftPath)

      // Only include real files on disk.
      if FileManager.default.fileExists(atPath: fileURL.path) {
        results.insert(relativePath(fileURL, base: repoRoot))
      }
    }
  }

  return results
}

func findPBXProjFiles(repoRoot: URL) throws -> [URL] {
  let fm = FileManager.default
  let enumerator = fm.enumerator(
    at: repoRoot,
    includingPropertiesForKeys: nil,
    options: []
  )

  var results: [URL] = []

  while let url = enumerator?.nextObject() as? URL {
    guard url.lastPathComponent == "project.pbxproj" else { continue }
    // Skip derived artifacts
    let rel = relativePath(url, base: repoRoot)
    guard !rel.hasPrefix(".marginsx/") else { continue }
    results.append(url)
  }

  return results
}

// MARK: - Minimal PBXProj Parser

fileprivate struct PBXProj {
  /// buildFileID -> fileRefID
  let buildFileToFileRef: [String: String]
  /// fileRefID -> (path, sourceTree)
  let fileRefToPath: [String: PBXFileRef]

  struct PBXFileRef {
    let path: String
    let sourceTree: String
  }

  static func parse(contentsOf pbxprojURL: URL) throws -> PBXProj {
    let text = try String(contentsOf: pbxprojURL, encoding: .utf8)

    // Parse PBXBuildFile entries: <ID> = { isa = PBXBuildFile; fileRef = <REFID> ...; };
    var buildFileToFileRef: [String: String] = [:]
    var fileRefToPath: [String: PBXFileRef] = [:]

    // This is intentionally minimal and line-oriented.
    // It works because pbxproj entries are typically single-line for these objects.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

      // PBXBuildFile
      // Example:
      //   ABCDEF1234567890 /* Foo.swift in Sources */ = {isa = PBXBuildFile; fileRef = 0123456789ABCDEF /* Foo.swift */; };
      if line.contains("isa = PBXBuildFile") || line.contains("isa=PBXBuildFile") {
        if let id = extractLeadingID(from: line),
           let fileRef = extractFieldID(named: "fileRef", from: line) {
          buildFileToFileRef[id] = fileRef
        }
        continue
      }

      // PBXFileReference
      // Example:
      //   0123456789ABCDEF /* Foo.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Foo.swift; sourceTree = "<group>"; };
      if line.contains("isa = PBXFileReference") || line.contains("isa=PBXFileReference") {
        guard let id = extractLeadingID(from: line) else { continue }

        // Restrict to Swift-ish file refs early to keep this fast.
        guard line.contains("sourcecode.swift") || line.contains(".swift") else { continue }

        guard let path = extractFieldString(named: "path", from: line) ?? extractFieldString(named: "name", from: line) else {
          continue
        }
        let sourceTree = extractFieldString(named: "sourceTree", from: line) ?? "\"<group>\""
        let normalizedSourceTree = trimPBXString(sourceTree)

        fileRefToPath[id] = PBXFileRef(path: trimPBXString(path), sourceTree: normalizedSourceTree)
        continue
      }
    }

    return PBXProj(buildFileToFileRef: buildFileToFileRef, fileRefToPath: fileRefToPath)
  }

  func compiledSwiftPaths(sourceRoot: URL) -> Set<String> {
    var results: Set<String> = []

    for (_, fileRefID) in buildFileToFileRef {
      guard let fileRef = fileRefToPath[fileRefID] else { continue }
      guard fileRef.path.hasSuffix(".swift") else { continue }

      // Resolve relative paths based on sourceTree.
      // We support the common cases:
      // - <group>   -> treat as relative to sourceRoot
      // - SOURCE_ROOT -> relative to sourceRoot
      // - absolute paths -> keep absolute
      let p = fileRef.path
      if p.hasPrefix("/") {
        // Absolute path
        let abs = URL(fileURLWithPath: p).standardizedFileURL.path
        // Convert to sourceRoot-relative if possible; otherwise skip (outside repo).
        let sr = sourceRoot.standardizedFileURL.path
        if abs.hasPrefix(sr + "/") {
          results.insert(String(abs.dropFirst(sr.count + 1)))
        }
      } else {
        // Treat as relative to sourceRoot (good enough for most repos).
        results.insert(p)
      }
    }

    return results
  }
}

// MARK: - PBX Parsing Helpers

fileprivate func extractLeadingID(from line: String) -> String? {
  // Leading token is the object ID (typically 24 hex chars).
  // Example: "ABCDEF... /* comment */ = { ... }"
  let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let firstSpace = trimmed.firstIndex(of: " ") else { return nil }
  let id = String(trimmed[..<firstSpace])
  guard id.count >= 8 else { return nil }
  return id
}

fileprivate func extractFieldID(named name: String, from line: String) -> String? {
  // Matches: "fileRef = 0123456789ABCDEF /* Foo.swift */;"
  guard let range = line.range(of: "\(name) = ") else { return nil }
  let after = line[range.upperBound...]
  // ID ends at first space or semicolon
  if let end = after.firstIndex(where: { $0 == " " || $0 == ";" }) {
    return String(after[..<end])
  }
  return nil
}

fileprivate func extractFieldString(named name: String, from line: String) -> String? {
  // Matches both quoted and unquoted values:
  // path = Foo.swift;
  // sourceTree = "<group>";
  guard let range = line.range(of: "\(name) = ") else { return nil }
  var after = line[range.upperBound...]
  // Cut at semicolon
  if let semi = after.firstIndex(of: ";") {
    after = after[..<semi]
  }
  return after.trimmingCharacters(in: .whitespaces)
}

fileprivate func trimPBXString(_ value: String) -> String {
  var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
  if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
    v.removeFirst()
    v.removeLast()
  }
  return v
}

// MARK: - Helper Functions

func isTestPath(_ path: String) -> Bool {
  path.contains("/Tests/") || path.hasSuffix("Tests.swift")
}

func collectSwiftFiles(root: URL, repoRoot: URL) -> [String] {
  let fm = FileManager.default
  guard fm.fileExists(atPath: root.path) else { return [] }

  let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)
  var results: [String] = []

  while let url = enumerator?.nextObject() as? URL {
    guard url.pathExtension == "swift" else { continue }
    results.append(relativePath(url, base: repoRoot))
  }

  return results
}

func relativePath(_ url: URL, base: URL) -> String {
  let basePath = base.standardizedFileURL.path
  let fullPath = url.standardizedFileURL.path
  guard fullPath.hasPrefix(basePath) else { return fullPath }
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
    throw ValidationError("Git working tree is dirty. Commit or stash changes before running snapshot.")
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
  try data.write(to: dir.appendingPathComponent("snapshot.json"), options: .atomic)
}

// MARK: - Errors

struct RuntimeError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
