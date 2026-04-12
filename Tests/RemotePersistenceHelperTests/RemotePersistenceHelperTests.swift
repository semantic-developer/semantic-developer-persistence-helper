import Foundation
import Testing

private final class ResponseBox: @unchecked Sendable {
    var value = ""
}

@Test func helperHelloReportsProtocolAndCapabilities() throws {
    let helperURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build")
        .appendingPathComponent("debug")
        .appendingPathComponent("semantic-developer-helper")

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
    let helperURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        .appendingPathComponent(".build")
        .appendingPathComponent("debug")
        .appendingPathComponent("semantic-developer-helper")
    let homeURL = fileManager.temporaryDirectory.appendingPathComponent("semantic-developer-helper-test-\(UUID().uuidString)")
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

    defer {
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cleanup.arguments = ["pkill", "-f", helperURL.path]
        try? cleanup.run()
        cleanup.waitUntilExit()
        try? fileManager.removeItem(at: homeURL)
    }

    let process = Process()
    process.executableURL = helperURL
    process.arguments = ["--stdio"]
    process.environment = (ProcessInfo.processInfo.environment).merging(["HOME": homeURL.path]) { _, new in new }

    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()

    let semaphore = DispatchSemaphore(value: 0)
    let responseBox = ResponseBox()
    DispatchQueue.global(qos: .userInitiated).async {
        let data = stdout.fileHandleForReading.availableData
        responseBox.value = String(decoding: data, as: UTF8.self)
        semaphore.signal()
    }

    let request = #"{"id":"1","method":"hello"}"#
    stdin.fileHandleForWriting.write(Data((request + "\n").utf8))

    let waitResult = semaphore.wait(timeout: .now() + 3)
    process.terminate()
    process.waitUntilExit()

    #expect(waitResult == .success)
    #expect(responseBox.value.contains(#""id":"1""#))
    #expect(responseBox.value.contains(#""protocolVersion":1"#))
}
