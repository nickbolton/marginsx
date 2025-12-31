import Foundation
import ArgumentParser

// MARK: - Flatten Prune Command

struct Prune: ParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "prune",
    abstract: "Remove files in destination not defined by the flatten plan."
  )

  @Option(
    name: .long,
    help: "Destination root to prune (must match flatten destination)."
  )
  var destination: String

  @Flag(
    name: .long,
    help: "Show what would be removed without deleting anything."
  )
  var dryRun: Bool = false

  @Flag(
    name: .long,
    help: "Delete without prompting."
  )
  var force: Bool = false

  @Flag(
    name: .long,
    help: "Suppress per-file output."
  )
  var quiet: Bool = false

  @Flag(
    name: .long,
    help: "Suppress all output."
  )
  var silent: Bool = false

  func run() throws {
    let repoRoot = try Git.repoRoot()

    let flattenMapURL = repoRoot
      .appendingPathComponent(".marginsx/flattened/flatten.map.json")

    let flattenMap = try loadFlattenMap(from: flattenMapURL)

    let destinationRoot =
      URL(fileURLWithPath: destination, isDirectory: true)

    let expectedFiles =
      computeExpectedFiles(flattenMap, destinationRoot: destinationRoot)

    let orphanFiles =
      findOrphanFiles(
        destinationRoot: destinationRoot,
        expectedFiles: expectedFiles
      )

    guard !orphanFiles.isEmpty else {
      if !silent {
        print("✔ No files to prune")
      }
      return
    }

    if !silent && !quiet {
      print("⚠️  \(orphanFiles.count) orphaned files found:")
      for file in orphanFiles {
        print("  \(file.path)")
      }
    }

    if dryRun {
      if !silent {
        print("[Dry run] No files were removed")
      }
      return
    }

    if !force {
      guard confirmPrune(count: orphanFiles.count) else {
        print("✔ Aborted — no files removed.")
        return
      }
    }

    try deleteFiles(orphanFiles)

    try removeEmptyDirectories(under: destinationRoot)

    if !silent {
      print("✔ Pruned \(orphanFiles.count) files")
    }
  }
}

// MARK: - Helpers

func loadFlattenMap(from url: URL) throws -> FlattenMap {
  let data = try Data(contentsOf: url)
  return try JSONDecoder().decode(FlattenMap.self, from: data)
}

func computeExpectedFiles(
  _ map: FlattenMap,
  destinationRoot: URL
) -> Set<URL> {

  var expected = Set<URL>()

  for target in map.targets {
    for file in target.files {
      let url = destinationRoot
        .appendingPathComponent(file.flattenedPath)
        .standardizedFileURL
      expected.insert(url)
    }
  }

  return expected
}

func findOrphanFiles(
  destinationRoot: URL,
  expectedFiles: Set<URL>
) -> [URL] {

  let fm = FileManager.default
  var orphans: [URL] = []

  guard let enumerator =
    fm.enumerator(
      at: destinationRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
  else {
    return []
  }

  for case let fileURL as URL in enumerator {
    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
    guard values?.isRegularFile == true else { continue }

    let standardized = fileURL.standardizedFileURL
    if !expectedFiles.contains(standardized) {
      orphans.append(standardized)
    }
  }

  return orphans.sorted { $0.path < $1.path }
}

func deleteFiles(_ files: [URL]) throws {
  let fm = FileManager.default
  for file in files {
    try fm.removeItem(at: file)
  }
}

func removeEmptyDirectories(under root: URL) throws {
  let fm = FileManager.default

  guard let enumerator =
    fm.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    )
  else {
    return
  }

  let directories = enumerator.allObjects
    .compactMap { $0 as? URL }
    .sorted { $0.path.count > $1.path.count } // deepest first

  for dir in directories {
    let contents = try fm.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil
    )

    if contents.isEmpty {
      try? fm.removeItem(at: dir)
    }
  }
}

// MARK: - Prompts

func confirmPrune(count: Int) -> Bool {
  print("""
  ⚠️  This will REMOVE \(count) files not defined by the flatten plan.
  Continue? [y/N]:
  """, terminator: " ")

  return readLine()?.lowercased() == "y"
}
