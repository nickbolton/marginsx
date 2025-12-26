import Foundation
import ArgumentParser

// MARK: - Flatten Command

struct Flatten: ParsableCommand {

  static let configuration = CommandConfiguration(
    abstract: "Flatten the repo into a single buildable source tree."
  )

  func run() throws {
    let repoRoot = try Git.repoRoot()

    let snapshotURL = repoRoot
      .appendingPathComponent(".marginsx/snapshot/snapshot.json")

    let snapshot = try loadSnapshot(from: snapshotURL)

    let plan = buildFlattenPlan(from: snapshot)
    let map = buildFlattenMap(plan: plan)

    let flattenedRoot = repoRoot
      .appendingPathComponent(".marginsx/flattened", isDirectory: true)

    try writeFlattenMap(map, to: flattenedRoot)

    printFlattenSummary(plan: plan, map: map)
    print("  Map written to: .marginsx/flattened/flatten.map.json")
  }
}

// MARK: - Flatten Plan

/// Contains only files that participate in the build.
/// Tests and `.other` files are intentionally excluded.
struct FlattenPlan {
  let includedFiles: [RepoFile]
}

func buildFlattenPlan(from snapshot: SnapshotModel) -> FlattenPlan {
  let included = snapshot.repoFiles.filter {
    $0.kind == .source || $0.kind == .resource
  }

  return FlattenPlan(includedFiles: included)
}

// MARK: - Flatten Mapping

struct FlattenedFile: Codable {
  let originalPath: String
  let flattenedPath: String
  let kind: FileKind
  let owner: Owner
}

struct FlattenMap: Codable {
  let createdAt: String
  let files: [FlattenedFile]
}

func buildFlattenMap(plan: FlattenPlan) -> FlattenMap {
  let timestamp = ISO8601DateFormatter().string(from: Date())

  let files: [FlattenedFile] = plan.includedFiles.map { file in
    let topLevel = (file.kind == .source) ? "Sources" : "Resources"

    let ownerPath: String
    switch file.owner {
    case .repo:
      ownerPath = "Repo"
    case .package(let name):
      ownerPath = "Packages/\(name)"
    }

    let flattenedPath = "\(topLevel)/\(ownerPath)/\(file.path)"

    return FlattenedFile(
      originalPath: file.path,
      flattenedPath: flattenedPath,
      kind: file.kind,
      owner: file.owner
    )
  }

  return FlattenMap(
    createdAt: timestamp,
    files: files.sorted { $0.flattenedPath < $1.flattenedPath }
  )
}

// MARK: - Persistence

func writeFlattenMap(_ map: FlattenMap, to flattenedRoot: URL) throws {
  let fm = FileManager.default
  try fm.createDirectory(at: flattenedRoot, withIntermediateDirectories: true)

  let mapURL = flattenedRoot.appendingPathComponent("flatten.map.json")

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

  let data = try encoder.encode(map)
  try data.write(to: mapURL, options: .atomic)
}

// MARK: - Output

func printFlattenSummary(plan: FlattenPlan, map: FlattenMap) {
  print("✔ Flatten plan created")
  print("  Included files: \(plan.includedFiles.count)")

  let byKind = Dictionary(grouping: plan.includedFiles, by: { $0.kind })
  print("    Sources:   \(byKind[.source]?.count ?? 0)")
  print("    Resources: \(byKind[.resource]?.count ?? 0)")

  print("  Flattened paths: \(map.files.count)")
}

// MARK: - Snapshot Loading

func loadSnapshot(from url: URL) throws -> SnapshotModel {
  let data = try Data(contentsOf: url)
  let decoder = JSONDecoder()
  return try decoder.decode(SnapshotModel.self, from: data)
}
