import Foundation
import CloudKit
import CryptoKit

/// Injectable boundary: tests exercise the same merge/retry path without an iCloud account.
@MainActor
protocol NovaCloudStorage {
    func accountID() async throws -> String
    func load(_ name: String) async throws -> NovaCloudSnapshot
    func save(_ document: NovaSyncDocument, named: String, revision: String?) async throws
}
struct NovaCloudSnapshot {
    var document: NovaSyncDocument
    var revision: String?
}

enum NovaCloudFailure: LocalizedError {
    case conflict
    case accountUnavailable
    case accountChanged
    var errorDescription: String? {
        switch self {
        case .conflict: return "Another device updated iCloud. Your changes are saved here; sync will retry."
        case .accountUnavailable: return "Sign in to iCloud in Settings to sync Nova Music. Your library remains on this device."
        case .accountChanged: return "Your iCloud account changed. Enable iCloud again to choose whether to add this device’s library."
        }
    }
}

@MainActor
final class NovaCloudKitStorage: NovaCloudStorage {
    static let containerIdentifier = "iCloud.com.example.NovaMusic"
    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private var retryAfter = Date.distantPast
    private var boundAccount: String?

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw NovaCloudFailure.accountUnavailable }
        let name = try await container.userRecordID().recordName
        // A stable opaque identity, shared by native and CloudKit JS clients.
        let hex = SHA256.hash(data: Data(name.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        boundAccount = id
        return id
    }
    private func checkAccount() async throws {
        guard Date() >= retryAfter else { throw NovaSyncFailure.message("iCloud asked Nova to wait before retrying. Your changes are saved here.") }
        let expected = boundAccount
        let actual = try await accountID()
        guard expected == actual else { boundAccount = expected; throw NovaCloudFailure.accountChanged }
    }
    private func record(_ name: String) async throws -> CKRecord? {
        do { return try await database.record(for: CKRecord.ID(recordName: name)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }
    func load(_ name: String) async throws -> NovaCloudSnapshot {
        do {
            try await checkAccount()
            guard let record = try await record(name) else { return NovaCloudSnapshot(document: NovaSyncDocument(), revision: nil) }
            guard let asset = record["document"] as? CKAsset, let url = asset.fileURL else { throw NovaSyncFailure.invalidDocument }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 10_000_000 else { throw NovaSyncFailure.invalidDocument }
            let document = try JSONDecoder().decode(NovaSyncDocument.self, from: Data(contentsOf: url))
            try document.validate()
            return NovaCloudSnapshot(document: document, revision: record.recordChangeTag)
        } catch { throw mapped(error) }
    }
    func save(_ document: NovaSyncDocument, named name: String, revision: String?) async throws {
        try document.validate()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await checkAccount()
            let record = try await record(name) ?? CKRecord(recordType: "NovaDocument", recordID: CKRecord.ID(recordName: name))
            guard record.recordChangeTag == revision else { throw NovaCloudFailure.conflict }
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
            record["document"] = CKAsset(fileURL: file)
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            guard let saved = result.saveResults[record.recordID] else { throw NovaSyncFailure.invalidResponse }
            _ = try saved.get()
        } catch { throw mapped(error) }
    }
    private func mapped(_ error: Error) -> Error {
        guard let cloud = error as? CKError else { return error }
        if let delay = cloud.retryAfterSeconds { retryAfter = Date().addingTimeInterval(delay) }
        if cloud.code == .serverRecordChanged { return NovaCloudFailure.conflict }
        if cloud.code == .notAuthenticated { return NovaCloudFailure.accountUnavailable }
        return error
    }
}

extension NovaSyncDocument {
    func cloudPartition(connection: Bool) -> Self {
        var result = self
        result.records = records.filter { $0.key.hasPrefix("connect:") == connection }
        return result
    }
}
