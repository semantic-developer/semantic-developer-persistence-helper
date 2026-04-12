import Foundation
import HostConfig
import SharedModels

public struct RemotePersistenceHello: Sendable, Equatable {
    public let protocolVersion: Int
    public let helperVersion: String
    public let capabilities: Set<RemotePersistenceCapability>

    public init(
        protocolVersion: Int,
        helperVersion: String,
        capabilities: Set<RemotePersistenceCapability>
    ) {
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
        self.capabilities = capabilities
    }
}

public enum RemotePersistenceCapability: String, Sendable, Equatable, Hashable {
    case listSessions
    case createSession
    case attachSession
    case replay
    case resize
    case closeSession
}

public struct RemotePersistenceSessionSummary: Sendable, Equatable {
    public let descriptor: PersistentSessionDescriptor
    public let reconnectToken: String?

    public init(descriptor: PersistentSessionDescriptor, reconnectToken: String?) {
        self.descriptor = descriptor
        self.reconnectToken = reconnectToken
    }
}

public struct RemotePersistenceCreateRequest: Sendable, Equatable {
    public let profile: HostProfile
    public let kind: PersistentSessionKind
    public let label: String?
    public let terminalType: String
    public let initialSize: TerminalSize
    public let reconnectPolicy: ReconnectPolicy
    public let startupCommand: String?

    public init(
        profile: HostProfile,
        kind: PersistentSessionKind,
        label: String?,
        terminalType: String,
        initialSize: TerminalSize,
        reconnectPolicy: ReconnectPolicy,
        startupCommand: String?
    ) {
        self.profile = profile
        self.kind = kind
        self.label = label
        self.terminalType = terminalType
        self.initialSize = initialSize
        self.reconnectPolicy = reconnectPolicy
        self.startupCommand = startupCommand
    }
}

public enum RemotePersistenceEvent: Sendable, Equatable {
    case output(sessionID: PersistentSessionID, sequence: Int64, bytes: [UInt8])
    case stateChanged(PersistentSessionDescriptor)
    case replayStarted(sessionID: PersistentSessionID)
    case replayFinished(sessionID: PersistentSessionID, replayedThroughSequence: Int64)
    case sessionExited(sessionID: PersistentSessionID, exitCode: Int32?)
    case error(sessionID: PersistentSessionID?, error: SemanticDeveloperError)
}
