import Foundation
import Network

/// A loopback RTMP server for the checks: does the server side of the handshake, answers
/// `connect` and `createStream`, then answers `publish` according to its behaviour.
final class RTMPTestServer {
    enum Behaviour { case accept, rejectPublish(description: String), dropAfterPublish }

    struct StartError: Error, CustomStringConvertible { let description: String }

    /// One client connection and where it is in the protocol.
    private final class Peer {
        let connection: NWConnection
        var handshake: [UInt8] = []
        var stage = 0 // 0: waiting for C0+C1, 1: waiting for C2, 2: chunks
        var reader = RTMPChunkReader()
        let writer = RTMPChunkWriter()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private static let handshakeSize = 1536

    private let behaviour: Behaviour
    private let queue = DispatchQueue(label: "RTMPTestServer")
    private let listener: NWListener
    private var peers: [Peer] = []
    private var receivedMessages: [RTMPMessage] = []
    private var key: String?

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    /// Every message clients sent, in order, once the handshake was done.
    var received: [RTMPMessage] { queue.sync { receivedMessages } }
    var publishedKey: String? { queue.sync { key } }

    init(behaviour: Behaviour) throws {
        self.behaviour = behaviour
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failure == nil, port != 0 else {
            listener.cancel()
            throw StartError(description: "test server didn't start: \(failure.map { "\($0)" } ?? "timed out")")
        }
    }

    deinit { stop() }

    func stop() {
        listener.cancel()
        queue.async { [peers] in peers.forEach { $0.connection.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection)
        peers.append(peer)
        connection.start(queue: queue)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(data, from: peer) }
            if isComplete || error != nil {
                peer.connection.cancel()
            } else {
                self.receive(peer)
            }
        }
    }

    private func handle(_ data: Data, from peer: Peer) {
        var bytes = [UInt8](data)
        if peer.stage < 2 {
            peer.handshake += bytes
            bytes = []
            if peer.stage == 0, peer.handshake.count >= 1 + Self.handshakeSize {
                let c1 = peer.handshake[1...Self.handshakeSize]
                var reply = Data([0x03])
                reply.append(contentsOf: [UInt8](repeating: 0, count: 8))
                reply.append(contentsOf: (0..<Self.handshakeSize - 8).map { _ in UInt8.random(in: .min ... .max) })
                reply.append(contentsOf: c1)
                peer.connection.send(content: reply, completion: .idempotent)
                peer.handshake.removeFirst(1 + Self.handshakeSize)
                peer.stage = 1
            }
            if peer.stage == 1, peer.handshake.count >= Self.handshakeSize {
                bytes = Array(peer.handshake[Self.handshakeSize...])
                peer.handshake = []
                peer.stage = 2
            }
            if bytes.isEmpty { return }
        }
        guard let messages = try? peer.reader.append(Data(bytes)) else {
            peer.connection.cancel()
            return
        }
        for message in messages {
            receivedMessages.append(message)
            if message.type == RTMPMessage.Kind.command.rawValue { answer(message, from: peer) }
        }
    }

    private func answer(_ message: RTMPMessage, from peer: Peer) {
        guard let values = try? AMF0.decode(message.payload), case .string(let name)? = values.first else { return }
        let transaction = values.count > 1 ? values[1] : .number(0)
        switch name {
        case "connect":
            send([.string("_result"), transaction,
                  .object([.init(key: "fmsVer", value: .string("FMS/3,0,1,123"))]),
                  status("status", "NetConnection.Connect.Success", "Connection succeeded.")], to: peer)
        case "createStream":
            send([.string("_result"), transaction, .null, .number(1)], to: peer)
        case "publish":
            if values.count > 3, case .string(let published) = values[3] { key = published }
            switch behaviour {
            case .accept:
                send(onStatus("status", "NetStream.Publish.Start", "Publishing."), to: peer, streamID: 1)
            case .rejectPublish(let description):
                send(onStatus("error", "NetStream.Publish.BadName", description), to: peer, streamID: 1)
            case .dropAfterPublish:
                send(onStatus("status", "NetStream.Publish.Start", "Publishing."), to: peer, streamID: 1) {
                    peer.connection.cancel()
                }
            }
        default:
            break
        }
    }

    private func status(_ level: String, _ code: String, _ description: String) -> AMF0 {
        .object([
            .init(key: "level", value: .string(level)),
            .init(key: "code", value: .string(code)),
            .init(key: "description", value: .string(description)),
        ])
    }

    private func onStatus(_ level: String, _ code: String, _ description: String) -> [AMF0] {
        [.string("onStatus"), .number(0), .null, status(level, code, description)]
    }

    private func send(_ values: [AMF0], to peer: Peer, streamID: UInt32 = 0, then: (() -> Void)? = nil) {
        var payload = Data()
        values.forEach { $0.encode(into: &payload) }
        let message = RTMPMessage(type: RTMPMessage.Kind.command.rawValue, streamID: streamID, timestamp: 0, payload: payload)
        peer.connection.send(content: peer.writer.chunks(for: message, chunkStreamID: 3), completion: .contentProcessed { _ in
            then?()
        })
    }
}
