import Foundation
import Testing

private final class HelperClient: @unchecked Sendable {
  private let process: Process
  private let stdin: Pipe
  private let stdout: Pipe
  private let lock = NSLock()
  private var buffer = Data()
  private var lines: [String] = []

  init(helperURL: URL, homeURL: URL) throws {
    process = Process()
    process.executableURL = helperURL
    process.arguments = ["--stdio"]
    process.environment = (ProcessInfo.processInfo.environment).merging(["HOME": homeURL.path]) {
      _, new in new
    }

    stdin = Pipe()
    stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()

    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        return
      }
      self?.append(data)
    }

    try process.run()
  }

  func send(_ json: String) {
    stdin.fileHandleForWriting.write(Data((json + "\n").utf8))
  }

  func waitForLine(
    timeout seconds: TimeInterval = 10,
    matching predicate: (String) -> Bool
  ) -> String? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      lock.lock()
      if let index = lines.firstIndex(where: predicate) {
        let line = lines.remove(at: index)
        lock.unlock()
        return line
      }
      lock.unlock()
      Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
  }

  func stop() {
    stdout.fileHandleForReading.readabilityHandler = nil
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }

  private func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }

    buffer.append(data)
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      let lineData = buffer.prefix(upTo: newlineIndex)
      buffer.removeSubrange(...newlineIndex)
      lines.append(String(decoding: lineData, as: UTF8.self))
    }
  }
}

private func helperURL() -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".build")
    .appendingPathComponent("debug")
    .appendingPathComponent("semantic-developer-helper")
}

private func copiedHelperURL(in homeURL: URL) throws -> URL {
  let binURL = homeURL.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
  let destinationURL = binURL.appendingPathComponent("semantic-developer-helper")
  try FileManager.default.copyItem(at: helperURL(), to: destinationURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700], ofItemAtPath: destinationURL.path)
  return destinationURL
}

private func jsonObject(from line: String) throws -> [String: Any] {
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func event(from line: String) throws -> [String: Any] {
  let object = try jsonObject(from: line)
  return try #require(object["event"] as? [String: Any])
}

private func outputText(from line: String) throws -> String {
  let eventObject = try event(from: line)
  let bytes = try #require(eventObject["bytes"] as? [Int])
  return String(decoding: bytes.map(UInt8.init), as: UTF8.self)
}

private func cleanUpHelperProcesses(helperURL: URL) {
  let cleanup = Process()
  cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  cleanup.arguments = ["pkill", "-f", helperURL.path]
  try? cleanup.run()
  cleanup.waitUntilExit()
}

@Suite(.serialized)
struct RemotePersistenceHelperIntegrationTests {
  @Test func helperHelloReportsProtocolAndCapabilities() throws {
    let helperURL = helperURL()

    let process = Process()
    process.executableURL = helperURL
    process.arguments = ["--hello"]

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: outputData, as: UTF8.self)

    #expect(process.terminationStatus == 0)
    #expect(output.contains("protocol=1"))
    #expect(output.contains("capabilities=listSessions"))
    #expect(output.contains("attachSession"))
  }

  @Test func helperBridgeRespondsToHelloOverStdio() throws {
    let fileManager = FileManager.default
    let homeURL = fileManager.temporaryDirectory.appendingPathComponent(
      "semantic-developer-helper-test-\(UUID().uuidString)")
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
    let helperURL = try copiedHelperURL(in: homeURL)

    defer {
      cleanUpHelperProcesses(helperURL: helperURL)
      try? fileManager.removeItem(at: homeURL)
    }

    let client = try HelperClient(helperURL: helperURL, homeURL: homeURL)
    defer { client.stop() }

    client.send(#"{"id":"1","method":"hello"}"#)
    let response = try #require(client.waitForLine { $0.contains(#""id":"1""#) })
    #expect(response.contains(#""protocolVersion":1"#))
  }

  @Test func helperSessionLifecycleSupportsDetachAttachReplayAndResize() throws {
    let fileManager = FileManager.default
    let homeURL = fileManager.temporaryDirectory.appendingPathComponent(
      "semantic-developer-helper-test-\(UUID().uuidString)")
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
    let helperURL = try copiedHelperURL(in: homeURL)

    defer {
      cleanUpHelperProcesses(helperURL: helperURL)
      try? fileManager.removeItem(at: homeURL)
    }

    let firstClient = try HelperClient(helperURL: helperURL, homeURL: homeURL)
    defer { firstClient.stop() }

    firstClient.send(
      #"{"id":"create","method":"createSession","hostName":"test-host","hostAddress":"127.0.0.1","port":22,"username":"tester","label":"Lifecycle","kind":"shell","terminalType":"xterm-256color","columns":80,"rows":24,"reconnectMode":"manual","startupCommand":"printf 'semantic-ready\n'; sleep 30"}"#
    )

    let createLine = try #require(firstClient.waitForLine { $0.contains(#""id":"create""#) })
    let createObject = try jsonObject(from: createLine)
    let createSession = try #require(createObject["session"] as? [String: Any])
    let createDescriptor = try #require(createSession["descriptor"] as? [String: Any])
    let sessionID = try #require(createDescriptor["id"] as? String)
    let reconnectToken = try #require(createSession["reconnectToken"] as? String)

    #expect(createDescriptor["liveness"] as? String == "attached")
    #expect(createDescriptor["columns"] as? Int == 80)
    #expect(createDescriptor["rows"] as? Int == 24)

    let outputLine = try #require(
      firstClient.waitForLine { line in
        guard line.contains(#""kind":"output""#) else {
          return false
        }
        return (try? outputText(from: line).contains("semantic-ready")) == true
      })
    #expect(outputLine.contains(#""sessionID":"\#(sessionID)""#))

    firstClient.send(
      #"{"id":"resize","method":"resizeSession","sessionID":"\#(sessionID)","columns":100,"rows":30}"#
    )
    let resizeLine = try #require(firstClient.waitForLine { $0.contains(#""id":"resize""#) })
    let resizeObject = try jsonObject(from: resizeLine)
    let resizeSession = try #require(resizeObject["session"] as? [String: Any])
    let resizeDescriptor = try #require(resizeSession["descriptor"] as? [String: Any])
    #expect(resizeDescriptor["columns"] as? Int == 100)
    #expect(resizeDescriptor["rows"] as? Int == 30)

    firstClient.send(#"{"id":"detach","method":"detachSession","sessionID":"\#(sessionID)"}"#)
    let detachLine = try #require(firstClient.waitForLine { $0.contains(#""id":"detach""#) })
    let detachObject = try jsonObject(from: detachLine)
    let detachSession = try #require(detachObject["session"] as? [String: Any])
    let detachDescriptor = try #require(detachSession["descriptor"] as? [String: Any])
    #expect(detachDescriptor["liveness"] as? String == "detached")
    #expect(detachDescriptor["recoveryState"] as? String == "reconnectable")

    let secondClient = try HelperClient(helperURL: helperURL, homeURL: homeURL)
    defer { secondClient.stop() }

    secondClient.send(
      #"{"id":"attach","method":"attachSession","sessionID":"\#(sessionID)","reconnectToken":"\#(reconnectToken)"}"#
    )
    let attachLine = try #require(secondClient.waitForLine { $0.contains(#""id":"attach""#) })
    let attachObject = try jsonObject(from: attachLine)
    let attachSession = try #require(attachObject["session"] as? [String: Any])
    let attachDescriptor = try #require(attachSession["descriptor"] as? [String: Any])
    #expect(attachDescriptor["liveness"] as? String == "attached")

    _ = try #require(secondClient.waitForLine { $0.contains(#""kind":"replayStarted""#) })
    let replayOutputLine = try #require(
      secondClient.waitForLine { line in
        guard line.contains(#""kind":"output""#) else {
          return false
        }
        return (try? outputText(from: line).contains("semantic-ready")) == true
      })
    #expect(replayOutputLine.contains(#""sessionID":"\#(sessionID)""#))
    _ = try #require(secondClient.waitForLine { $0.contains(#""kind":"replayFinished""#) })
  }
}
