import Foundation
import ArgumentParser

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

    let productIndex = try ProductIndex.load(
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
      productIndex: productIndex
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

// MARK: - Package Index (SwiftPM, no caching)

struct ProductIndex {
  struct ProductInfo {
    let packageName: String
    let files: Set<RepoFile>
  }

  /// Key = product name (what client code typically `import`s)
  let products: [String: ProductInfo]

  static func load(
    packages: [PackageSnapshot],
    repoRoot: URL
  ) throws -> ProductIndex {

    var products: [String: ProductInfo] = [:]

    for pkg in packages {
      let pkgRoot = repoRoot.appendingPathComponent(pkg.rootPath)

      print("• Resolving SwiftPM package \(pkg.name)…")
      let describe = try runSwiftPackageDescribe(at: pkgRoot)
      
      // 1) Build per-target file sets
      var targetFilesByName: [String: Set<RepoFile>] = [:]

      for target in describe.targets where target.type == "library" {
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
          let resURL = URL(fileURLWithPath: res.path)
          let relative = relativePath(resURL, base: repoRoot)
          files.insert(
            RepoFile(
              path: relative,
              owner: .package(pkg.name),
              kind: .resource
            )
          )
        }

        targetFilesByName[target.name] = files
      }

      // 2) Union files per product
      for product in describe.products {
        var union: Set<RepoFile> = []
        for tName in product.targets {
          if let tFiles = targetFilesByName[tName] {
            union.formUnion(tFiles)
          }
        }

        // If duplicates exist across packages, last-wins is dangerous.
        // Prefer first-wins to keep deterministic behavior, or log.
        if products[product.name] == nil {
          products[product.name] = ProductInfo(
            packageName: pkg.name,
            files: union
          )
        } else {
          // Optional: print a warning if you want visibility.
          // print("⚠️ Duplicate product name '\(product.name)' found in \(pkg.name)")
        }
      }
    }

    return ProductIndex(products: products)
  }
}

// MARK: - SwiftPM describe (temp file output)

func runSwiftPackageDescribe(at url: URL) throws -> SwiftPMDescribe {
  let fm = FileManager.default
  let tempDir = fm.temporaryDirectory
  let outFile = tempDir.appendingPathComponent("swiftpm-\(UUID().uuidString).json")
  let errFile = tempDir.appendingPathComponent("swiftpm-\(UUID().uuidString).err")
  
  func removeTemporaryFiles() {
    if fm.fileExists(atPath: outFile.path) {
      try? fm.removeItem(at: outFile)
    }
    
    if fm.fileExists(atPath: errFile.path) {
      try? fm.removeItem(at: errFile)
    }
  }
  
  defer {
    removeTemporaryFiles()
  }
    
  removeTemporaryFiles()
  fm.createFile(atPath: outFile.path, contents: nil)
  fm.createFile(atPath: errFile.path, contents: nil)
  
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
  process.arguments = ["package", "describe", "--type", "json"]
  process.currentDirectoryURL = url
  
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = try FileHandle(forWritingTo: outFile)
  process.standardError = try FileHandle(forWritingTo: errFile)
  
  try process.run()
  process.waitUntilExit()
  
  guard process.terminationStatus == 0 else {
    let stderr = (try? String(contentsOf: errFile, encoding: .utf8)) ?? "<no stderr>"
    throw SwiftPMError.describeFailed(
      packagePath: url.path,
      exitCode: Int(process.terminationStatus),
      stderr: stderr
    )
  }
  
  let data = try Data(contentsOf: outFile)
  return try JSONDecoder().decode(SwiftPMDescribe.self, from: data)
}

// MARK: - SwiftPM Models

struct SwiftPMDescribe: Codable {

  struct Product: Codable {
    let name: String
    let targets: [String]
  }

  struct Target: Codable {
    let name: String
    let type: String
    let path: String
    let sources: [String]
    let resources: [Resource]

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      name = try c.decode(String.self, forKey: .name)
      type = try c.decode(String.self, forKey: .type)
      path = try c.decode(String.self, forKey: .path)
      sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
      resources = try c.decodeIfPresent([Resource].self, forKey: .resources) ?? []
    }

    enum CodingKeys: String, CodingKey {
      case name, type, path, sources, resources
    }
  }

  struct Resource: Codable {
    let path: String
  }

  let products: [Product]
  let targets: [Target]
}

// MARK: - Errors

enum SwiftPMError: Error, CustomStringConvertible {
  case describeFailed(packagePath: String, exitCode: Int, stderr: String)

  var description: String {
    switch self {
    case let .describeFailed(path, code, stderr):
      return """
      swift package describe failed
        package: \(path)
        exitCode: \(code)
        stderr: \(stderr)
      """
    }
  }
}

// MARK: - Repo Discovery, Import Index, Resolution, Exclusions, Output
// (unchanged from your previous version)

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
        if t.hasPrefix("import class ") {
          return t
            .replacingOccurrences(of: "import class ", with: "")
            .split(separator: " ")
            .first
            .map(String.init)?
            .split(separator: ".")
            .last
            .map(String.init)
        } else if t.hasPrefix("import ") {
          return t
            .replacingOccurrences(of: "import ", with: "")
            .split(separator: " ")
            .first
            .map(String.init)
        } else {
          return nil
        }
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
  productIndex: ProductIndex
) -> [TargetSnapshot] {

  let repoSourceFiles = repoFiles.filter { $0.owner == .repo && $0.kind == .source }

  return targets.map { target in
    var visitedFiles: Set<RepoFile> = []
    var visitedImports: Set<String> = [] // products/modules we’ve already expanded
    var queue: [RepoFile] = repoSourceFiles.filter {
      $0.path.hasPrefix(target.entryFolder + "/")
    }

    while let file = queue.popLast() {
      guard visitedFiles.insert(file).inserted else { continue }

      for imp in importIndex[file] ?? [] {
        guard visitedImports.insert(imp).inserted else { continue }

        // 1) Prefer SwiftPM product expansion
        if let product = productIndex.products[imp] {
          for f in product.files where !visitedFiles.contains(f) {
            queue.append(f)
          }
          continue
        }

        // 2) Repo fallback: expand by *folder prefix* (not file suffix)
        // Heuristics: support common layouts
        let prefixes = [
          "\(imp)/",
          "Sources/\(imp)/",
          "\(target.entryFolder)/\(imp)/",        // if you nest modules under the target folder
          "\(target.entryFolder)/Sources/\(imp)/"
        ]

        for candidate in repoSourceFiles {
          if visitedFiles.contains(candidate) { continue }
          if prefixes.contains(where: { candidate.path.hasPrefix($0) }) {
            queue.append(candidate)
          }
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
