import Foundation

public struct PersistentSessionID: Sendable, Hashable, Equatable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }
}

public enum PersistentSessionKind: String, Sendable, Equatable {
    case shell
    case codex
    case custom
}

public enum PersistentSessionLiveness: Sendable, Equatable {
    case attached
    case detached
    case exited(exitCode: Int32?)
    case lost
}

public enum SessionRecoveryState: Sendable, Equatable {
    case notApplicable
    case reconnectable
    case reconnecting
    case unavailable
}

public struct ReconnectPolicy: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case automatic
        case manual
        case disabled
    }

    public let mode: Mode
    public let idleTimeoutSeconds: Int?

    public init(mode: Mode = .automatic, idleTimeoutSeconds: Int? = nil) {
        self.mode = mode
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }
}

public struct PersistentSessionDescriptor: Sendable, Equatable {
    public let id: PersistentSessionID
    public let hostName: String
    public let hostAddress: String
    public let port: Int
    public let username: String
    public let label: String
    public let kind: PersistentSessionKind
    public let createdAt: Date
    public let lastAttachedAt: Date?
    public let terminalType: String
    public let lastKnownSize: TerminalSize
    public let liveness: PersistentSessionLiveness
    public let recoveryState: SessionRecoveryState
    public let reconnectPolicy: ReconnectPolicy
    public let startupCommand: String?

    public init(
        id: PersistentSessionID,
        hostName: String,
        hostAddress: String,
        port: Int,
        username: String,
        label: String,
        kind: PersistentSessionKind,
        createdAt: Date,
        lastAttachedAt: Date?,
        terminalType: String,
        lastKnownSize: TerminalSize,
        liveness: PersistentSessionLiveness,
        recoveryState: SessionRecoveryState,
        reconnectPolicy: ReconnectPolicy,
        startupCommand: String?
    ) {
        self.id = id
        self.hostName = hostName
        self.hostAddress = hostAddress
        self.port = port
        self.username = username
        self.label = label
        self.kind = kind
        self.createdAt = createdAt
        self.lastAttachedAt = lastAttachedAt
        self.terminalType = terminalType
        self.lastKnownSize = lastKnownSize
        self.liveness = liveness
        self.recoveryState = recoveryState
        self.reconnectPolicy = reconnectPolicy
        self.startupCommand = startupCommand
    }
}
