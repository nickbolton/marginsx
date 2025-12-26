import Foundation
import ArgumentParser
import CryptoKit

// MARK: - Snapshot Command

struct Snapshot: ParsableCommand {

  static let configuration = CommandConfiguration(
    abstract: "Capture a filesystem-authoritative snapshot using SwiftPM-assisted import closure."
  )

  @Option(
    name: [.customLong("target")],
    parsing: .unconditionalSingleValue,
    help: "Target spec: <target-name>[=<entry-folder>]. Repeatable."
  )
  var targetSpecs: [String] = []

  func run() throws {
    let repoRoot = try Git.repoRoot()
    try Git.ensureCleanWorkingTree(at: repoRoot)

    guard !targetSpecs.isEmpty else {
      throw ValidationError("At least one --target must be specified.")
    }

    let targets = try parseTargetSpecs(targetSpecs, repoRoot: repoRoot)
    let gitIgnore = GitIgnore.load(from: repoRoot)
    let commit = try Git.commitHash(at: repoRoot)

    let packages = try discoverPackages(
      repoRoot: repoRoot,
      gitIgnore: gitIgnore
    )

    let packageIndex = try PackageIndex.load(
      packages: packages,
      repoRoot: repoRoot
    )

    let repoFiles = try discoverRepoFiles(
      repoRoot: repoRoot,
      packages: packages,
      gitIgnore: gitIgnore
    )

    let importIndex = buildImportIndex(
      repoFiles,
      repoRoot: repoRoot
    )

    let resolvedTargets = resolveTargets(
      targets: targets,
      repoFiles: repoFiles,
      importIndex: importIndex,
      packageIndex: packageIndex
    )

    let snapshot = SnapshotModel(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      gitCommit: commit,
      repoRoot: repoRoot.path,
      packages: packages,
      targets: resolvedTargets
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
  let targets: [TargetSnapshot]
}

struct TargetSnapshot: Codable {
  let name: String
  let repoFiles: [RepoFile]
}

struct PackageSnapshot: Codable {
  let name: String
  let rootPath: String
}

struct RepoFile: Codable, Hashable {
  let path: String
  let owner: Owner
  let kind: FileKind
}

enum Owner: Codable, Hashable {
  case repo
  case package(String)
}

enum FileKind: String, Codable {
  case source
  case test
  case resource
  case other
}

// MARK: - Target Specs

struct TargetSpec {
  let name: String
  let entryFolder: String
}

func parseTargetSpecs(
  _ raw: [String],
  repoRoot: URL
) throws -> [TargetSpec] {

  try raw.map { spec in
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ValidationError("Empty --target value.")
    }

    let parts = trimmed.split(
      separator: "=",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )

    let name = parts[0].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else {
      throw ValidationError("Missing target name in --target '\(spec)'.")
    }

    let entryFolder: String
    if parts.count == 2 {
      entryFolder = parts[1].trimmingCharacters(in: .whitespaces)
      guard !entryFolder.isEmpty else {
        throw ValidationError("Empty entry folder in --target '\(spec)'.")
      }
    } else {
      entryFolder = name
    }

    let folderURL = repoRoot.appendingPathComponent(entryFolder)
    var isDir: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: folderURL.path,
        isDirectory: &isDir
      ),
      isDir.boolValue
    else {
      throw ValidationError(
        "Target entry folder does not exist or is not a directory: \(entryFolder)"
      )
    }

    return TargetSpec(name: name, entryFolder: entryFolder)
  }
}

// MARK: - Package Discovery

func discoverPackages(
  repoRoot: URL,
  gitIgnore: GitIgnore
) throws -> [PackageSnapshot] {

  let fm = FileManager.default
  let enumerator = fm.enumerator(at: repoRoot, includingPropertiesForKeys: nil)

  var packages: [PackageSnapshot] = []

  while let url = enumerator?.nextObject() as? URL {
    let relative = relativePath(url, base: repoRoot)
    if gitIgnore.matches(relative) { continue }

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

// MARK: - Package Index (SwiftPM describe + caching)

struct PackageIndex {
  let modules: [String: Set<RepoFile>]

  static func load(
    packages: [PackageSnapshot],
    repoRoot: URL
  ) throws -> PackageIndex {

    let cacheRoot = repoRoot.appendingPathComponent(".marginsx/cache/swiftpm")
    try FileManager.default.createDirectory(
      at: cacheRoot,
      withIntermediateDirectories: true
    )

    var modules: [String: Set<RepoFile>] = [:]

    for pkg in packages {
      let pkgRoot = repoRoot.appendingPathComponent(pkg.rootPath)
      let packageSwift = pkgRoot.appendingPathComponent("Package.swift")

      let hash = try sha256(of: packageSwift)
      let cacheFile = cacheRoot.appendingPathComponent("\(pkg.name)-\(hash).json")

      let describe: SwiftPMDescribe

      if FileManager.default.fileExists(atPath: cacheFile.path) {
        let data = try Data(contentsOf: cacheFile)
        describe = try JSONDecoder().decode(SwiftPMDescribe.self, from: data)
      } else {
        describe = try runSwiftPackageDescribe(at: pkgRoot)
        let data = try JSONEncoder().encode(describe)
        try data.write(to: cacheFile, options: .atomic)
      }

      for target in describe.targets where target.type == "regular" {
        var files: Set<RepoFile> = []

        for src in target.sources {
          files.insert(
            RepoFile(
              path: "\(pkg.rootPath)/\(target.path)/\(src)",
              owner: .package(pkg.name),
              kind: .source
            )
          )
        }

        for res in target.resources {
          files.insert(
            RepoFile(
              path: "\(pkg.rootPath)/\(target.path)/\(res)",
              owner: .package(pkg.name),
              kind: .resource
            )
          )
        }

        modules[target.name] = files
      }
    }

    return PackageIndex(modules: modules)
  }
}

// MARK: - SwiftPM describe --type json

struct SwiftPMDescribe: Codable {
  struct Target: Codable {
    let name: String
    let type: String
    let path: String
    let sources: [String]
    let resources: [String]
  }
  let targets: [Target]
}

func runSwiftPackageDescribe(at url: URL) throws -> SwiftPMDescribe {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
  process.arguments = ["package", "describe", "--type", "json"]
  process.currentDirectoryURL = url

  let outPipe = Pipe()
  let errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe

  try process.run()
  process.waitUntilExit()

  let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
  let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()

  guard process.terminationStatus == 0 else {
    let msg = String(data: stderr, encoding: .utf8) ?? "<no stderr>"
    throw SwiftPMError.describeFailed(
      packagePath: url.path,
      exitCode: Int(process.terminationStatus),
      stderr: msg
    )
  }

  return try JSONDecoder().decode(SwiftPMDescribe.self, from: stdout)
}

enum SwiftPMError: Error, CustomStringConvertible {
  case describeFailed(packagePath: String, exitCode: Int, stderr: String)

  var description: String {
    switch self {
    case let .describeFailed(packagePath, exitCode, stderr):
      return """
      swift package describe failed
        package: \(packagePath)
        exitCode: \(exitCode)
        stderr: \(stderr)
      """
    }
  }
}

// MARK: - Repo Discovery

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

    let kind = classifyFile(relative)
    guard kind != .other else { continue }

    files.append(
      RepoFile(
        path: relative,
        owner: owningPackage(for: relative, packages: packages),
        kind: kind
      )
    )
  }

  return files
}

// MARK: - Import Index

func buildImportIndex(
  _ files: [RepoFile],
  repoRoot: URL
) -> [RepoFile: Set<String>] {

  var index: [RepoFile: Set<String>] = [:]

  for file in files where file.kind == .source {
    let url = repoRoot.appendingPathComponent(file.path)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      continue
    }

    let imports = contents
      .split(separator: "\n")
      .compactMap { line -> String? in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("import ") else { return nil }
        return t
          .replacingOccurrences(of: "import ", with: "")
          .split(separator: " ")
          .first
          .map(String.init)
      }

    index[file] = Set(imports)
  }

  return index
}

// MARK: - Target Resolution (Import Closure)

func resolveTargets(
  targets: [TargetSpec],
  repoFiles: [RepoFile],
  importIndex: [RepoFile: Set<String>],
  packageIndex: PackageIndex
) -> [TargetSnapshot] {

  let repoFileSet = Set(repoFiles)

  return targets.map { target in
    var visitedFiles: Set<RepoFile> = []
    var visitedModules: Set<String> = []
    var queue = repoFiles.filter {
      $0.kind == .source &&
      $0.path.hasPrefix(target.entryFolder + "/")
    }

    while let file = queue.popLast() {
      guard visitedFiles.insert(file).inserted else { continue }

      for module in importIndex[file] ?? [] {

        if let pkgFiles = packageIndex.modules[module],
           visitedModules.insert(module).inserted {
          visitedFiles.formUnion(pkgFiles)
          continue
        }

        for candidate in repoFileSet where
          candidate.owner == .repo &&
          candidate.kind == .source &&
          candidate.path.hasSuffix("/\(module).swift") &&
          !visitedFiles.contains(candidate) {
          queue.append(candidate)
        }
      }
    }

    return TargetSnapshot(
      name: target.name,
      repoFiles: visitedFiles.sorted { $0.path < $1.path }
    )
  }
}

// MARK: - Exclusion / Helpers

let excludedPathComponents: Set<String> = [
  ".git", ".build", ".swiftpm", "DerivedData",
  "XCBuildData", "Pods", "Carthage",
  ".marginsx", ".DS_Store", ".github"
]

struct GitIgnore {
  let patterns: [String]

  static func load(from root: URL) -> GitIgnore {
    let path = root.appendingPathComponent(".gitignore")
    let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    return GitIgnore(patterns: text.split(separator: "\n").map(String.init))
  }

  func matches(_ path: String) -> Bool {
    patterns.contains { path.contains($0) }
  }
}

func isExcluded(
  _ path: String,
  gitIgnore: GitIgnore,
  packages: [PackageSnapshot]
) -> Bool {

  let components = path.split(separator: "/").map(String.init)
  if components.contains(where: excludedPathComponents.contains) {
    return true
  }

  for pkg in packages where path.hasPrefix(pkg.rootPath + "/") {
    if components.contains("build") || components.contains("\(pkg.name).build") {
      return true
    }
  }

  return gitIgnore.matches(path)
}

func owningPackage(
  for path: String,
  packages: [PackageSnapshot]
) -> Owner {

  for pkg in packages where path.hasPrefix(pkg.rootPath + "/") {
    return .package(pkg.name)
  }
  return .repo
}

func classifyFile(_ path: String) -> FileKind {
  if path.hasSuffix(".swift") {
    return path.contains("/Tests/") ? .test : .source
  }
  if path.contains(".xcassets") || path.contains("/Resources/") {
    return .resource
  }
  return .other
}

func relativePath(_ url: URL, base: URL) -> String {
  let basePath = base.standardizedFileURL.path
  let fullPath = url.standardizedFileURL.path
  guard fullPath.hasPrefix(basePath) else { return fullPath }
  return String(fullPath.dropFirst(basePath.count + 1))
}

// MARK: - Hashing

func sha256(of file: URL) throws -> String {
  let data = try Data(contentsOf: file)
  let hash = SHA256.hash(data: data)
  return hash.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Output

func writeSnapshot(
  _ snapshot: SnapshotModel,
  repoRoot: URL
) throws {

  let dir = repoRoot.appendingPathComponent(".marginsx/snapshot")
  try FileManager.default.createDirectory(
    at: dir,
    withIntermediateDirectories: true
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

  let data = try encoder.encode(snapshot)
  try data.write(
    to: dir.appendingPathComponent("snapshot.json"),
    options: .atomic
  )
}

func printSnapshotSummary(_ snapshot: SnapshotModel) {
  print("✔ Snapshot captured")
  print("  Commit: \(snapshot.gitCommit)")
  print("  Targets: \(snapshot.targets.count)")
  for t in snapshot.targets {
    print("    \(t.name): \(t.repoFiles.count) files")
  }
  print("  Snapshot written to: .marginsx/snapshot/snapshot.json")
}
