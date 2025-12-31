import Foundation
import ArgumentParser

// MARK: - Flatten Command

struct Flatten: ParsableCommand {

  static let configuration = CommandConfiguration(
    abstract: "Flatten a snapshot into a target-scoped source tree."
  )

  @Option(
    name: .long,
    help: "Destination root where flattened files will be copied (target project folder)."
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

// MARK: - Output

func printFlattenSummary(_ map: FlattenMap) {
  print("✔ Flatten plan created")
  print("  Targets: \(map.targets.count)")

  if let destination = map.destination {
    print("  Destination: \(destination)")
  } else {
    print("  Destination: (not specified)")
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
