import SharedModels

public enum HostAuthentication: Sendable, Equatable {
    case privateKey(keyName: String)
    case password

    public var authType: AuthType {
        switch self {
        case .privateKey:
            return .privateKey
        case .password:
            return .password
        }
    }
}
