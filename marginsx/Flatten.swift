import Foundation
import ArgumentParser

// MARK: - Flatten Command

struct Flatten: ParsableCommand {

  static let configuration = CommandConfiguration(
    abstract: "Flatten a snapshot into a target-scoped source tree."
  )

  @Option(
    name: .long,
    help: "Destination root where flattened files will be copied (target project folder). Omit for dry run."
  )
  var destination: String?

  func run() throws {
    let repoRoot = try Git.repoRoot()

    let snapshotURL = repoRoot
      .appendingPathComponent(".marginsx/snapshot/snapshot.json")

    let snapshot = try loadSnapshot(from: snapshotURL)

    let flattenMap = buildFlattenMap(
      snapshot: snapshot,
      destination: destination
    )

    let flattenedRoot = repoRoot
      .appendingPathComponent(".marginsx/flattened", isDirectory: true)

    try writeFlattenMap(flattenMap, to: flattenedRoot)
    printFlattenSummary(flattenMap)

    try performFlatten(
      flattenMap,
      repoRoot: repoRoot
    )
  }
}

// MARK: - Models

struct FlattenMap: Codable {
  let createdAt: String
  let destination: String?
  let targets: [FlattenedTarget]
}

struct FlattenedTarget: Codable {
  let name: String
  let files: [FlattenedFile]
}

struct FlattenedFile: Codable {
  let originalPath: String
  let flattenedPath: String
  let kind: FileKind
  let owner: Owner
}

// MARK: - Build Flatten Map

func buildFlattenMap(
  snapshot: SnapshotModel,
  destination: String?
) -> FlattenMap {

  let timestamp = ISO8601DateFormatter().string(from: Date())

  let targets: [FlattenedTarget] = snapshot.targets.map { target in
    let files = target.repoFiles
      .filter { $0.kind == .source || $0.kind == .resource }
      .map { file -> FlattenedFile in

        let topLevel: String
        switch file.kind {
        case .source:
          topLevel = "Sources"
        case .resource:
          topLevel = "Resources"
        default:
          fatalError("Unexpected file kind in flatten: \(file.kind)")
        }

        let ownerPath: String
        switch file.owner {
        case .repo:
          ownerPath = "Repo"
        case .package(let name):
          ownerPath = "Packages/\(name)"
        }

        let flattenedPath =
          "Targets/\(target.name)/\(topLevel)/\(ownerPath)/\(file.path)"

        return FlattenedFile(
          originalPath: file.path,
          flattenedPath: flattenedPath,
          kind: file.kind,
          owner: file.owner
        )
      }
      .sorted { $0.flattenedPath < $1.flattenedPath }

    return FlattenedTarget(
      name: target.name,
      files: files
    )
  }

  return FlattenMap(
    createdAt: timestamp,
    destination: destination,
    targets: targets
  )
}

// MARK: - IO

func loadSnapshot(from url: URL) throws -> SnapshotModel {
  let data = try Data(contentsOf: url)
  return try JSONDecoder().decode(SnapshotModel.self, from: data)
}

func writeFlattenMap(
  _ map: FlattenMap,
  to root: URL
) throws {

  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

  let data = try encoder.encode(map)

  try data.write(
    to: root.appendingPathComponent("flatten.map.json"),
    options: .atomic
  )
}

// MARK: - Flatten Execution

func performFlatten(
  _ map: FlattenMap,
  repoRoot: URL
) throws {

  guard let destinationPath = map.destination else {
    print("ℹ️  Dry run — no destination specified")
    printPlannedOperations(map, repoRoot: repoRoot)
    return
  }

  let fm = FileManager.default
  let destinationRoot = URL(fileURLWithPath: destinationPath, isDirectory: true)

  if !fm.fileExists(atPath: destinationRoot.path) {
    try fm.createDirectory(
      at: destinationRoot,
      withIntermediateDirectories: true
    )
  }

  var copiedCount = 0

  for target in map.targets {
    for file in target.files {
      let sourceURL = repoRoot.appendingPathComponent(file.originalPath)
      let destinationURL =
        destinationRoot.appendingPathComponent(file.flattenedPath)

      try fm.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      if fm.fileExists(atPath: destinationURL.path) {
        // For now: skip existing files (no overwrite semantics yet)
        continue
      }

      try fm.copyItem(
        at: sourceURL,
        to: destinationURL
      )

      copiedCount += 1
    }
  }

  print("✔ Copied \(copiedCount) files to \(destinationRoot.path)")
}

// MARK: - Dry Run Output

func printPlannedOperations(
  _ map: FlattenMap,
  repoRoot: URL
) {
  for target in map.targets {
    for file in target.files {
      let source = repoRoot.appendingPathComponent(file.originalPath).path
      let destination = file.flattenedPath
      print("  \(source) → \(destination)")
    }
  }
}

// MARK: - Output

func printFlattenSummary(_ map: FlattenMap) {
  print("✔ Flatten plan created")
  print("  Targets: \(map.targets.count)")

  if let destination = map.destination {
    print("  Destination: \(destination)")
  } else {
    print("  Destination: (dry run)")
  }

  for target in map.targets {
    let sourceCount = target.files.filter { $0.kind == .source }.count
    let resourceCount = target.files.filter { $0.kind == .resource }.count

    print("    \(target.name):")
    print("      Sources:   \(sourceCount)")
    print("      Resources: \(resourceCount)")
  }

  print("  Flatten map written to: .marginsx/flattened/flatten.map.json")
}
