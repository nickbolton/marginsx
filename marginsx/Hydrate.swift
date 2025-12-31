import Foundation
import ArgumentParser

struct HydrateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hydrate",
    abstract: "Hydrate the source project from a flattened build."
  )

  func run() throws {
    print("hydrate: not yet implemented")
  }
}
