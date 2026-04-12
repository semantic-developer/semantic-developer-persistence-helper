import Foundation
import SharedModels

public struct HostProfile: Sendable, Equatable {
    public let name: String
    public let host: HostAddress
    public let port: Int
    public let username: String
    public let authentication: HostAuthentication
    public let remoteTransport: RemoteTransport
    public let usePersistedSession: Bool
    public let startupCommand: String?

    public init(
        name: String,
        host: HostAddress,
        port: Int = 22,
        username: String,
        authentication: HostAuthentication,
        remoteTransport: RemoteTransport = .ssh,
        usePersistedSession: Bool = false,
        startupCommand: String? = nil
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStartupCommand = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw SemanticDeveloperError.invalidConfiguration(.host)
        }

        guard (1...65_535).contains(port) else {
            throw SemanticDeveloperError.invalidConfiguration(.port)
        }

        guard !trimmedUsername.isEmpty else {
            throw SemanticDeveloperError.invalidConfiguration(.username)
        }

        self.name = trimmedName
        self.host = host
        self.port = port
        self.username = trimmedUsername
        self.authentication = authentication
        self.remoteTransport = remoteTransport
        self.usePersistedSession = usePersistedSession
        self.startupCommand = trimmedStartupCommand?.isEmpty == true ? nil : trimmedStartupCommand
    }
}
