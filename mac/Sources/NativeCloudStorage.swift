import Foundation
import CloudKit
import CryptoKit

/// Only fixed private records are exposed to the trusted Nova main frame.
@MainActor
final class NativeCloudStorage {
    private lazy var container = CKContainer(identifier: "iCloud.com.example.NovaMusic")
    private var database: CKDatabase { container.privateCloudDatabase }
    private var boundIdentity: String?
    private var retryAfter = Date.distantPast
    private func identity() async throws -> String {
        guard try await container.accountStatus() == .available else { throw Failure("Sign in to iCloud in System Settings. Your library stays here.") }
        let name = try await container.userRecordID().recordName
        let hex = SHA256.hash(data: Data(name.utf8)).prefix(16).map { String(format:"%02x",$0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
    private func record(_ name: String) async throws -> CKRecord? {
        do { return try await database.record(for: CKRecord.ID(recordName:name)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }
    func request(_ input: [String: Any]) async -> [String: Any] {
        let id = input["id"] as? String ?? ""
        do {
            guard Date() >= retryAfter else { throw Failure("iCloud asked Nova to wait before retrying. Your changes are saved here.") }
            let current = try await identity()
            if input["action"] as? String == "account" { boundIdentity = current; return ["id":id,"result":current] }
            guard current == boundIdentity else { throw Failure("Your Apple Account changed. Enable iCloud again.") }
            guard let name = input["name"] as? String, name == "nova-library" else { throw Failure("Unsupported iCloud record.") }
            let existing = try await record(name)
            switch input["action"] as? String {
            case "load":
                guard let existing else { return ["id":id,"result":["document":["version":1,"records":[:]],"revision":NSNull()]] }
                var document: Any = ["version":1,"records":[:]] as [String:Any]
                if let asset = existing["document"] as? CKAsset, let file = asset.fileURL {
                    guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 10_000_000 else { throw Failure("Invalid iCloud document.") }
                    document = try JSONSerialization.jsonObject(with:Data(contentsOf:file))
                } else if existing["webParts"] == nil { throw Failure("Invalid iCloud document.") }
                var result: [String:Any] = ["document":document,"revision":existing.recordChangeTag as Any]
                if let data = try await MacWebLibraryParts.data(existing, database:database) {
                    result["webDocument"] = try JSONSerialization.jsonObject(with:data)
                }
                return ["id":id,"result":result]
            case "save":
                let revision = input["revision"] as? String
                guard existing?.recordChangeTag == revision else { return ["id":id,"error":"Another device updated iCloud. Retry syncing.","conflict":true] }
                guard let document = input["document"] as? [String:Any], document["version"] as? Int == 1, let records = document["records"] as? [String:Any], records.count <= 30000 else { throw Failure("Invalid iCloud document.") }
                let data = try JSONSerialization.data(withJSONObject:document)
                guard data.count <= 10_000_000 else { throw Failure("The library is too large to sync.") }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:file) }
                try data.write(to:file,options:.atomic)
                let record = existing ?? CKRecord(recordType:"NovaDocument",recordID:CKRecord.ID(recordName:name))
                record["document"] = CKAsset(fileURL:file)
                let result = try await database.modifyRecords(saving:[record],deleting:[],savePolicy:.ifServerRecordUnchanged,atomically:false)
                guard let saved = result.saveResults[record.recordID] else { throw Failure("iCloud did not confirm this save.") }
                _ = try saved.get(); return ["id":id,"result":true]
            default: throw Failure("Unsupported iCloud action.")
            }
        } catch {
            if let cloud = error as? CKError, let delay = cloud.retryAfterSeconds { retryAfter = Date().addingTimeInterval(delay) }
            return ["id":id,"error":error.localizedDescription,"conflict":(error as? CKError)?.code == .serverRecordChanged]
        }
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// Browser writes use ordinary private records because the asset upload service
// does not allow browser origins. Validate all parts before exposing any data.
enum MacWebLibraryParts {
    static func data(_ record: CKRecord, database: CKDatabase) async throws -> Data? {
        guard let names = record["webParts"] as? [String] else { return nil }
        guard !names.isEmpty, names.count <= 128,
              names.allSatisfy({ $0.range(of: "^nova-library-web-[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw NSError(domain: "NovaCloudParts", code: 1) }
        var result = Data()
        for start in stride(from: 0, to: names.count, by: 4) {
            let batch = Array(names[start..<min(start + 4, names.count)])
            let records = try await database.records(for: batch.map { CKRecord.ID(recordName: $0) })
            for name in batch {
                guard let entry = records[CKRecord.ID(recordName: name)],
                      let text = try entry.get()["webText"] as? String, text.utf16.count <= 100000 else { throw NSError(domain: "NovaCloudParts", code: 2) }
                let data = Data(text.utf8)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard name == "nova-library-web-" + hash, result.count + data.count <= 10_000_000 else { throw NSError(domain: "NovaCloudParts", code: 3) }
                result.append(data)
            }
        }
        return result
    }
}
