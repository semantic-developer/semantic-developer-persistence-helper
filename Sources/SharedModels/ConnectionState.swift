public enum ConnectionState: Sendable, Equatable {
    case idle
    case bootstrapping
    case connecting
    case checkingHelper
    case installingHelper
    case creatingPersistedSession
    case attaching
    case connected
    case attached
    case detachedRecoverable
    case reconnecting
    case helperUnavailable
    case sessionExited
    case sessionLost
    case disconnecting
    case disconnected(reason: DisconnectReason?)
    case failed(SemanticDeveloperError)
}

public enum DisconnectReason: Sendable, Equatable {
    case requestedByUser
    case requestedDetach
    case remoteClosed
    case networkLost
    case authenticationFailed
    case protocolError
    case helperUnavailable
    case sessionExited
    case sessionLost
    case sessionNotFound
}
