import Foundation

public enum SemanticDeveloperError: Error, Sendable, Equatable {
    case invalidTerminalSize(columns: Int, rows: Int)
    case invalidConfiguration(ConfigurationField)
    case missingCredential(CredentialKind)
    case unsupportedFeature(Feature)
    case connectionFailed
    case authenticationFailed
    case disconnected(DisconnectReason)
}

public enum ConfigurationField: String, Sendable, Equatable {
    case host
    case port
    case username
    case authentication
    case hostKeyPolicy
    case startupCommand
}

public enum CredentialKind: String, Sendable, Equatable {
    case privateKey
    case password
    case passphrase
    case knownHost
}

public enum Feature: String, Sendable, Equatable {
    case ssh
    case persistedSessions
    case mosh
    case ptyResize
    case hostVerification
}

extension SemanticDeveloperError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTerminalSize(let columns, let rows):
            return "Invalid terminal size: \(columns)x\(rows)."
        case .invalidConfiguration(let field):
            return "Invalid \(field.rawValue) configuration."
        case .missingCredential(let kind):
            return "Missing \(kind.rawValue) credential."
        case .unsupportedFeature(let feature):
            switch feature {
            case .persistedSessions:
                return "Persisted sessions are not available in this build. Build or provide `semantic-developer-helper` locally before connecting."
            default:
                return "\(feature.rawValue.uppercasedFirstLetter()) is not supported in this build."
            }
        case .connectionFailed:
            return "Connection failed."
        case .authenticationFailed:
            return "Authentication failed."
        case .disconnected(let reason):
            return "Disconnected: \(reason.label)."
        }
    }
}

private extension String {
    func uppercasedFirstLetter() -> String {
        guard let first else {
            return self
        }

        return String(first).uppercased() + dropFirst()
    }
}

private extension DisconnectReason {
    var label: String {
        switch self {
        case .requestedByUser:
            return "requested by user"
        case .remoteClosed:
            return "remote host closed the session"
        case .networkLost:
            return "network connection was lost"
        case .authenticationFailed:
            return "authentication failed"
        case .protocolError:
            return "protocol error"
        case .helperUnavailable:
            return "persistence helper unavailable"
        case .sessionExited:
            return "persisted session exited"
        case .sessionLost:
            return "persisted session was lost"
        case .sessionNotFound:
            return "persisted session was not found"
        case .requestedDetach:
            return "requested detach"
        }
    }
}
