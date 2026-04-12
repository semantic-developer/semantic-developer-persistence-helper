import Foundation
import SharedModels

public struct HostAddress: Sendable, Equatable {
    public let value: String

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw SemanticDeveloperError.invalidConfiguration(.host)
        }

        self.value = trimmed
    }
}
