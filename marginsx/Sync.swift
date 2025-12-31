import Foundation
import ArgumentParser

// MARK: - Sync [Flatten + Prune] Command

struct SyncCommand: ParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "sync",
    abstract: "Flatten a snapshot into a target-scoped source tree, and prune unused files."
  )

  @OptionGroup var requiredDestination: RequiredDestinationOptions
  @OptionGroup var output: OutputOptions
  @OptionGroup var destructive: DestructiveOptions

  @Flag(name: .long)
  var dryRun: Bool = false

  func run() throws {
    try Flatten(
      destination: requiredDestination.destination,
      verbose: output.verbose,
      quiet: output.quiet,
      silent: output.silent,
      force: destructive.force,
      clean: destructive.clean,
      overwrite: destructive.overwrite
    ).execute()

    try Prune(
      destination: requiredDestination.destination,
      quiet: output.quiet,
      silent: output.silent,
      force: destructive.force,
      dryRun: dryRun
    ).execute()
  }
}
