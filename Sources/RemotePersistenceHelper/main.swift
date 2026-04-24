import Dispatch
import Foundation
import RemotePersistenceProtocol
import SharedModels

#if canImport(Darwin)
import Darwin

@_silgen_name("fork")
private func platform_fork() -> pid_t
#elseif canImport(Glibc)
import Glibc

@_silgen_name("posix_openpt")
private func linux_posix_openpt(_ flags: Int32) -> Int32

@_silgen_name("grantpt")
private func linux_grantpt(_ fd: Int32) -> Int32

@_silgen_name("unlockpt")
private func linux_unlockpt(_ fd: Int32) -> Int32

@_silgen_name("ptsname")
private func linux_ptsname(_ fd: Int32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("fork")
private func platform_fork() -> pid_t
#endif

private let helperProtocolVersion = RemotePersistenceBuildInfo.helperProtocolVersion
private let helperVersion = RemotePersistenceBuildInfo.helperVersion
private let helperCapabilities: [RemotePersistenceCapability] = [
    .listSessions,
    .createSession,
    .attachSession,
    .replay,
    .resize,
    .closeSession,
]

private let replayBufferLimit = 256

@main
enum RemotePersistenceHelperMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)

        let arguments = CommandLine.arguments

        if arguments.contains("--hello") {
            printHello()
            return
        }

        if arguments.contains("--daemon") {
            runDaemon()
            return
        }

        if arguments.contains("--stdio") {
            let exitCode = runBridge()
            Foundation.exit(exitCode)
        }

        writeErrorLine("Usage: semantic-developer-helper [--hello|--stdio|--daemon]")
        Foundation.exit(64)
    }

    private static func printHello() {
        let capabilities = helperCapabilities.map(\.rawValue).joined(separator: ",")
        print("protocol=\(helperProtocolVersion)|version=\(helperVersion)|capabilities=\(capabilities)")
    }
}

private func runBridge() -> Int32 {
    do {
        let socketPath = try daemonSocketPath()
        let socket = try ensureDaemonAndConnect(socketPath: socketPath)
        defer { _ = close(socket) }

        let socketToStdout = DispatchGroup()
        socketToStdout.enter()
        DispatchQueue.global(qos: .utility).async {
            copyBytes(from: socket, to: STDOUT_FILENO)
            socketToStdout.leave()
        }

        copyBytes(from: STDIN_FILENO, to: socket)
        shutdown(socket, Int32(SHUT_WR))
        socketToStdout.wait()
        return 0
    } catch {
        writeErrorLine("semantic-developer-helper bridge error: \(String(describing: error))")
        return 1
    }
}

private func runDaemon() {
    do {
        let socketPath = try daemonSocketPath()
        let daemon = try RemoteHelperDaemon(socketPath: socketPath)
        try daemon.run()
    } catch {
        writeErrorLine("semantic-developer-helper daemon error: \(String(describing: error))")
        Foundation.exit(1)
    }
}

private final class RemoteHelperDaemon: @unchecked Sendable {
    private let socketPath: String
    private let daemonState = HelperState()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(socketPath: String) throws {
        self.socketPath = socketPath
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func run() throws {
        let listener = try makeUnixListener(at: socketPath)
        defer {
            _ = close(listener)
            unlink(socketPath)
        }

        while true {
            let clientFD = accept(listener, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                throw HelperError.socketFailure("accept failed: \(errno)")
            }

            Task.detached { [self] in
                await self.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) async {
        let writer = ClientWriter(fd: fd, encoder: encoder)
        let connectionID = UUID()
        await daemonState.register(connectionID: connectionID, writer: writer)
        let reader = SocketLineReader(fd: fd)

        do {
            while let line = try reader.readLine() {
                if line.isEmpty {
                    continue
                }

                let request = try decoder.decode(WireClientMessage.self, from: line)
                let response = await daemonState.handle(request: request, connectionID: connectionID)
                try await writer.send(response)
            }
        } catch {
            let response = WireServerMessage(
                id: nil,
                hello: nil,
                sessions: nil,
                session: nil,
                acknowledged: nil,
                errorCode: HelperError.protocolError.code,
                event: nil
            )
            try? await writer.send(response)
        }

        await daemonState.connectionClosed(connectionID)
        await writer.close()
    }
}

private actor HelperState {
    private struct ReplayEntry {
        let sequence: Int64
        let bytes: [UInt8]
    }

    private struct ManagedSession {
        var descriptor: PersistentSessionDescriptor
        var reconnectToken: String
        var masterFD: Int32
        var childPID: pid_t
        var nextSequence: Int64
        var replayBuffer: [ReplayEntry]
        var attachedConnectionID: UUID?
    }

    private var writers: [UUID: ClientWriter] = [:]
    private var sessions: [PersistentSessionID: ManagedSession] = [:]

    func register(connectionID: UUID, writer: ClientWriter) {
        writers[connectionID] = writer
    }

    func connectionClosed(_ connectionID: UUID) {
        for sessionID in sessions.keys {
            guard var session = sessions[sessionID], session.attachedConnectionID == connectionID else {
                continue
            }

            session.attachedConnectionID = nil
            session.descriptor = updateDescriptor(
                session.descriptor,
                liveness: .detached,
                recoveryState: session.descriptor.reconnectPolicy.mode == .disabled ? .unavailable : .reconnectable
            )
            sessions[sessionID] = session
        }

        writers.removeValue(forKey: connectionID)
    }

    func handle(request: WireClientMessage, connectionID: UUID) async -> WireServerMessage {
        do {
            switch request.method {
            case .hello:
                return WireServerMessage(
                    id: request.id,
                    hello: WireHello(
                        protocolVersion: helperProtocolVersion,
                        helperVersion: helperVersion,
                        capabilities: helperCapabilities.map(\.rawValue)
                    ),
                    sessions: nil,
                    session: nil,
                    acknowledged: nil,
                    errorCode: nil,
                    event: nil
                )
            case .listSessions:
                let descriptors = sessions.values.map(\.descriptor)
                let filteredDescriptors = descriptors.filter { descriptor in
                    descriptor.hostAddress == request.hostAddress &&
                    descriptor.port == request.port &&
                    descriptor.username == request.username
                }
                let sortedDescriptors = filteredDescriptors.sorted { lhs, rhs in
                    lhs.createdAt < rhs.createdAt
                }
                let matching = sortedDescriptors.map { descriptor in
                    WireSessionSummary(
                        descriptor: WirePersistentSessionDescriptor(descriptor: descriptor),
                        reconnectToken: sessions[descriptor.id]?.reconnectToken
                    )
                }
                return WireServerMessage(
                    id: request.id,
                    hello: nil,
                    sessions: matching,
                    session: nil,
                    acknowledged: nil,
                    errorCode: nil,
                    event: nil
                )
            case .createSession:
                let created = try createSession(request: request, connectionID: connectionID)
                return response(for: request.id, session: created)
            case .attachSession:
                let attached = try attachSession(request: request, connectionID: connectionID)
                return response(for: request.id, session: attached)
            case .detachSession:
                let detached = try detachSession(request: request)
                return response(for: request.id, session: detached)
            case .sendInput:
                try sendInput(request: request)
                return WireServerMessage(
                    id: request.id,
                    hello: nil,
                    sessions: nil,
                    session: nil,
                    acknowledged: true,
                    errorCode: nil,
                    event: nil
                )
            case .resizeSession:
                let resized = try resizeSession(request: request)
                return response(for: request.id, session: resized)
            case .closeSession:
                let closed = try closeSession(request: request)
                return response(for: request.id, session: closed)
            }
        } catch let error as HelperError {
            return WireServerMessage(
                id: request.id,
                hello: nil,
                sessions: nil,
                session: nil,
                acknowledged: nil,
                errorCode: error.code,
                event: nil
            )
        } catch {
            return WireServerMessage(
                id: request.id,
                hello: nil,
                sessions: nil,
                session: nil,
                acknowledged: nil,
                errorCode: HelperError.connectionFailed.code,
                event: nil
            )
        }
    }

    private func createSession(request: WireClientMessage, connectionID: UUID) throws -> WireSessionSummary {
        guard
            let hostName = request.hostName,
            let hostAddress = request.hostAddress,
            let port = request.port,
            let username = request.username,
            let kindRaw = request.kind,
            let terminalType = request.terminalType,
            let columns = request.columns,
            let rows = request.rows,
            let reconnectModeRaw = request.reconnectMode,
            let reconnectMode = ReconnectPolicy.Mode(rawValue: reconnectModeRaw)
        else {
            throw HelperError.protocolError
        }

        let kind = PersistentSessionKind(rawValue: kindRaw) ?? .custom
        let size = try TerminalSize(columns: columns, rows: rows)
        let reconnectPolicy = ReconnectPolicy(mode: reconnectMode, idleTimeoutSeconds: request.idleTimeoutSeconds)
        let label = normalizedLabel(
            label: request.label,
            kind: kind,
            hostName: hostName
        )
        let launched = try launchPersistedProcess(
            terminalType: terminalType,
            size: size,
            startupCommand: request.startupCommand
        )
        let sessionID = PersistentSessionID(UUID().uuidString.lowercased())
        let descriptor = PersistentSessionDescriptor(
            id: sessionID,
            hostName: hostName,
            hostAddress: hostAddress,
            port: port,
            username: username,
            label: label,
            kind: kind,
            createdAt: Date(),
            lastAttachedAt: Date(),
            terminalType: terminalType,
            lastKnownSize: size,
            liveness: .attached,
            recoveryState: .notApplicable,
            reconnectPolicy: reconnectPolicy,
            startupCommand: request.startupCommand
        )
        let reconnectToken = UUID().uuidString.lowercased()
        sessions[sessionID] = ManagedSession(
            descriptor: descriptor,
            reconnectToken: reconnectToken,
            masterFD: launched.masterFD,
            childPID: launched.childPID,
            nextSequence: 0,
            replayBuffer: [],
            attachedConnectionID: connectionID
        )
        startOutputPump(sessionID: sessionID)
        startExitMonitor(sessionID: sessionID)
        notifyAttachedClient(sessionID: sessionID, event: .stateChanged(descriptor))
        return WireSessionSummary(
            descriptor: WirePersistentSessionDescriptor(descriptor: descriptor),
            reconnectToken: reconnectToken
        )
    }

    private func attachSession(request: WireClientMessage, connectionID: UUID) throws -> WireSessionSummary {
        guard let sessionIDRaw = request.sessionID else {
            throw HelperError.protocolError
        }

        let sessionID = PersistentSessionID(sessionIDRaw)
        guard var session = sessions[sessionID] else {
            throw HelperError.sessionNotFound
        }
        guard session.reconnectToken == request.reconnectToken else {
            throw HelperError.authenticationFailed
        }
        guard case .exited = session.descriptor.liveness else {
            let shouldReplay = session.descriptor.liveness == .detached && !session.replayBuffer.isEmpty
            session.attachedConnectionID = connectionID
            session.descriptor = PersistentSessionDescriptor(
                id: session.descriptor.id,
                hostName: session.descriptor.hostName,
                hostAddress: session.descriptor.hostAddress,
                port: session.descriptor.port,
                username: session.descriptor.username,
                label: session.descriptor.label,
                kind: session.descriptor.kind,
                createdAt: session.descriptor.createdAt,
                lastAttachedAt: Date(),
                terminalType: session.descriptor.terminalType,
                lastKnownSize: session.descriptor.lastKnownSize,
                liveness: .attached,
                recoveryState: .notApplicable,
                reconnectPolicy: session.descriptor.reconnectPolicy,
                startupCommand: session.descriptor.startupCommand
            )
            sessions[sessionID] = session
            notifyAttachedClient(sessionID: sessionID, event: .stateChanged(session.descriptor))
            if shouldReplay {
                notifyAttachedClient(sessionID: sessionID, event: .replayStarted(sessionID: sessionID))
                for replayEntry in session.replayBuffer {
                    notifyAttachedClient(
                        sessionID: sessionID,
                        event: .output(sessionID: sessionID, sequence: replayEntry.sequence, bytes: replayEntry.bytes)
                    )
                }
                notifyAttachedClient(
                    sessionID: sessionID,
                    event: .replayFinished(
                        sessionID: sessionID,
                        replayedThroughSequence: session.replayBuffer.last?.sequence ?? 0
                    )
                )
            }
            return WireSessionSummary(
                descriptor: WirePersistentSessionDescriptor(descriptor: session.descriptor),
                reconnectToken: session.reconnectToken
            )
        }

        throw HelperError.sessionExited
    }

    private func detachSession(request: WireClientMessage) throws -> WireSessionSummary {
        guard let sessionIDRaw = request.sessionID else {
            throw HelperError.protocolError
        }

        let sessionID = PersistentSessionID(sessionIDRaw)
        guard var session = sessions[sessionID] else {
            throw HelperError.sessionNotFound
        }

        let previousConnectionID = session.attachedConnectionID
        let recoveryState: SessionRecoveryState = session.descriptor.reconnectPolicy.mode == .disabled ? .unavailable : .reconnectable
        session.attachedConnectionID = nil
        session.descriptor = updateDescriptor(
            session.descriptor,
            liveness: .detached,
            recoveryState: recoveryState
        )
        sessions[sessionID] = session
        if let previousConnectionID {
            notifyConnection(previousConnectionID, event: .stateChanged(session.descriptor))
        }
        return WireSessionSummary(
            descriptor: WirePersistentSessionDescriptor(descriptor: session.descriptor),
            reconnectToken: session.reconnectToken
        )
    }

    private func sendInput(request: WireClientMessage) throws {
        guard let sessionIDRaw = request.sessionID, let bytes = request.bytes else {
            throw HelperError.protocolError
        }

        let sessionID = PersistentSessionID(sessionIDRaw)
        guard let session = sessions[sessionID], session.masterFD >= 0 else {
            throw HelperError.sessionNotFound
        }

        try writeAll(fd: session.masterFD, bytes: bytes)
    }

    private func resizeSession(request: WireClientMessage) throws -> WireSessionSummary {
        guard
            let sessionIDRaw = request.sessionID,
            let columns = request.columns,
            let rows = request.rows
        else {
            throw HelperError.protocolError
        }

        let sessionID = PersistentSessionID(sessionIDRaw)
        guard var session = sessions[sessionID], session.masterFD >= 0 else {
            throw HelperError.sessionNotFound
        }

        let size = try TerminalSize(columns: columns, rows: rows)
        try setWindowSize(fd: session.masterFD, size: size)
        session.descriptor = PersistentSessionDescriptor(
            id: session.descriptor.id,
            hostName: session.descriptor.hostName,
            hostAddress: session.descriptor.hostAddress,
            port: session.descriptor.port,
            username: session.descriptor.username,
            label: session.descriptor.label,
            kind: session.descriptor.kind,
            createdAt: session.descriptor.createdAt,
            lastAttachedAt: session.descriptor.lastAttachedAt,
            terminalType: session.descriptor.terminalType,
            lastKnownSize: size,
            liveness: session.descriptor.liveness,
            recoveryState: session.descriptor.recoveryState,
            reconnectPolicy: session.descriptor.reconnectPolicy,
            startupCommand: session.descriptor.startupCommand
        )
        sessions[sessionID] = session
        notifyAttachedClient(sessionID: sessionID, event: .stateChanged(session.descriptor))
        return WireSessionSummary(
            descriptor: WirePersistentSessionDescriptor(descriptor: session.descriptor),
            reconnectToken: session.reconnectToken
        )
    }

    private func closeSession(request: WireClientMessage) throws -> WireSessionSummary {
        guard let sessionIDRaw = request.sessionID else {
            throw HelperError.protocolError
        }

        let sessionID = PersistentSessionID(sessionIDRaw)
        guard var session = sessions[sessionID] else {
            throw HelperError.sessionNotFound
        }

        if session.childPID > 0 {
            kill(session.childPID, SIGTERM)
        }
        if session.masterFD >= 0 {
            _ = close(session.masterFD)
        }
        let previousConnectionID = session.attachedConnectionID
        session.masterFD = -1
        session.childPID = 0
        session.attachedConnectionID = nil
        session.descriptor = updateDescriptor(
            session.descriptor,
            liveness: .exited(exitCode: request.exitCode),
            recoveryState: .unavailable
        )
        sessions[sessionID] = session
        if let previousConnectionID {
            notifyConnection(previousConnectionID, event: .stateChanged(session.descriptor))
            notifyConnection(
                previousConnectionID,
                event: .sessionExited(sessionID: sessionID, exitCode: request.exitCode)
            )
        }
        return WireSessionSummary(
            descriptor: WirePersistentSessionDescriptor(descriptor: session.descriptor),
            reconnectToken: session.reconnectToken
        )
    }

    private func startOutputPump(sessionID: PersistentSessionID) {
        guard let session = sessions[sessionID], session.masterFD >= 0 else {
            return
        }

        let masterFD = session.masterFD
        Task.detached {
            await self.readOutputLoop(sessionID: sessionID, masterFD: masterFD)
        }
    }

    private func startExitMonitor(sessionID: PersistentSessionID) {
        guard let session = sessions[sessionID], session.childPID > 0 else {
            return
        }

        let childPID = session.childPID
        Task.detached {
            await self.waitForExit(sessionID: sessionID, childPID: childPID)
        }
    }

    nonisolated private func readOutputLoop(sessionID: PersistentSessionID, masterFD: Int32) async {
        while true {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                await handleOutput(sessionID: sessionID, bytes: Array(buffer.prefix(Int(count))))
                continue
            }

            if count == 0 {
                return
            }

            if errno == EINTR {
                continue
            }

            return
        }
    }

    nonisolated private func waitForExit(sessionID: PersistentSessionID, childPID: pid_t) async {
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) < 0 {
            if errno == EINTR {
                continue
            }
            return
        }

        let exitCode: Int32?
        if processDidExit(status) {
            exitCode = processExitStatus(status)
        } else if processWasSignaled(status) {
            exitCode = 128 + processTermSignal(status)
        } else {
            exitCode = nil
        }

        await handleExit(sessionID: sessionID, exitCode: exitCode)
    }

    private func handleOutput(sessionID: PersistentSessionID, bytes: [UInt8]) {
        guard var session = sessions[sessionID] else {
            return
        }

        session.nextSequence += 1
        session.replayBuffer.append(ReplayEntry(sequence: session.nextSequence, bytes: bytes))
        if session.replayBuffer.count > replayBufferLimit {
            session.replayBuffer.removeFirst(session.replayBuffer.count - replayBufferLimit)
        }
        sessions[sessionID] = session
        notifyAttachedClient(
            sessionID: sessionID,
            event: .output(sessionID: sessionID, sequence: session.nextSequence, bytes: bytes)
        )
    }

    private func handleExit(sessionID: PersistentSessionID, exitCode: Int32?) {
        guard var session = sessions[sessionID] else {
            return
        }

        if session.masterFD >= 0 {
            _ = close(session.masterFD)
        }
        let previousConnectionID = session.attachedConnectionID
        session.masterFD = -1
        session.childPID = 0
        session.attachedConnectionID = nil
        session.descriptor = updateDescriptor(
            session.descriptor,
            liveness: .exited(exitCode: exitCode),
            recoveryState: .unavailable
        )
        sessions[sessionID] = session
        if let previousConnectionID {
            notifyConnection(previousConnectionID, event: .stateChanged(session.descriptor))
            notifyConnection(
                previousConnectionID,
                event: .sessionExited(sessionID: sessionID, exitCode: exitCode)
            )
        }
    }

    private func notifyAttachedClient(sessionID: PersistentSessionID, event: RemotePersistenceEvent) {
        guard
            let session = sessions[sessionID],
            let connectionID = session.attachedConnectionID,
            let writer = writers[connectionID]
        else {
            return
        }

        send(event: event, via: writer)
    }

    private func notifyConnection(_ connectionID: UUID, event: RemotePersistenceEvent) {
        guard let writer = writers[connectionID] else {
            return
        }

        send(event: event, via: writer)
    }

    private func send(event: RemotePersistenceEvent, via writer: ClientWriter) {
        let message = WireServerMessage(
            id: nil,
            hello: nil,
            sessions: nil,
            session: nil,
            acknowledged: nil,
            errorCode: nil,
            event: WireEvent(event: event)
        )

        Task {
            try? await writer.send(message)
        }
    }

    private func response(for requestID: String, session: WireSessionSummary) -> WireServerMessage {
        WireServerMessage(
            id: requestID,
            hello: nil,
            sessions: nil,
            session: session,
            acknowledged: nil,
            errorCode: nil,
            event: nil
        )
    }

    private func updateDescriptor(
        _ descriptor: PersistentSessionDescriptor,
        liveness: PersistentSessionLiveness,
        recoveryState: SessionRecoveryState
    ) -> PersistentSessionDescriptor {
        PersistentSessionDescriptor(
            id: descriptor.id,
            hostName: descriptor.hostName,
            hostAddress: descriptor.hostAddress,
            port: descriptor.port,
            username: descriptor.username,
            label: descriptor.label,
            kind: descriptor.kind,
            createdAt: descriptor.createdAt,
            lastAttachedAt: descriptor.lastAttachedAt,
            terminalType: descriptor.terminalType,
            lastKnownSize: descriptor.lastKnownSize,
            liveness: liveness,
            recoveryState: recoveryState,
            reconnectPolicy: descriptor.reconnectPolicy,
            startupCommand: descriptor.startupCommand
        )
    }
}

private actor ClientWriter {
    private let fd: Int32
    private let encoder: JSONEncoder
    private var closed = false

    init(fd: Int32, encoder: JSONEncoder) {
        self.fd = fd
        self.encoder = encoder
    }

    func send(_ message: WireServerMessage) async throws {
        guard !closed else {
            return
        }

        var data = try encoder.encode(message)
        data.append(0x0A)
        try data.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            try writeAll(fd: fd, bytes: UnsafeBufferPointer(start: pointer, count: data.count))
        }
    }

    func close() {
        guard !closed else {
            return
        }

        closed = true
        _ = systemClose(fd)
    }
}

private final class SocketLineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) {
        self.fd = fd
    }

    func readLine() throws -> Data? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                return Data(line)
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(Int(count)))
                continue
            }

            if count == 0 {
                if buffer.isEmpty {
                    return nil
                }

                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                return line
            }

            if errno == EINTR {
                continue
            }

            throw HelperError.socketFailure("read failed: \(errno)")
        }
    }
}

private struct WireClientMessage: Decodable {
    let id: String
    let method: WireRequestMethod
    let sessionID: String?
    let reconnectToken: String?
    let hostName: String?
    let hostAddress: String?
    let port: Int?
    let username: String?
    let label: String?
    let kind: String?
    let terminalType: String?
    let columns: Int?
    let rows: Int?
    let reconnectMode: String?
    let idleTimeoutSeconds: Int?
    let startupCommand: String?
    let bytes: [UInt8]?
    let exitCode: Int32?
}

private enum WireRequestMethod: String, Decodable {
    case hello
    case listSessions
    case createSession
    case attachSession
    case detachSession
    case sendInput
    case resizeSession
    case closeSession
}

private struct WireServerMessage: Encodable {
    let id: String?
    let hello: WireHello?
    let sessions: [WireSessionSummary]?
    let session: WireSessionSummary?
    let acknowledged: Bool?
    let errorCode: String?
    let event: WireEvent?
}

private struct WireHello: Encodable {
    let protocolVersion: Int
    let helperVersion: String
    let capabilities: [String]
}

private struct WireSessionSummary: Encodable {
    let descriptor: WirePersistentSessionDescriptor
    let reconnectToken: String?
}

private struct WirePersistentSessionDescriptor: Encodable {
    let id: String
    let hostName: String
    let hostAddress: String
    let port: Int
    let username: String
    let label: String
    let kind: String
    let createdAt: Date
    let lastAttachedAt: Date?
    let terminalType: String
    let columns: Int
    let rows: Int
    let liveness: String
    let exitCode: Int32?
    let recoveryState: String
    let reconnectMode: String
    let idleTimeoutSeconds: Int?
    let startupCommand: String?

    init(descriptor: PersistentSessionDescriptor) {
        self.id = descriptor.id.rawValue
        self.hostName = descriptor.hostName
        self.hostAddress = descriptor.hostAddress
        self.port = descriptor.port
        self.username = descriptor.username
        self.label = descriptor.label
        self.kind = descriptor.kind.rawValue
        self.createdAt = descriptor.createdAt
        self.lastAttachedAt = descriptor.lastAttachedAt
        self.terminalType = descriptor.terminalType
        self.columns = descriptor.lastKnownSize.columns
        self.rows = descriptor.lastKnownSize.rows
        switch descriptor.liveness {
        case .attached:
            liveness = "attached"
            exitCode = nil
        case .detached:
            liveness = "detached"
            exitCode = nil
        case .lost:
            liveness = "lost"
            exitCode = nil
        case .exited(let code):
            liveness = "exited"
            exitCode = code
        }
        switch descriptor.recoveryState {
        case .notApplicable:
            recoveryState = "notApplicable"
        case .reconnectable:
            recoveryState = "reconnectable"
        case .reconnecting:
            recoveryState = "reconnecting"
        case .unavailable:
            recoveryState = "unavailable"
        }
        reconnectMode = descriptor.reconnectPolicy.mode.rawValue
        idleTimeoutSeconds = descriptor.reconnectPolicy.idleTimeoutSeconds
        startupCommand = descriptor.startupCommand
    }
}

private struct WireEvent: Encodable {
    let kind: String
    let sessionID: String?
    let sequence: Int64?
    let bytes: [UInt8]?
    let descriptor: WirePersistentSessionDescriptor?
    let replayedThroughSequence: Int64?
    let exitCode: Int32?
    let errorCode: String?

    init(event: RemotePersistenceEvent) {
        switch event {
        case .output(let sessionID, let sequence, let bytes):
            kind = "output"
            self.sessionID = sessionID.rawValue
            self.sequence = sequence
            self.bytes = bytes
            descriptor = nil
            replayedThroughSequence = nil
            exitCode = nil
            errorCode = nil
        case .stateChanged(let descriptor):
            kind = "stateChanged"
            sessionID = descriptor.id.rawValue
            sequence = nil
            bytes = nil
            self.descriptor = WirePersistentSessionDescriptor(descriptor: descriptor)
            replayedThroughSequence = nil
            exitCode = nil
            errorCode = nil
        case .replayStarted(let sessionID):
            kind = "replayStarted"
            self.sessionID = sessionID.rawValue
            sequence = nil
            bytes = nil
            descriptor = nil
            replayedThroughSequence = nil
            exitCode = nil
            errorCode = nil
        case .replayFinished(let sessionID, let replayedThroughSequence):
            kind = "replayFinished"
            self.sessionID = sessionID.rawValue
            sequence = nil
            bytes = nil
            descriptor = nil
            self.replayedThroughSequence = replayedThroughSequence
            exitCode = nil
            errorCode = nil
        case .sessionExited(let sessionID, let exitCode):
            kind = "sessionExited"
            self.sessionID = sessionID.rawValue
            sequence = nil
            bytes = nil
            descriptor = nil
            replayedThroughSequence = nil
            self.exitCode = exitCode
            errorCode = nil
        case .error(let sessionID, let error):
            kind = "error"
            self.sessionID = sessionID?.rawValue
            sequence = nil
            bytes = nil
            descriptor = nil
            replayedThroughSequence = nil
            exitCode = nil
            errorCode = HelperError(error: error).code
        }
    }
}

private enum HelperError: Error {
    case protocolError
    case authenticationFailed
    case connectionFailed
    case sessionNotFound
    case sessionExited
    case socketFailure(String)

    init(error: SemanticDeveloperError) {
        switch error {
        case .authenticationFailed:
            self = .authenticationFailed
        case .disconnected(.sessionNotFound):
            self = .sessionNotFound
        case .disconnected(.sessionExited):
            self = .sessionExited
        default:
            self = .connectionFailed
        }
    }

    var code: String {
        switch self {
        case .protocolError:
            return "protocolError"
        case .authenticationFailed:
            return "authenticationFailed"
        case .connectionFailed, .socketFailure:
            return "connectionFailed"
        case .sessionNotFound:
            return "sessionNotFound"
        case .sessionExited:
            return "sessionExited"
        }
    }
}

private struct LaunchedProcess {
    let masterFD: Int32
    let childPID: pid_t
}

private func writeErrorLine(_ message: String) {
    let data = Data((message + "\n").utf8)
    try? data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            return
        }
        try writeAll(fd: STDERR_FILENO, bytes: UnsafeBufferPointer(start: baseAddress, count: data.count))
    }
}

private func openPseudoTerminalMaster() -> Int32 {
    #if canImport(Darwin)
    return posix_openpt(O_RDWR | O_NOCTTY)
    #else
    return linux_posix_openpt(O_RDWR | O_NOCTTY)
    #endif
}

private func preparePseudoTerminalSlave(masterFD: Int32) -> UnsafeMutablePointer<CChar>? {
    #if canImport(Darwin)
    guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0 else {
        return nil
    }
    return ptsname(masterFD)
    #else
    guard linux_grantpt(masterFD) == 0, linux_unlockpt(masterFD) == 0 else {
        return nil
    }
    return linux_ptsname(masterFD)
    #endif
}

private func streamSocketType() -> Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

private func launchPersistedProcess(
    terminalType: String,
    size: TerminalSize,
    startupCommand: String?
) throws -> LaunchedProcess {
    let masterFD = openPseudoTerminalMaster()
    guard masterFD >= 0 else {
        throw HelperError.connectionFailed
    }

    guard let slaveNamePointer = preparePseudoTerminalSlave(masterFD: masterFD) else {
        _ = close(masterFD)
        throw HelperError.connectionFailed
    }

    let slaveName = String(cString: slaveNamePointer)
    // O_NOCTTY: do not let the parent helper claim this PTY as its
    // controlling terminal. If the parent claims it, the child's
    // ioctl(TIOCSCTTY) silently fails (stealing requires CAP_SYS_ADMIN)
    // and bash boots without job control, printing
    // "cannot set terminal process group" / "no job control in this shell".
    let slaveFD = open(slaveName, O_RDWR | O_NOCTTY)
    guard slaveFD >= 0 else {
        _ = close(masterFD)
        throw HelperError.connectionFailed
    }

    defer {
        _ = close(slaveFD)
    }

    var windowSize = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
    #if canImport(Darwin)
    _ = ioctl(slaveFD, TIOCSWINSZ, &windowSize)
    #else
    _ = ioctl(slaveFD, UInt(TIOCSWINSZ), &windowSize)
    #endif

    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"

    let childPID = platform_fork()
    guard childPID >= 0 else {
        _ = close(masterFD)
        throw HelperError.connectionFailed
    }

    if childPID == 0 {
        _ = setsid()
        #if canImport(Darwin)
        _ = ioctl(slaveFD, TIOCSCTTY, 0)
        #else
        _ = ioctl(slaveFD, UInt(TIOCSCTTY), 0)
        #endif

        _ = dup2(slaveFD, STDIN_FILENO)
        _ = dup2(slaveFD, STDOUT_FILENO)
        _ = dup2(slaveFD, STDERR_FILENO)

        if slaveFD > STDERR_FILENO {
            _ = close(slaveFD)
        }
        _ = close(masterFD)

        setenv("TERM", terminalType, 1)

        if let startupCommand {
            _ = withCStringArray([shell, "-lc", startupCommand]) { argv in
                execvp(shell, argv)
            }
        } else {
            _ = withCStringArray([shell, "-l"]) { argv in
                execvp(shell, argv)
            }
        }

        _exit(127)
    }

    try setWindowSize(fd: masterFD, size: size)
    return LaunchedProcess(masterFD: masterFD, childPID: childPID)
}

private func setWindowSize(fd: Int32, size: TerminalSize) throws {
    var windowSize = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
    #if canImport(Darwin)
    let result = ioctl(fd, TIOCSWINSZ, &windowSize)
    #else
    let result = ioctl(fd, UInt(TIOCSWINSZ), &windowSize)
    #endif
    guard result == 0 else {
        throw HelperError.connectionFailed
    }
}

private func normalizedLabel(label: String?, kind: PersistentSessionKind, hostName: String) -> String {
    if let label {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }

    switch kind {
    case .shell:
        return hostName
    case .codex:
        return "\(hostName) Codex"
    case .custom:
        return "\(hostName) Session"
    }
}

private func daemonSocketPath() throws -> String {
    let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".semantic-developer", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    chmod(directoryURL.path, S_IRWXU)
    return directoryURL.appendingPathComponent("persistence-helper.sock").path
}

private func ensureDaemonAndConnect(socketPath: String) throws -> Int32 {
    if let socket = try? connectUnixSocket(at: socketPath) {
        return socket
    }

    if FileManager.default.fileExists(atPath: socketPath) {
        unlink(socketPath)
    }

    try spawnDaemon()

    for _ in 0..<20 {
        if let socket = try? connectUnixSocket(at: socketPath) {
            return socket
        }
        usleep(100_000)
    }

    throw HelperError.connectionFailed
}

private func spawnDaemon() throws {
    let childPID = platform_fork()
    guard childPID >= 0 else {
        throw HelperError.connectionFailed
    }

    if childPID > 0 {
        return
    }

    _ = setsid()

    let nullFD = open("/dev/null", O_RDWR)
    if nullFD >= 0 {
        _ = dup2(nullFD, STDIN_FILENO)
        _ = dup2(nullFD, STDOUT_FILENO)
        _ = dup2(nullFD, STDERR_FILENO)
        if nullFD > STDERR_FILENO {
            _ = close(nullFD)
        }
    }

    let executablePath = CommandLine.arguments[0]
    _ = withCStringArray([executablePath, "--daemon"]) { argv in
        execvp(executablePath, argv)
    }

    _exit(127)
}

private func makeUnixListener(at path: String) throws -> Int32 {
    unlink(path)

    let fd = socket(AF_UNIX, streamSocketType(), 0)
    guard fd >= 0 else {
        throw HelperError.socketFailure("socket failed: \(errno)")
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        _ = close(fd)
        throw HelperError.socketFailure("socket path too long")
    }

    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
        for (index, byte) in pathBytes.enumerated() {
            rawBuffer[index] = byte
        }
        rawBuffer[pathBytes.count] = 0
    }

    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length)
        }
    }
    guard bindResult == 0 else {
        _ = close(fd)
        throw HelperError.socketFailure("bind failed: \(errno)")
    }

    chmod(path, S_IRUSR | S_IWUSR)

    guard listen(fd, 16) == 0 else {
        _ = close(fd)
        throw HelperError.socketFailure("listen failed: \(errno)")
    }

    return fd
}

private func connectUnixSocket(at path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, streamSocketType(), 0)
    guard fd >= 0 else {
        throw HelperError.socketFailure("socket failed: \(errno)")
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        _ = close(fd)
        throw HelperError.socketFailure("socket path too long")
    }

    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
        for (index, byte) in pathBytes.enumerated() {
            rawBuffer[index] = byte
        }
        rawBuffer[pathBytes.count] = 0
    }

    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, length)
        }
    }

    guard result == 0 else {
        _ = close(fd)
        throw HelperError.socketFailure("connect failed: \(errno)")
    }

    return fd
}

private func copyBytes(from sourceFD: Int32, to destinationFD: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(sourceFD, &buffer, buffer.count)
        if count > 0 {
            do {
                try writeAll(fd: destinationFD, bytes: Array(buffer.prefix(Int(count))))
            } catch {
                return
            }
            continue
        }

        if count == 0 {
            return
        }

        if errno == EINTR {
            continue
        }

        return
    }
}

private func writeAll(fd: Int32, bytes: [UInt8]) throws {
    try bytes.withUnsafeBufferPointer { buffer in
        try writeAll(fd: fd, bytes: buffer)
    }
}

private func writeAll(fd: Int32, bytes: UnsafeBufferPointer<UInt8>) throws {
    var offset = 0
    while offset < bytes.count {
        let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if written > 0 {
            offset += Int(written)
            continue
        }

        if written < 0, errno == EINTR {
            continue
        }

        throw HelperError.connectionFailed
    }
}

private func processDidExit(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}

private func processExitStatus(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func processWasSignaled(_ status: Int32) -> Bool {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f
}

private func processTermSignal(_ status: Int32) -> Int32 {
    status & 0x7f
}

private func withCStringArray<R>(
    _ arguments: [String],
    _ body: ([UnsafeMutablePointer<CChar>?]) throws -> R
) rethrows -> R {
    var cStrings = arguments.map { strdup($0) }
    cStrings.append(nil)
    defer {
        for pointer in cStrings where pointer != nil {
            free(pointer)
        }
    }
    return try body(cStrings)
}
