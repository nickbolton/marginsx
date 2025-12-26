import Foundation
import ArgumentParser

struct Rehydrate: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Rehydrate the source project from a flattened build."
  )

  func run() throws {
    print("rehydrate: not yet implemented")
  }
}
