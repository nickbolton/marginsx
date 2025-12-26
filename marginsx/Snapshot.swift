import Foundation
import ArgumentParser

// MARK: - Snapshot Command

struct Snapshot: ParsableCommand {

  static let configuration = CommandConfiguration(
    abstract: "Capture a filesystem-authoritative snapshot of the repo."
  )

  func run() throws {
    let repoRoot = try Git.repoRoot()
    try Git.ensureCleanWorkingTree(at: repoRoot)

    let gitIgnore = GitIgnore.load(from: repoRoot)
    let commit = try Git.commitHash(at: repoRoot)

    let packages = try discoverPackages(
      repoRoot: repoRoot,
      gitIgnore: gitIgnore
    )

    let repoFiles = try discoverRepoFiles(
      repoRoot: repoRoot,
      packages: packages,
      gitIgnore: gitIgnore
    )

    let snapshot = SnapshotModel(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      gitCommit: commit,
      repoRoot: repoRoot.path,
      packages: packages,
      repoFiles: repoFiles
    )

    try writeSnapshot(snapshot, repoRoot: repoRoot)
    printSnapshotSummary(snapshot)
  }
}

// MARK: - Models

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
  case repo
  case package(String)
}

enum FileKind: String, Codable {
  case source
  case test
  case resource
  case other
}

// MARK: - Hard-coded Exclusions

let excludedPathComponents: Set<String> = [
  ".git",
  ".build",
  ".swiftpm",
  "DerivedData",
  "XCBuildData",
  "Pods",
  "Carthage",
  ".marginsx",
  ".DS_Store",
  ".github"
]

// MARK: - GitIgnore

struct GitIgnore {

  enum Pattern {
    case directory(String)
    case suffix(String)
    case exact(String)
  }

  let patterns: [Pattern]

  static func load(from repoRoot: URL) -> GitIgnore {
    let path = repoRoot.appendingPathComponent(".gitignore")

    guard
      let contents = try? String(contentsOf: path, encoding: .utf8)
    else {
      return GitIgnore(patterns: [])
    }

    let patterns: [Pattern] = contents
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .compactMap { line in
        if line.hasSuffix("/") {
          return .directory(String(line.dropLast()))
        }
        if line.hasPrefix("*.") {
          return .suffix(String(line.dropFirst()))
        }
        return .exact(line)
      }

    return GitIgnore(patterns: patterns)
  }

  func matches(_ path: String) -> Bool {
    for pattern in patterns {
      switch pattern {
      case .directory(let dir):
        if path.split(separator: "/").contains(Substring(dir)) {
          return true
        }
      case .suffix(let suffix):
        if path.hasSuffix(suffix) {
          return true
        }
      case .exact(let exact):
        if path == exact || path.hasPrefix(exact + "/") {
          return true
        }
      }
    }
    return false
  }
}

// MARK: - Discovery

func discoverPackages(
  repoRoot: URL,
  gitIgnore: GitIgnore
) throws -> [PackageSnapshot] {

  let fm = FileManager.default
  let enumerator = fm.enumerator(at: repoRoot, includingPropertiesForKeys: nil)

  var packages: [PackageSnapshot] = []

  while let url = enumerator?.nextObject() as? URL {
    let relative = relativePath(url, base: repoRoot)
    if isExcluded(relative, gitIgnore: gitIgnore, packages: []) { continue }

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
  packages: [PackageSnapshot],
  gitIgnore: GitIgnore
) throws -> [RepoFile] {

  let fm = FileManager.default
  let enumerator = fm.enumerator(at: repoRoot, includingPropertiesForKeys: nil)

  var files: [RepoFile] = []

  while let url = enumerator?.nextObject() as? URL {
    let relative = relativePath(url, base: repoRoot)

    if isExcluded(relative, gitIgnore: gitIgnore, packages: packages) {
      continue
    }

    var isDir: ObjCBool = false
    fm.fileExists(atPath: url.path, isDirectory: &isDir)
    if isDir.boolValue { continue }

    let owner = owningPackage(for: relative, packages: packages)
    let kind = classifyFile(relative)

    files.append(
      RepoFile(path: relative, owner: owner, kind: kind)
    )
  }

  return files.sorted { $0.path < $1.path }
}

// MARK: - Exclusion Logic (CRITICAL FIX)

func isExcluded(
  _ path: String,
  gitIgnore: GitIgnore,
  packages: [PackageSnapshot]
) -> Bool {

  let components = path.split(separator: "/").map(String.init)

  // Global exclusions
  if components.contains(where: { excludedPathComponents.contains($0) }) {
    return true
  }

  // Package-scoped build artifact exclusions
  for package in packages {
    if path.hasPrefix(package.rootPath + "/") {

      // Xcode-style build/
      if components.contains("build") {
        return true
      }

      // SwiftPM-style <PackageName>.build/
      if components.contains("\(package.name).build") {
        return true
      }
    }
  }

  // .gitignore
  if gitIgnore.matches(path) {
    return true
  }

  return false
}

// MARK: - Ownership

func owningPackage(
  for path: String,
  packages: [PackageSnapshot]
) -> Owner {

  for package in packages {
    if path.hasPrefix(package.rootPath + "/") {
      return .package(package.name)
    }
  }

  return .repo
}

// MARK: - Classification (CONSERVATIVE)

func classifyFile(_ path: String) -> FileKind {
  if path.hasSuffix(".swift") {
    return path.contains("/Tests/") ? .test : .source
  }

  if path.contains("/Resources/") ||
     path.contains(".xcassets/") ||
     path.contains(".lproj/") {
    return .resource
  }

  let standaloneResourceExtensions = [
    "png", "jpg", "jpeg", "svg",
    "ttf", "otf", "strings"
  ]

  if standaloneResourceExtensions.contains(where: { path.hasSuffix(".\($0)") }) {
    return .resource
  }

  return .other
}

// MARK: - Snapshot Output

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

func printSnapshotSummary(_ snapshot: SnapshotModel) {
  let byKind = Dictionary(grouping: snapshot.repoFiles, by: { $0.kind })

  print("✔ Snapshot captured")
  print("  Commit: \(snapshot.gitCommit)")
  print("  Packages: \(snapshot.packages.count)")
  print("  Files: \(snapshot.repoFiles.count)")
  print("    Sources:   \(byKind[.source]?.count ?? 0)")
  print("    Tests:     \(byKind[.test]?.count ?? 0)")
  print("    Resources: \(byKind[.resource]?.count ?? 0)")
  print("    Other:     \(byKind[.other]?.count ?? 0)")
  print("  Snapshot written to: .marginsx/snapshot/snapshot.json")
}

// MARK: - Utilities

func relativePath(_ url: URL, base: URL) -> String {
  let basePath = base.standardizedFileURL.path
  let fullPath = url.standardizedFileURL.path
  guard fullPath.hasPrefix(basePath) else { return fullPath }
  return String(fullPath.dropFirst(basePath.count + 1))
}
