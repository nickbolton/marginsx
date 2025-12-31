import Foundation
import ArgumentParser

// MARK: - Entry Point

@main
struct MarginsX: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "marginsx",
    abstract: "Flatten and rehydrate large Swift/Xcode projects.",
    subcommands: [
      SnapshotCommand.self,
      FlattenCommand.self,
      PruneCommand.self,
      SyncCommand.self,
      HydrateCommand.self
    ]
  )
}

struct RuntimeError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

struct OptionalDestinationOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Destination root where flattened files will be copied (target project folder). Omit for dry run."
  )
  var destination: String?
}

struct RequiredDestinationOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Destination root where files will be written."
  )
  var destination: String
}

struct OutputOptions: ParsableArguments {
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
}

struct DestructiveOptions: ParsableArguments {
  @Flag(
    name: .long,
    help: "Overwrite existing files without prompting."
  )
  var overwrite: Bool = false

  @Flag(
    name: .long,
    help: "Assume yes for all prompts (implies overwrite)."
  )
  var force: Bool = false

  @Flag(
    name: .long,
    help: "Remove all contents inside the destination directory and exit."
  )
  var clean: Bool = false
}
