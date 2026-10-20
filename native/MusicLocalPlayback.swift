import Foundation
import Network
import CryptoKit

@MainActor
protocol MusicLocalPlaybackTransport: AnyObject {
    var onReceive: (Data) -> Void { get set }
    var onPeersChanged: (Set<String>) -> Void { get set }
    var onError: (String?) -> Void { get set }
    func start(id: String, key: Data, payload: Data)
    func publish(_ payload: Data)
    func refresh() async
    func stop()
}

/// Persistent, authenticated local-network transport. Library sync provisions the
/// random shared key once; no playback packet or discovery request uses CloudKit.
@MainActor
final class MusicLocalPlayback: MusicLocalPlaybackTransport {
    static let serviceType = "_novamusic._tcp"
    static let maximumPayload = 10_000_000
    var onReceive: (Data) -> Void = { _ in }
    var onPeersChanged: (Set<String>) -> Void = { _ in }
    var onError: (String?) -> Void = { _ in }
    private let now: () -> Date
    private var lastRefresh: Date?
    private var recovery: Task<Void, Never>?
    private var epoch = UUID()
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    private var identity = ""
    private var secret: Data?
    private var latest = Data()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var retry: Timer?
    private var endpoints: [String: NWEndpoint] = [:]
    private var channels: [UUID: Channel] = [:]
    private var seen: [UUID: Date] = [:]
    private(set) var peers = Set<String>()

    private final class Channel {
        let connection: NWConnection
        let expected: String?
        var peer: String?
        var buffer = Data()
        var sending = false
        var pending: Data?
        var deadline: Task<Void, Never>?
        init(_ connection: NWConnection, expected: String?) { self.connection = connection; self.expected = expected }
    }
    struct Packet: Codable {
        var version = 1
        var id = UUID()
        var sender: String
        var at = Date()
        var payload: Data
    }
    enum Failure: Error { case invalidKey, invalidPacket, oversized }
    static func seal(_ packet: Packet, key: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.invalidKey }
        guard packet.payload.count <= maximumPayload else { throw Failure.oversized }
        return try AES.GCM.seal(JSONEncoder().encode(packet), using: SymmetricKey(data: key), authenticating: Data("NovaMusic-LAN-1".utf8)).combined!
    }
    static func open(_ data: Data, key: Data, now: Date = Date()) throws -> Packet {
        guard key.count == 32 else { throw Failure.invalidKey }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: Data("NovaMusic-LAN-1".utf8))
        let packet = try JSONDecoder().decode(Packet.self, from: clear)
        guard packet.version == 1, UUID(uuidString: packet.sender) != nil,
              abs(now.timeIntervalSince(packet.at)) < 60, packet.payload.count <= maximumPayload else { throw Failure.invalidPacket }
        return packet
    }
    static func framed(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data); return frame
    }
    static func takeFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 28, length <= 14_000_000 else { throw Failure.oversized }
        guard buffer.count >= length + 4 else { return nil }
        let frame = Data(buffer.dropFirst(4).prefix(length)); buffer.removeFirst(length + 4); return frame
    }
    func start(id: String, key: Data, payload: Data) {
        guard UUID(uuidString: id) != nil, key.count == 32, payload.count <= Self.maximumPayload else { return }
        if identity == id, secret == key, listener != nil { latest = payload; return }
        stop(); identity = id; secret = key; latest = payload; lastRefresh = now()
        let epoch = self.epoch
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.includePeerToPeer = false
            parameters.prohibitedInterfaceTypes = [.cellular]
            let listener = try NWListener(using: parameters)
            listener.service = .init(name: id, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.attach(connection, expected: nil) } }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.epoch == epoch else { return }
                    if case .failed = state {
                        self.onError("Local network discovery is unavailable. Check Local Network access in Settings.")
                        self.scheduleRecovery()
                    }
                    if case .waiting = state { self.onError("Allow Local Network access to connect Nova Music devices.") }
                }
            }
            self.listener = listener; listener.start(queue: .main)
            let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    guard let self, self.epoch == epoch else { return }
                    var endpoints: [String: NWEndpoint] = [:]
                    for result in results {
                        if case let .service(name, _, _, _) = result.endpoint, UUID(uuidString: name) != nil, name != self.identity { endpoints[name] = result.endpoint }
                    }
                    self.endpoints = endpoints; self.connectAvailable()
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.epoch == epoch else { return }
                    if case .waiting = state { self.onError("Allow Local Network access to connect Nova Music devices.") }
                    if case .failed = state { self.scheduleRecovery() }
                }
            }
            self.browser = browser; browser.start(queue: .main)
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.connectAvailable() } }
            retry = timer; RunLoop.main.add(timer, forMode: .common)
        } catch { onError("Local network discovery could not start. Try reopening Nova Music.") }
    }
    func refresh() async {
        guard secret != nil else { return }
        // Suspended TCP sockets can still look ready after returning to the app.
        // Rebuild discovery and reauthenticate instead of trusting the stale channel.
        if let lastRefresh, now().timeIntervalSince(lastRefresh) > 8 { restart() }
        lastRefresh = now()
        connectAvailable()
    }
    private func restart() {
        guard let key = secret else { return }
        let id = identity, payload = latest
        stop(); start(id: id, key: key, payload: payload)
    }
    private func scheduleRecovery() {
        guard recovery == nil else { return }
        let epoch = self.epoch
        recovery = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.epoch == epoch else { return }
            self.recovery = nil; self.restart()
        }
    }
    func publish(_ payload: Data) {
        guard payload.count <= Self.maximumPayload, let secret else { return }
        latest = payload
        guard let encrypted = try? Self.seal(Packet(sender: identity, payload: payload), key: secret) else { return }
        let frame = Self.framed(encrypted)
        for id in Array(channels.keys) { send(frame, to: id) }
    }
    func stop() {
        epoch = UUID(); lastRefresh = nil; recovery?.cancel(); recovery = nil
        retry?.invalidate(); retry = nil
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        for channel in channels.values { channel.deadline?.cancel(); channel.connection.cancel() }
        channels = [:]; endpoints = [:]; seen = [:]; secret = nil; latest = Data()
        peers = []; onPeersChanged(peers)
    }
    private func connectAvailable() {
        for (id, endpoint) in endpoints where identity < id && !channels.values.contains(where: { $0.expected == id || $0.peer == id }) {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp); parameters.prohibitedInterfaceTypes = [.cellular]
            attach(NWConnection(to: endpoint, using: parameters), expected: id)
        }
    }
    private func attach(_ connection: NWConnection, expected: String?) {
        guard channels.count < 32 else { connection.cancel(); return }
        let id = UUID(), channel = Channel(connection, expected: expected); channels[id] = channel
        channel.deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, self?.channels[id]?.peer == nil { self?.drop(id) }
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.channels[id] != nil else { return }
                switch state {
                case .ready:
                    if let key = self.secret, let packet = try? Self.seal(Packet(sender: self.identity, payload: self.latest), key: key) { self.send(Self.framed(packet), to: id) }
                    self.receive(id)
                case .waiting, .failed, .cancelled: self.drop(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    private func send(_ frame: Data, to id: UUID) {
        guard let channel = channels[id] else { return }
        if channel.sending { channel.pending = frame; return }
        channel.sending = true
        channel.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, let channel = self.channels[id] else { return }
                channel.sending = false
                if error != nil { self.drop(id); return }
                if let pending = channel.pending { channel.pending = nil; self.send(pending, to: id) }
            }
        })
    }
    private func receive(_ id: UUID) {
        guard let channel = channels[id] else { return }
        channel.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let channel = self.channels[id], let secret = self.secret else { return }
                if let data { channel.buffer.append(data) }
                do {
                    guard channel.buffer.count <= 14_065_536 else { throw Failure.oversized }
                    while let frame = try Self.takeFrame(from: &channel.buffer) {
                        let packet = try Self.open(frame, key: secret)
                        guard packet.sender != self.identity, channel.expected == nil || channel.expected == packet.sender,
                              channel.peer == nil || channel.peer == packet.sender else { throw Failure.invalidPacket }
                        channel.peer = packet.sender; channel.deadline?.cancel()
                        self.updatePeers(); self.onError(nil)
                        self.seen = self.seen.filter { Date().timeIntervalSince($0.value) < 60 }
                        if self.seen[packet.id] == nil { self.seen[packet.id] = Date(); self.onReceive(packet.payload) }
                    }
                    if complete || error != nil { self.drop(id) } else { self.receive(id) }
                } catch { self.drop(id) }
            }
        }
    }
    private func drop(_ id: UUID) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        channel.deadline?.cancel(); channel.connection.cancel(); updatePeers()
    }
    private func updatePeers() {
        let next = Set(channels.values.compactMap(\.peer))
        if next != peers { peers = next; onPeersChanged(next) }
    }
}
