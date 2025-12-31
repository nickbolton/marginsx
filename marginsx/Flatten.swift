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

  @Flag(
    name: .long,
    help: "Overwrite existing files without prompting."
  )
  var overwrite: Bool = false

  @Flag(
    name: .long,
    help: "Remove all contents inside the destination directory and exit."
  )
  var clean: Bool = false

  @Flag(
    name: .long,
    help: "Print full per-file output (source → destination)."
  )
  var verbose: Bool = false

  @Flag(
    name: .long,
    help: "Suppress per-file output."
  )
  var quiet: Bool = false

  @Flag(
    name: .long,
    help: "Suppress all output, including summaries."
  )
  var silent: Bool = false

  @Flag(
    name: .long,
    help: "Assume yes for all prompts (implies overwrite)."
  )
  var force: Bool = false

  func run() throws {
    guard !(verbose && quiet) else {
      throw ValidationError("--verbose and --quiet cannot be used together")
    }

    let repoRoot = try Git.repoRoot()

    // --clean is a standalone operation
    if clean {
      try performClean(repoRoot: repoRoot)
      return
    }

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

    if !silent {
      printFlattenSummary(flattenMap)
    }

    try performFlatten(
      flattenMap,
      repoRoot: repoRoot,
      overwrite: overwrite || force,
      verbose: verbose,
      quiet: quiet,
      silent: silent
    )
  }

  // MARK: - Clean

  private func performClean(repoRoot: URL) throws {
    guard let destination else {
      throw ValidationError("--clean requires --destination")
    }

    let fm = FileManager.default
    let destinationRoot = URL(fileURLWithPath: destination, isDirectory: true)

    if fm.fileExists(atPath: destinationRoot.path) {
      if !force {
        guard confirmClean(destinationRoot) else {
          throw ValidationError("Aborted — destination not cleaned.")
        }
      }

      let contents = try fm.contentsOfDirectory(
        at: destinationRoot,
        includingPropertiesForKeys: nil
      )

      for item in contents {
        try fm.removeItem(at: item)
      }

      if !silent {
        print("✔ Cleaned destination: \(destinationRoot.path)")
      }
    } else {
      try fm.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true
      )

      if !silent {
        print("✔ Created empty destination: \(destinationRoot.path)")
      }
    }
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
          "\(target.name)/\(topLevel)/\(ownerPath)/\(file.path)"

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
  repoRoot: URL,
  overwrite: Bool,
  verbose: Bool,
  quiet: Bool,
  silent: Bool
) throws {

  guard let destinationPath = map.destination else {
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

  let totalFiles = map.targets.reduce(0) { $0 + $1.files.count }
  var processed = 0
  var copiedCount = 0

  if !quiet && !silent {
    print("▶ Copying \(totalFiles) files")
  }

  for target in map.targets {
    for file in target.files {
      processed += 1

      let sourceURL = repoRoot.appendingPathComponent(file.originalPath)
      let destinationURL =
        destinationRoot.appendingPathComponent(file.flattenedPath)

      try fm.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      if fm.fileExists(atPath: destinationURL.path) {
        if !overwrite {
          let decision = promptForOverwrite(destinationURL)
          if decision == .no {
            continue
          }
        }

        try fm.removeItem(at: destinationURL)
      }

      try fm.copyItem(at: sourceURL, to: destinationURL)
      copiedCount += 1

      if silent || quiet {
        continue
      }

      print("✔ Copied \(processed)/\(totalFiles)")

      if verbose {
        print("  \(sourceURL.path) → \(file.flattenedPath)")
      }
    }
  }

  if !silent {
    print("✔ Finished — copied \(copiedCount) files")
  }
}

// MARK: - Confirmation Prompts

func confirmClean(_ url: URL) -> Bool {
  print("""
  ⚠️  This will REMOVE ALL CONTENTS inside:
    \(url.path)
  Continue? [y/N]:
  """, terminator: " ")

  return readLine()?.lowercased() == "y"
}

enum OverwriteDecision {
  case yes
  case no
  case all
}

func promptForOverwrite(_ url: URL) -> OverwriteDecision {
  print("""
  File exists:
    \(url.path)
  Overwrite? [y/N/a]:
  """, terminator: " ")

  switch readLine()?.lowercased() {
  case "y": return .yes
  case "a": return .all
  default: return .no
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
