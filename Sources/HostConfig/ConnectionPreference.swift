public enum RemoteTransport: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case ssh
    case mosh

    public var label: String {
        switch self {
        case .ssh:
            return "SSH"
        case .mosh:
            return "Mosh"
        }
    }
}

// Legacy saved-connection/CLI compatibility only.
public enum ConnectionPreference: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case ssh
    case persistedSession
    case mosh

    public var label: String {
        switch self {
        case .ssh:
            return "SSH"
        case .persistedSession:
            return "Persisted"
        case .mosh:
            return "Mosh"
        }
    }

    public var remoteTransport: RemoteTransport {
        switch self {
        case .ssh, .persistedSession:
            return .ssh
        case .mosh:
            return .mosh
        }
    }

    public var usesPersistedSession: Bool {
        self == .persistedSession
    }
}
