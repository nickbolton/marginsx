import Foundation
import ArgumentParser

// MARK: - Flatten Prune Command

struct PruneCommand: ParsableCommand {
  
  static let configuration = CommandConfiguration(
    commandName: "prune",
    abstract: "Remove files in destination not defined by the flatten plan."
  )
  
  @OptionGroup var destinationOptions: RequiredDestinationOptions
  @OptionGroup var output: OutputOptions
  @OptionGroup var destructive: DestructiveOptions
  
  @Flag(
    name: .long,
    help: "Show what would be removed without deleting anything."
  )
  var dryRun: Bool = false
  
  func run() throws {
    try Prune(
      destination: destinationOptions.destination,
      quiet: output.quiet,
      silent: output.silent,
      force: destructive.force,
      dryRun: dryRun
    ).execute()
  }
}

struct Prune {

  let destination: String
  let quiet: Bool
  let silent: Bool
  let force: Bool
  let dryRun: Bool

  func execute() throws {
    let repoRoot = try Git.repoRoot()

    let flattenMapURL = repoRoot
      .appendingPathComponent(".marginsx/flattened/flatten.map.json")

    let flattenMap = try loadFlattenMap(from: flattenMapURL)

    let destinationRoot =
      URL(fileURLWithPath: destination, isDirectory: true)

    let expectedFiles =
      computeExpectedFiles(flattenMap, destinationRoot: destinationRoot)

    let pruneRoots =
      computePruneRoots(flattenMap, destinationRoot: destinationRoot)

    let orphanFiles =
      findOrphanFiles(
        destinationRoot: destinationRoot,
        expectedFiles: expectedFiles,
        pruneRoots: pruneRoots
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

func computePruneRoots(
  _ map: FlattenMap,
  destinationRoot: URL
) -> [URL] {

  let roots = map.targets.map {
    destinationRoot.appendingPathComponent($0.name)
  }

  return roots.map { $0.standardizedFileURL }
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
  expectedFiles: Set<URL>,
  pruneRoots: [URL]
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

    // ✅ Only prune inside flatten scope
    guard pruneRoots.contains(where: { standardized.path.hasPrefix($0.path) }) else {
      continue
    }

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
    var isDirectory: ObjCBool = false
    fm.fileExists(atPath: dir.path, isDirectory: &isDirectory)

    guard isDirectory.boolValue else { continue }

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

