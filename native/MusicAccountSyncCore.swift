import Foundation

enum NovaSyncValue: Codable, Equatable, Sendable {
    case object([String: NovaSyncValue]), array([NovaSyncValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode([NovaSyncValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: NovaSyncValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }
    subscript(key: String) -> NovaSyncValue? { if case .object(let value) = self { return value[key] }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var array: [NovaSyncValue]? { if case .array(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var safeInt: Int? { guard let value = number, value.isFinite, value > Double(Int.min), value < Double(Int.max), value.rounded() == value else { return nil }; return Int(value) }
    var object: [String: NovaSyncValue]? { if case .object(let value) = self { return value }; return nil }
    static func encoded<T: Encodable>(_ value: T) throws -> Self { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    func decoded<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

struct NovaSyncRecord: Codable, Equatable, Sendable {
    var clock: Int64
    var actor: String
    var deleted: Bool
    var value: NovaSyncValue?
}

struct NovaSyncDocument: Codable, Equatable, Sendable {
    var version = 1
    var records: [String: NovaSyncRecord] = [:]
    var values: [String: NovaSyncValue] { records.compactMapValues { $0.deleted ? nil : $0.value } }
    func validate() throws {
        guard version == 1, records.count <= 30000, (try JSONEncoder().encode(self)).count <= 10_000_000 else { throw NovaSyncFailure.invalidDocument }
        for (key, record) in records {
            guard Self.validKey(key), record.clock > 0, record.clock <= 9_007_199_254_740_991,
                  UUID(uuidString: record.actor) != nil, record.deleted || record.value != nil else { throw NovaSyncFailure.invalidDocument }
        }
    }
    static func validKey(_ key: String) -> Bool { key.range(of: "^[A-Za-z]+:[A-Za-z0-9_.:-]{1,240}$", options: .regularExpression) != nil }
    func merging(_ other: Self) throws -> Self {
        try validate(); try other.validate()
        var next = self
        for (key, incoming) in other.records {
            guard let current = next.records[key] else { next.records[key] = incoming; continue }
            if incoming.clock > current.clock || (incoming.clock == current.clock && incoming.actor.lowercased() > current.actor.lowercased()) {
                next.records[key] = incoming
            } else if incoming.clock == current.clock && incoming.actor.lowercased() == current.actor.lowercased() && incoming != current {
                throw NovaSyncFailure.revisionCollision
            }
        }
        return next
    }
    func updating(previous: [String: NovaSyncValue], next: [String: NovaSyncValue], actor: UUID) throws -> Self {
        try validate()
        var result = self, clock = records.values.map(\.clock).max() ?? 0
        for key in Set(previous.keys).union(next.keys).sorted() where previous[key] != next[key] {
            guard Self.validKey(key), clock < 9_007_199_254_740_991 else { throw NovaSyncFailure.invalidDocument }
            clock += 1
            result.records[key] = NovaSyncRecord(clock: clock, actor: actor.uuidString.lowercased(), deleted: next[key] == nil, value: next[key])
        }
        return result
    }
}

enum NovaSyncFailure: LocalizedError {
    case invalidDocument, revisionCollision, notConfigured, invalidResponse, accountChanged, unsyncedChanges, message(String)
    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The account library contains unsupported data. Your local library has not been replaced."
        case .revisionCollision: return "Two records have the same revision but different contents. Sync stopped to protect your library."
        case .notConfigured: return "Account sync is not available yet. Your library remains on this device."
        case .invalidResponse: return "The sync service returned an unexpected response."
        case .accountChanged: return "The account changed while syncing."
        case .unsyncedChanges: return "Some changes have not synced. Go online and sync before signing out."
        case .message(let text): return text
        }
    }
}


struct MusicAccountProfile: Codable, Equatable, Sendable {
    var name = ""
    var icon = "♪"
    var color = "#1ed760"
    var image = ""
    static let icons = ["♪","♫","🎧","🎵","⭐","🌙","🌸","🦋","⚡","💿","🎹","🚀"]
    static let colors = ["#1ed760","#a78bfa","#fb7185","#38bdf8","#fbbf24","#fb923c"]
    func validated() throws -> Self {
        guard name.utf16.count <= 60, Self.icons.contains(icon), Self.colors.contains(color), image.utf8.count <= 180000,
              image.isEmpty || image.range(of: #"^data:image/(jpeg|png);base64,[A-Za-z0-9+/]+={0,2}$"#,options:.regularExpression) != nil else { throw NovaSyncFailure.invalidDocument }
        var result = self; result.name = name.trimmingCharacters(in:.whitespacesAndNewlines); return result
    }
}
