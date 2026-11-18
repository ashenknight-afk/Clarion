import Foundation

/// Runs one connection on a private queue against a test server and records every state it reports.
private final class ConnectionProbe {
    let connection: RTMPConnection
    private let lock = NSLock()
    private var states: [RTMPConnection.State] = []
    private let changed = DispatchSemaphore(value: 0)

    init(server: RTMPTestServer, key: String) throws {
        guard let target = RTMPConnection.Target(server: "rtmp://127.0.0.1:\(server.port)/live", key: key) else {
            throw CheckFailure(description: "no target for the test server")
        }
        connection = RTMPConnection(target: target, queue: DispatchQueue(label: "RTMPConnectionChecks"))
        connection.onState = { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            self.states.append(state)
            self.lock.unlock()
            self.changed.signal()
        }
        connection.start()
    }

    var history: [RTMPConnection.State] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    /// Waits up to 5 s for a reported state that matches.
    func wait(for what: String, _ matches: (RTMPConnection.State) -> Bool) throws {
        let deadline = DispatchTime.now() + 5
        while !history.contains(where: matches) {
            guard changed.wait(timeout: deadline) == .success else {
                throw CheckFailure(description: "timed out waiting for \(what); states: \(history)")
            }
        }
    }

    func close() throws {
        let done = DispatchSemaphore(value: 0)
        connection.close { done.signal() }
        guard done.wait(timeout: .now() + 5) == .success else { throw CheckFailure(description: "close didn't complete") }
    }
}

private func isFailed(_ state: RTMPConnection.State) -> Bool {
    if case .failed = state { return true }
    return false
}

/// Polls for up to 5 s.
private func eventually(_ what: String, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw CheckFailure(description: "timed out waiting for \(what)") }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func commandNames(_ messages: [RTMPMessage]) -> [String] {
    messages.compactMap { message in
        guard message.type == RTMPMessage.Kind.command.rawValue,
              case .string(let name)? = try? AMF0.decode(message.payload).first else { return nil }
        return name
    }
}

func rtmpConnectionChecks() {
    check("target parses rtmps with default port and trims the key") {
        let target = RTMPConnection.Target(server: "rtmps://live.twitch.tv/app", key: " abc\n")
        try expect(target?.host == "live.twitch.tv", "host")
        try expect(target?.port == 443, "port")
        try expect(target?.tls == true, "tls")
        try expect(target?.app == "app", "app")
        try expect(target?.key == "abc", "key")
    }

    check("target parses rtmp with an explicit port") {
        let target = RTMPConnection.Target(server: "rtmp://127.0.0.1:1935/live", key: "k")
        try expect(target?.port == 1935, "port")
        try expect(target?.tls == false, "tls")
    }

    check("target rejects other schemes and an empty key") {
        try expect(RTMPConnection.Target(server: "http://x/y", key: "k") == nil, "http accepted")
        try expect(RTMPConnection.Target(server: "rtmps://x/y", key: " \n") == nil, "empty key accepted")
    }

    check("publishes metadata, video and audio to an accepting server") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "live_123")
        try probe.wait(for: "publishing") { $0 == .publishing }

        let metadata = FLV.metadata(width: 1920, height: 1080, frameRate: 60, videoKbps: 6000, audioKbps: 160)
        let video = FLV.avcFrame(Data([0, 0, 0, 2, 0x65, 0x88]), keyframe: true)
        let audio = FLV.aacFrame(Data([1, 2, 3]))
        probe.connection.send(metadata: metadata)
        probe.connection.send(video: video, timestamp: 40, keyframe: true)
        probe.connection.send(audio: audio, timestamp: 21)

        func message(_ type: UInt8) -> RTMPMessage? { server.received.first { $0.type == type } }
        try eventually("media at the server") { message(8) != nil && message(9) != nil && message(18) != nil }
        try expect(message(18)?.payload == metadata && message(18)?.timestamp == 0, "metadata")
        try expect(message(9)?.payload == video && message(9)?.timestamp == 40, "video")
        try expect(message(8)?.payload == audio && message(8)?.timestamp == 21, "audio")
        try expect(server.publishedKey == "live_123", "published key")
        try probe.close()
    }

    check("a rejected publish fails without the key in its text") {
        let server = try RTMPTestServer(behaviour: .rejectPublish(description: "bad key SECRET"))
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "SECRET")
        try probe.wait(for: "failed", isFailed)
        guard case .failed(let text)? = probe.history.first(where: isFailed) else { return }
        try expect(!text.contains("SECRET"), "key in error text")
        try expect(!text.isEmpty, "empty error text")
    }

    check("a dropped connection after publishing fails") {
        let server = try RTMPTestServer(behaviour: .dropAfterPublish)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try probe.wait(for: "failed", isFailed)
        let history = probe.history
        guard let publishing = history.firstIndex(of: .publishing) else { throw CheckFailure(description: "never published: \(history)") }
        try expect(history[publishing...].contains(where: isFailed), "failed before publishing: \(history)")
    }

    check("close after publishing unpublishes and ends closed") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try probe.wait(for: "publishing") { $0 == .publishing }
        try probe.close()
        try eventually("FCUnpublish and deleteStream") {
            let names = commandNames(server.received)
            return names.contains("FCUnpublish") && names.contains("deleteStream")
        }
        try expect(probe.history.last == .closed, "last state \(String(describing: probe.history.last))")
    }
}
