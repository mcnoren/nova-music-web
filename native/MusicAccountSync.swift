import Foundation
import SwiftUI
import Combine
import Security
import UIKit

@MainActor
final class MusicAccountSync: ObservableObject {
    struct User: Codable { var id: UUID; var email: String }
    struct Session: Codable {
        var access_token: String
        var refresh_token: String
        var expires_at: Double?
        var expires_in: Double?
        var user: User
    }
    @Published private(set) var user: User?
    @Published private(set) var status = "Not signed in"
    @Published private(set) var error: String?
    @Published private(set) var lastSynced: Date?
    private weak var store: YouTubeStore?
    private var session: Session?
    private var document = NovaSyncDocument()
    private var previous: [String:NovaSyncValue] = [:]
    private var applying = false, started = false
    private var generation = UUID()
    private var task: Task<Void,Never>?, poll: Task<Void,Never>?, syncTask: Task<Void,Never>?
    private var subscriptions = Set<AnyCancellable>()
    private let actor: UUID
    private let url: URL?
    private let key: String
    private let service = (Bundle.main.bundleIdentifier ?? "NovaMusic") + ".account-sync"
    var configured: Bool {
        guard url != nil, !key.isEmpty, !key.contains("$(") else { return false }
        if key.hasPrefix("sb_publishable_") { return true }
        let parts = key.split(separator:".")
        guard parts.count == 3 else { return false }
        var encoded = String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        encoded += String(repeating:"=",count:(4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded:encoded), let value = try? JSONDecoder().decode(NovaSyncValue.self,from:data) else { return false }
        return value["role"]?.string == "anon"
    }

    init(store: YouTubeStore) {
        self.store = store
        let raw = Bundle.main.object(forInfoDictionaryKey:"NovaSyncURL") as? String ?? ""
        let candidate = URL(string:raw)
        url = candidate?.scheme == "https" && candidate?.user == nil && candidate?.password == nil ? candidate : nil
        key = Bundle.main.object(forInfoDictionaryKey:"NovaSyncPublishableKey") as? String ?? ""
        actor = store.defaults.string(forKey:"music.sync.device").flatMap(UUID.init(uuidString:)) ?? UUID()
        store.defaults.set(actor.uuidString,forKey:"music.sync.device")
        store.objectWillChange.debounce(for:.milliseconds(700),scheduler:RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }.store(in:&subscriptions)
        NotificationCenter.default.publisher(for:UserDefaults.didChangeNotification).debounce(for:.milliseconds(700),scheduler:RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }.store(in:&subscriptions)
        NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }.store(in:&subscriptions)
    }
    func bootstrap() async {
        guard !started else { return }; started = true
        guard configured else { return }
        if let data = keychainRead(), let session = try? JSONDecoder().decode(Session.self,from:data) {
            do { try await activate(session,mergeGuest:false) }
            catch { self.error = error.localizedDescription; status = "Sync needs attention" }
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30))
                guard !Task.isCancelled else { return }; await self?.sync()
            }
        }
    }
    func sendCode(email: String) async throws {
        guard configured else { throw NovaSyncFailure.notConfigured }
        guard email.range(of:"^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$",options:.regularExpression) != nil else { throw NovaSyncFailure.message("Enter a valid email address.") }
        _ = try await request("/auth/v1/otp",method:"POST",body:["email":.string(email),"create_user":.bool(true)])
    }
    func verifyCode(email: String, code: String, mergeGuest: Bool) async throws {
        guard code.range(of:"^[0-9]{6,10}$",options:.regularExpression) != nil else { throw NovaSyncFailure.message("Enter the code from your email.") }
        let existingID = user?.id
        if existingID != nil { captureChanges(schedule:false) }
        let response = try await request("/auth/v1/verify",method:"POST",body:["email":.string(email),"token":.string(code),"type":.string("email")])
        let session = try response.decoded(Session.self)
        guard !session.access_token.isEmpty, !session.refresh_token.isEmpty else { throw NovaSyncFailure.invalidResponse }
        if let existingID, existingID != session.user.id { throw NovaSyncFailure.message("Sign in with the current account to preserve your pending changes.") }
        try await activate(session,mergeGuest:existingID == nil && mergeGuest)
    }
    private func activate(_ session: Session, mergeGuest: Bool) async throws {
        guard let store else { return }
        let guest = mergeGuest ? try MusicAccountLibrary.values(store) : nil
        if user == nil, self.session == nil, keychainRead() == nil {
            let values = try MusicAccountLibrary.values(store)
            store.defaults.set(try JSONEncoder().encode(values),forKey:"music.sync.guest")
        }
        generation = UUID(); self.session = session; user = session.user
        if self.session?.expires_at == nil { self.session?.expires_at = Date().timeIntervalSince1970 + (session.expires_in ?? 3600) }
        try saveSession()
        if let data = store.defaults.data(forKey:cacheKey), let stored = try? JSONDecoder().decode(NovaSyncDocument.self,from:data) { try stored.validate(); document = stored }
        else { document = NovaSyncDocument() }
        if let guest { var values = document.values; values.merge(guest,uniquingKeysWith:{ _,new in new }); document = try document.updating(previous:document.values,next:values,actor:actor) }
        try applyCurrent(); status = "Syncing"
        await sync()
    }
    private var cacheKey: String { "music.sync.document." + (user?.id.uuidString.lowercased() ?? "guest") }
    private func saveDocument() throws { guard let store else { return }; store.defaults.set(try JSONEncoder().encode(document),forKey:cacheKey) }
    private func changed() { captureChanges(schedule: true) }
    private func captureChanges(schedule: Bool) {
        guard user != nil, !applying, let store else { return }
        do {
            let next = try MusicAccountLibrary.values(store,preserving:document.values)
            guard next != previous else { return }
            document = try document.updating(previous:previous,next:next,actor:actor); previous = next; try saveDocument()
            status = "Changes saved on this device"; error = nil
            if schedule { task?.cancel(); task = Task { [weak self] in try? await Task.sleep(for:.milliseconds(700)); if !Task.isCancelled { await self?.sync() } } }
        } catch { self.error = error.localizedDescription; status = "Sync needs attention" }
    }
    func sync() async {
        if let running = syncTask { await running.value; return }
        guard user != nil, configured else { return }
        let running = Task { await runSync() }; syncTask = running
        await running.value; syncTask = nil
    }
    private func runSync() async {
        guard let user else { return }
        captureChanges(schedule: false)
        let epoch = generation, id = user.id
        status = "Syncing"; error = nil
        do {
            for _ in 0..<5 {
                let response = try await request("/rest/v1/nova_music_libraries?select=document,revision&user_id=eq.\(id.uuidString.lowercased())",authenticated:true)
                try assertCurrent(epoch,id)
                captureChanges(schedule: false)
                guard let rows = response.array, rows.count <= 1 else { throw NovaSyncFailure.invalidResponse }
                let remote = try rows.first?["document"]?.decoded(NovaSyncDocument.self) ?? NovaSyncDocument()
                let revision = rows.first?["revision"]?.number ?? 0
                let candidate = try document.merging(remote)
                if candidate == remote { document = candidate; try applyCurrent(); status = "Synced"; lastSynced = Date(); return }
                let result = try await request("/rest/v1/rpc/save_nova_music_library",method:"POST",body:["expected_revision":.number(revision),"library_document":try .encoded(candidate)],authenticated:true)
                try assertCurrent(epoch,id)
                captureChanges(schedule: false)
                if result["conflict"] == .bool(true) { continue }
                guard let savedRevision = result["revision"]?.number, savedRevision > revision else { throw NovaSyncFailure.invalidResponse }
                document = try candidate.merging(document); try applyCurrent()
                if document != candidate { continue }
                status = "Synced"; lastSynced = Date(); return
            }
            throw NovaSyncFailure.message("Another device is updating the library. Your edits are saved here; sync will retry.")
        } catch {
            if generation == epoch { self.error = error.localizedDescription; status = "Changes saved on this device" }
        }
    }
    private func applyCurrent() throws {
        guard let store else { return }
        applying = true; defer { applying = false }
        try MusicAccountLibrary.apply(document.values,to:store)
        previous = try MusicAccountLibrary.values(store,preserving:document.values); try saveDocument()
    }
    func signOut() async throws {
        changed(); await sync()
        guard error == nil, status == "Synced" else { throw NovaSyncFailure.unsyncedChanges }
        guard let store, let oldSession = session else { return }
        let guest = store.defaults.data(forKey:"music.sync.guest").flatMap { try? JSONDecoder().decode([String:NovaSyncValue].self,from:$0) } ?? [:]
        generation = UUID(); task?.cancel(); store.defaults.removeObject(forKey:cacheKey)
        applying = true; defer { applying = false }
        try MusicAccountLibrary.apply(guest,to:store)
        keychainDelete(); session = nil; user = nil; document = NovaSyncDocument(); previous = [:]
        status = "Not signed in"; error = nil; lastSynced = nil
        _ = try? await request("/auth/v1/logout?scope=local",method:"POST",token:oldSession.access_token)
    }
    private func assertCurrent(_ epoch: UUID,_ id: UUID) throws { if epoch != generation || id != user?.id { throw NovaSyncFailure.accountChanged } }
    private func accessToken() async throws -> String {
        guard let current = session else { throw NovaSyncFailure.message("Sign in to sync your library.") }
        if (current.expires_at ?? 0) > Date().timeIntervalSince1970 + 60 { return current.access_token }
        let epoch = generation
        let response = try await request("/auth/v1/token?grant_type=refresh_token",method:"POST",body:["refresh_token":.string(current.refresh_token)])
        var refreshed = try response.decoded(Session.self); try assertCurrent(epoch,refreshed.user.id)
        refreshed.expires_at = refreshed.expires_at ?? Date().timeIntervalSince1970 + (refreshed.expires_in ?? 3600)
        session = refreshed; try saveSession(); return refreshed.access_token
    }
    private func request(_ path: String,method: String = "GET",body: [String:NovaSyncValue]? = nil,authenticated: Bool = false,token: String? = nil) async throws -> NovaSyncValue {
        guard configured, let url, let endpoint = URL(string:path,relativeTo:url) else { throw NovaSyncFailure.notConfigured }
        var request = URLRequest(url:endpoint); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue(key,forHTTPHeaderField:"apikey"); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let bearer = authenticated ? try await accessToken() : token
        if let bearer { request.setValue("Bearer \(bearer)",forHTTPHeaderField:"Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse, http.url?.host == url.host else { throw NovaSyncFailure.invalidResponse }
        let value = (try? JSONDecoder().decode(NovaSyncValue.self,from:data)) ?? .object([:])
        guard (200..<300).contains(http.statusCode) else { throw NovaSyncFailure.message(http.statusCode == 401 ? "Your session expired. Sign in again to sync." : value["msg"]?.string ?? value["message"]?.string ?? "Sync could not finish. Your library remains saved here.") }
        return value
    }
    private func keychainQuery() -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"nova-account"] }
    private func keychainRead() -> Data? {
        var query = keychainQuery(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess else { return nil }; return item as? Data
    }
    private func saveSession() throws {
        guard let session else { return }; let data = try JSONEncoder().encode(session)
        var query = keychainQuery(); query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary,nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(keychainQuery() as CFDictionary,[kSecValueData as String:data] as CFDictionary) == errSecSuccess else { throw NovaSyncFailure.message("Could not securely save your sign-in. Try again.") }
        } else if status != errSecSuccess { throw NovaSyncFailure.message("Could not securely save your sign-in. Try again.") }
    }
    private func keychainDelete() { SecItemDelete(keychainQuery() as CFDictionary) }
}

struct MusicAccountSyncSection: View {
    @ObservedObject var account: MusicAccountSync
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var reauth = false
    @State private var working = false
    @State private var addLibrary = true
    @State private var message: String?
    var body: some View {
        Section("Nova Music account") {
            if let user = account.user, !reauth {
                Text(user.email); LabeledContent("Library sync",value:account.status)
                if let date = account.lastSynced { Text("Last synced \(date.formatted(date:.omitted,time:.shortened))").font(.footnote).foregroundStyle(.secondary) }
                Button("Sync now") { Task { await account.sync() } }.disabled(working)
                Button("Sign in again") { email = user.email; sent = false; reauth = true }.disabled(working)
                Button("Sign out") { perform { try await account.signOut() } }.disabled(working)
            } else if !account.configured {
                Text("Account sync is not available yet.")
                Text("Your library stays on this device until account sync is activated.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Sign in with the same email in the app and browser to share your library.").font(.footnote).foregroundStyle(.secondary)
                TextField("Email address",text:$email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(sent || working || reauth)
                if sent {
                    TextField("Code from your email",text:$code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    if !reauth { Toggle("Add this device’s library to my account",isOn:$addLibrary) }
                    Button("Sign in") { perform { try await account.verifyCode(email:email.trimmingCharacters(in:.whitespaces),code:code.trimmingCharacters(in:.whitespaces),mergeGuest:!reauth && addLibrary); reauth = false; sent = false; code = "" } }.disabled(working)
                    Button(reauth ? "Cancel" : "Use another email") { sent = false; reauth = false; code = "" }.disabled(working)
                } else { Button("Email me a sign-in code") { perform { try await account.sendCode(email:email.trimmingCharacters(in:.whitespaces)); sent = true } }.disabled(working) }
            }
            if working { ProgressView() }
            if let error = message ?? account.error { Text(error).font(.footnote).foregroundStyle(.red) }
            Text("Sync includes library metadata. Imported audio, photos and playback settings remain on their original device.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true; message = nil
        Task { do { try await operation() } catch { message = error.localizedDescription }; working = false }
    }
}
