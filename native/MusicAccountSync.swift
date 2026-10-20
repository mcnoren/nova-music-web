import AVFoundation
import Foundation
import SwiftUI
import Combine
import Security
import UIKit
import PhotosUI
import CryptoKit
import CloudKit

@MainActor
struct MusicAccountCredentialStorage {
    var read: () -> Data?
    var save: (Data) throws -> Void
    var delete: () -> Void
}

@MainActor
final class MusicAccountSync: ObservableObject {
    // Legacy providers remain available for migration and regression tests.
    enum Backend { case icloud, github, supabase }
    let backend: Backend
    var usesGitHub: Bool { backend == .github }
    var usesICloud: Bool { backend == .icloud }
    private let localPlayback: MusicLocalPlaybackTransport
    private var localPeers = Set<String>()
    private var localKey: Data?
    private let cloud: NovaCloudStorage
    private var playbackPublishTask: Task<Void, Never>?
    private var playbackActivityAt: Double?
    @Published private(set) var lyricsDisplayMessage: String?
    private var displayRequest: (target: String, id: String, at: Double)?
    private var cloudRetryAfter = Date.distantPast
    struct User: Codable { var id: UUID; var email: String }
    struct Session: Codable {
        var access_token: String
        var refresh_token: String
        var expires_at: Double?
        var expires_in: Double?
        var user: User
        var repository: String? = nil
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
    private var bootstrapTask: Task<Void, Never>?
    private var generation = UUID()
    private var task: Task<Void,Never>?, poll: Task<Void,Never>?, syncTask: Task<Void,Never>?
    private var subscriptions = Set<AnyCancellable>()
    @Published private(set) var outputDevices: [MusicConnectedDevice] = []
    @Published private(set) var outputName = "This device"
    @Published private(set) var outputID: String?
    @Published private(set) var outputError: String?
    @Published private(set) var pendingOutputID: String?
    private var outputIntent: (id:String,command:String,playing:Bool)?
    private var outputTimeout: Task<Void,Never>?
    private var connectTask: Task<Void,Never>?, commandTask: Task<Void,Never>?
    private var mirrorClockTask: Task<Void,Never>?
    private var freezeTask: Task<Void,Never>?
    private var playbackIntent: (id: UUID, playing: Bool, command: String?)?
    private var intentTimeout: Task<Void,Never>?
    private var preparingCommand: String?, acknowledgedHandoff: String?
    private var appliedCommand: String?, lastPresence = Date.distantPast, lastStatus = Date.distantPast
    private var applyingPlayback = false, remoteMirroring = false, wasOutput = false
    // A selection made in the car stays on this phone, including after unplugging.
    // Only an explicit output selection can send it back to another device.
    private(set) var carPlayOwnsOutput = false
    private var appliedLibrary: [String:NovaSyncValue]?
    private var connectionNeedsSync = true
    private var serverRevision: Double?
    private let actor: UUID
    private let url: URL?
    private let key: String
    private let service: String
    private var githubRetryAfter = Date.distantPast
    private let network: URLSession
    private let credentialStorage: MusicAccountCredentialStorage?
    var configured: Bool {
        if usesGitHub || usesICloud { return true }
        guard url != nil, !key.isEmpty, !key.contains("$(") else { return false }
        if key.hasPrefix("sb_publishable_") { return true }
        let parts = key.split(separator:".")
        guard parts.count == 3 else { return false }
        var encoded = String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        encoded += String(repeating:"=",count:(4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded:encoded), let value = try? JSONDecoder().decode(NovaSyncValue.self,from:data) else { return false }
        return value["role"]?.string == "anon"
    }

    init(store: YouTubeStore, network: URLSession = .shared, credentialService: String? = nil, credentialStorage: MusicAccountCredentialStorage? = nil, backend: Backend = .icloud, cloud: NovaCloudStorage? = nil, localPlayback: MusicLocalPlaybackTransport? = nil) {
        self.localPlayback = localPlayback ?? MusicLocalPlayback()
        self.cloud = cloud ?? NovaCloudKitStorage()
        self.backend = backend
        self.store = store
        self.network = network
        self.credentialStorage = credentialStorage
        service = credentialService ?? (Bundle.main.bundleIdentifier ?? "NovaMusic") + (backend == .github ? ".github-library-sync" : ".account-sync")
        let raw = Bundle.main.object(forInfoDictionaryKey:"NovaSyncURL") as? String ?? ""
        let candidate = URL(string:raw)
        url = candidate?.scheme == "https" && candidate?.user == nil && candidate?.password == nil ? candidate : nil
        key = Bundle.main.object(forInfoDictionaryKey:"NovaSyncPublishableKey") as? String ?? ""
        actor = store.defaults.string(forKey:"music.sync.device").flatMap(UUID.init(uuidString:)) ?? UUID()
        store.defaults.set(actor.uuidString,forKey:"music.sync.device")
        self.localPlayback.onReceive = { [weak self] data in
            guard let self, self.usesICloud, let incoming = try? JSONDecoder().decode(NovaSyncDocument.self, from: data),
                  incoming.records.keys.allSatisfy({ $0.hasPrefix("connect:") }),
                  let merged = try? self.document.merging(incoming) else { return }
            if merged != self.document {
                self.document = merged; self.receiveConnection(); try? self.saveDocument()
                self.publishLocalConnection()
            }
        }
        self.localPlayback.onPeersChanged = { [weak self] peers in self?.localPeers = peers; self?.receiveConnection() }
        self.localPlayback.onError = { [weak self] message in self?.outputError = message }
        store.player.connectedPlaybackChanged = { [weak self] in self?.schedulePlaybackPublication() }
        store.player.connectedCommand = { [weak self] action in self?.routeControl(action) ?? false }
        Publishers.MergeMany(store.player.$loading.map { _ in () }.eraseToAnyPublisher(),store.player.$ready.map { _ in () }.eraseToAnyPublisher(),store.player.$playing.map { _ in () }.eraseToAnyPublisher(),store.player.$currentVideoID.map { _ in () }.eraseToAnyPublisher(),store.player.$trackLyrics.map { _ in () }.eraseToAnyPublisher(),store.player.$lyricCalibration.map { _ in () }.eraseToAnyPublisher(),store.player.$playlistIDs.map { _ in () }.eraseToAnyPublisher(),store.player.$playlistIndex.map { _ in () }.eraseToAnyPublisher(),store.player.$shuffled.map { _ in () }.eraseToAnyPublisher(),store.player.$repeatMode.map { _ in () }.eraseToAnyPublisher())
            .sink { [weak self] _ in self?.lastStatus = .distantPast; self?.schedulePlaybackPublication() }.store(in:&subscriptions)
        store.objectWillChange.debounce(for:.milliseconds(700),scheduler:RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }.store(in:&subscriptions)
        NotificationCenter.default.publisher(for:UserDefaults.didChangeNotification).debounce(for:.milliseconds(700),scheduler:RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }.store(in:&subscriptions)
        NotificationCenter.default.publisher(for: .CKAccountChanged).sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.usesICloud else { return }
                self.disableICloud()
                self.error = NovaCloudFailure.accountChanged.localizedDescription
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }.store(in:&subscriptions)
    }
    func bootstrap() async {
        if let bootstrapTask { await bootstrapTask.value; return }
        let task = Task { await self.startAccount() }
        bootstrapTask = task
        await task.value
    }
    private func startAccount() async {
        guard !started else { return }; started = true
        guard configured else { return }
        if usesICloud {
            if store?.defaults.object(forKey: "music.icloud.enabled") as? Bool != false {
                if restoreCachedLocalPlayback() {
                    Task { [weak self] in await self?.sync() }
                } else { do { try await enableICloud(mergeLibrary: true, automatic: true) }
                catch { self.error = error.localizedDescription; status = "Saved on this device" } }
            }
        } else if let data = keychainRead(), let session = try? JSONDecoder().decode(Session.self,from:data), !usesGitHub || session.repository != nil {
            do { try await activate(session,mergeGuest:false) }
            catch { self.error = error.localizedDescription; status = "Sync needs attention" }
        }
        if !usesGitHub { connectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.connectTick()
                try? await Task.sleep(for:.milliseconds(self?.usesICloud == true ? 1500 : self?.connectedSnapshot?.playing == true || self?.pendingOutputID != nil || self?.playbackIntent != nil || (self?.outputDevices.count ?? 0)>1 ? 750 : 2000))
            }
        }
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(self?.usesGitHub == true ? 300 : 30))
                guard !Task.isCancelled else { return }; await self?.sync()
            }
        }
    }
    /// Playback routing is asynchronous even when this phone is the output.
    /// Siri must wait for the queued command before checking the audio item.
    func waitForPendingPlayback() async throws {
        guard !usesGitHub else { return }
        await commandTask?.value
        try Task.checkCancellation()
        if let outputError { throw NovaSyncFailure.message(outputError) }
    }
    private func validateEmail(_ email: String) throws {
        guard configured else { throw NovaSyncFailure.notConfigured }
        guard email.range(of:"^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$",options:.regularExpression) != nil else { throw NovaSyncFailure.message("Enter a valid email address.") }
    }
    func signIn(email: String, password: String, mergeGuest: Bool) async throws {
        if usesGitHub { try await connectGitHub(repository: email, token: password, mergeLibrary: mergeGuest); return }
        try validateEmail(email)
        guard !password.isEmpty else { throw NovaSyncFailure.message("Enter your password.") }
        let existingID = user?.id
        if existingID != nil { captureChanges(schedule:false) }
        let response = try await request("/auth/v1/token?grant_type=password",method:"POST",body:["email":.string(email),"password":.string(password)])
        let session = try response.decoded(Session.self)
        guard !session.access_token.isEmpty, !session.refresh_token.isEmpty else { throw NovaSyncFailure.invalidResponse }
        if let existingID, existingID != session.user.id { throw NovaSyncFailure.message("Sign in with the current account to preserve your pending changes.") }
        try await activate(session,mergeGuest:existingID == nil && mergeGuest)
    }
    func createAccount(email: String, password: String) async throws {
        try validateEmail(email)
        guard password.count >= 12 else { throw NovaSyncFailure.message("Choose a password with at least 12 characters.") }
        let response = try await request("/auth/v1/signup",method:"POST",body:["email":.string(email),"password":.string(password)])
        if let token = response["access_token"]?.string { _ = try? await request("/auth/v1/logout?scope=local",method:"POST",token:token) }
    }
    func sendPasswordReset(email: String) async throws {
        try validateEmail(email)
        _ = try await request("/auth/v1/recover",method:"POST",body:["email":.string(email)])
    }
    private func activate(_ session: Session, mergeGuest: Bool) async throws {
        guard let store else { return }
        let guest = mergeGuest ? try MusicAccountLibrary.values(store) : nil
        if user == nil, self.session == nil, keychainRead() == nil {
            let values = try MusicAccountLibrary.values(store)
            store.defaults.set(try JSONEncoder().encode(values),forKey:"music.sync.guest")
        }
        resetConnection(); appliedLibrary = nil
        generation = UUID(); self.session = session; user = session.user
        if !usesGitHub, self.session?.expires_at == nil { self.session?.expires_at = Date().timeIntervalSince1970 + (session.expires_in ?? 3600) }
        try saveSession()
        if let data = store.defaults.data(forKey:cacheKey), let stored = try? JSONDecoder().decode(NovaSyncDocument.self,from:data) { try stored.validate(); document = stored }
        else { document = NovaSyncDocument() }
        if usesGitHub { document = Self.libraryOnly(document) }
        if let guest { var values = document.values; values.merge(guest,uniquingKeysWith:{ _,new in new }); document = try document.updating(previous:document.values,next:values,actor:actor) }
        try applyCurrent(); status = "Syncing"
        await sync()
    }
    private var cacheKey: String { (usesICloud ? "music.icloud.document." : usesGitHub ? "music.github.document." : "music.sync.document.") + (user?.id.uuidString.lowercased() ?? "guest") }
    private func saveDocument() throws { guard let store else { return }; store.defaults.set(try JSONEncoder().encode(document),forKey:cacheKey) }
    func changed() { captureChanges(schedule: true) }
    private func captureChanges(schedule: Bool) {
        guard user != nil, !applying, let store else { return }
        do {
            let next = try MusicAccountLibrary.values(store,preserving:document.values)
            guard next != previous else { return }
            document = try document.updating(previous:previous,next:next,actor:actor); previous = next; connectionNeedsSync = true; try saveDocument()
            status = "Changes saved on this device"; error = nil
            if schedule { task?.cancel(); task = Task { [weak self] in try? await Task.sleep(for:.milliseconds(self?.usesGitHub == true ? 5000 : 700)); if !Task.isCancelled { await self?.sync() } } }
        } catch { self.error = error.localizedDescription; status = "Sync needs attention" }
    }
    func sync() async {
        if let running = syncTask { await running.value; return }
        guard user != nil, configured else { return }
        let running = Task { await runSync() }; syncTask = running
        await running.value; syncTask = nil
    }
    private func runSync() async {
        if usesICloud { await runICloudSync(); return }
        if usesGitHub { await runGitHubSync(); return }
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
                if candidate == remote { document = candidate; connectionNeedsSync = false; serverRevision = revision; try applyCurrent(); status = "Synced"; lastSynced = Date(); return }
                let result = try await request("/rest/v1/rpc/save_nova_music_library",method:"POST",body:["expected_revision":.number(revision),"library_document":try .encoded(candidate)],authenticated:true)
                try assertCurrent(epoch,id)
                captureChanges(schedule: false)
                if result["conflict"] == .bool(true) { continue }
                guard let savedRevision = result["revision"]?.number, savedRevision > revision else { throw NovaSyncFailure.invalidResponse }
                document = try candidate.merging(document); connectionNeedsSync = document != candidate; serverRevision = savedRevision; try applyCurrent()
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
        let library = document.values.filter { !$0.key.hasPrefix("connect:") }
        if library != appliedLibrary { try MusicAccountLibrary.apply(document.values,to:store); appliedLibrary = library }
        configureLocalPlayback()
        receiveConnection()
        previous = try MusicAccountLibrary.values(store,preserving:document.values); try saveDocument()
    }
    func signOut() async throws {
        if usesICloud { disableICloud(); return }
        if usesGitHub { disconnectGitHub(); return }
        changed(); await sync()
        guard error == nil, status == "Synced" else { throw NovaSyncFailure.unsyncedChanges }
        guard let store, let oldSession = session else { return }
        let guest = store.defaults.data(forKey:"music.sync.guest").flatMap { try? JSONDecoder().decode([String:NovaSyncValue].self,from:$0) } ?? [:]
        resetConnection(); appliedLibrary = nil
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
        guard backend == .supabase, configured, let url, let endpoint = URL(string:path,relativeTo:url) else { throw NovaSyncFailure.notConfigured }
        var request = URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue(key,forHTTPHeaderField:"apikey"); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let bearer = authenticated ? try await accessToken() : token
        if let bearer { request.setValue("Bearer \(bearer)",forHTTPHeaderField:"Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data,response) = try await network.data(for:request)
        guard let http = response as? HTTPURLResponse, http.url?.host == url.host else { throw NovaSyncFailure.invalidResponse }
        let value = (try? JSONDecoder().decode(NovaSyncValue.self,from:data)) ?? .object([:])
        guard (200..<300).contains(http.statusCode) else { throw NovaSyncFailure.message(http.statusCode == 401 && authenticated ? "Your session expired. Sign in again to sync." : value["msg"]?.string ?? value["message"]?.string ?? value["error_description"]?.string ?? "Sync could not finish. Your library remains saved here.") }
        return value
    }
    private func restoreCachedLocalPlayback() -> Bool {
        guard let store, let identity = store.defaults.string(forKey: "music.icloud.identity"), let id = UUID(uuidString: identity),
              let data = store.defaults.data(forKey: "music.icloud.document." + identity.lowercased()),
              let saved = try? JSONDecoder().decode(NovaSyncDocument.self, from: data),
              let encoded = saved.values["deviceTrust:localPlayback"]?.string,
              Data(base64Encoded: encoded)?.count == 32 else { return false }
        do {
            try saved.validate(); user = User(id: id, email: "iCloud")
            document = saved.cloudPartition(connection: false); previous = document.values
            try applyCurrent(); status = "Saved on this device"; return true
        } catch { user = nil; document = NovaSyncDocument(); return false }
    }
    func enableICloud(mergeLibrary: Bool = true, automatic: Bool = false) async throws {
        guard usesICloud, let store else { return }
        let identity = try await cloud.accountID()
        guard let id = UUID(uuidString: identity) else { throw NovaSyncFailure.invalidResponse }
        let oldIdentity = store.defaults.string(forKey: "music.icloud.identity")
        if automatic, let oldIdentity, oldIdentity != identity { throw NovaCloudFailure.accountChanged }
        if user != nil, user?.id != id { disableICloud() }
        generation = UUID(); resetConnection(); appliedLibrary = nil
        user = User(id: id, email: "iCloud")
        // Keep each account's cached edits separate; never carry device commands across launches/accounts.
        let saved = store.defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(NovaSyncDocument.self, from: $0) }
        document = saved?.cloudPartition(connection: false) ?? NovaSyncDocument()
        try document.validate()
        if mergeLibrary {
            var values = document.values
            values.merge(try MusicAccountLibrary.values(store), uniquingKeysWith: { _, local in local })
            document = try document.updating(previous: document.values, next: values, actor: actor)
        }
        previous = document.values
        store.defaults.set(identity, forKey: "music.icloud.identity")
        store.defaults.set(true, forKey: "music.icloud.enabled")
        try applyCurrent()
        await sync()
    }

    func disableICloud() {
        guard usesICloud else { return }
        captureChanges(schedule: false)
        generation = UUID(); task?.cancel()
        wasOutput = false // Disabling sync must not stop this device’s audio.
        resetConnection(); user = nil; session = nil; appliedLibrary = nil
        document = NovaSyncDocument(); previous = [:]
        store?.defaults.set(false, forKey: "music.icloud.enabled")
        status = "Saved on this device"; error = nil; lastSynced = nil
    }

    private func runICloudSync() async {
        guard let user, Date() >= cloudRetryAfter else { return }
        captureChanges(schedule: false)
        let epoch = generation, id = user.id
        status = "Syncing with iCloud"; error = nil
        do {
            guard try await cloud.accountID() == id.uuidString.lowercased() else { throw NovaCloudFailure.accountChanged }
            for _ in 0..<5 {
                let remote = try await cloud.load("nova-library")
                try assertCurrent(epoch, id); captureChanges(schedule: false)
                var candidate = try document.cloudPartition(connection: false).merging(remote.document.cloudPartition(connection: false))
                if candidate.values["deviceTrust:localPlayback"]?.string.flatMap({ Data(base64Encoded: $0) })?.count != 32 {
                    var values = candidate.values
                    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    values["deviceTrust:localPlayback"] = .string(secret.base64EncodedString())
                    candidate = try candidate.updating(previous: candidate.values, next: values, actor: actor)
                }
                if candidate != remote.document {
                    do { try await cloud.save(candidate, named: "nova-library", revision: remote.revision) }
                    catch NovaCloudFailure.conflict { continue }
                }
                try assertCurrent(epoch, id); captureChanges(schedule: false)
                document = try candidate.merging(document); try applyCurrent()
                if document.cloudPartition(connection: false) != candidate { continue }
                status = "Synced with iCloud"; lastSynced = Date(); return
            }
            throw NovaCloudFailure.conflict
        } catch {
            guard generation == epoch else { return }
            if case NovaCloudFailure.accountChanged = error { disableICloud() }
            self.error = error.localizedDescription; status = "Changes saved on this device"
            cloudRetryAfter = Date().addingTimeInterval(10)
        }
    }

    private func configureLocalPlayback() {
        guard usesICloud, user != nil,
              let encoded = document.values["deviceTrust:localPlayback"]?.string,
              let key = Data(base64Encoded: encoded), key.count == 32,
              let payload = try? JSONEncoder().encode(document.cloudPartition(connection: true)) else { return }
        localKey = key
        localPlayback.start(id: deviceID, key: key, payload: payload)
    }
    private func publishLocalConnection() {
        guard usesICloud, localKey != nil,
              let payload = try? JSONEncoder().encode(document.cloudPartition(connection: true)) else { return }
        localPlayback.publish(payload)
    }
    private func syncLocalConnection() async {
        guard user != nil else { return }
        configureLocalPlayback(); publishLocalConnection()
        await localPlayback.refresh()
    }
    private func syncPlayback() async {
        if usesICloud { await syncLocalConnection() } else { await sync() }
    }

    var gitHubRepository: String { session?.repository ?? "" }

    static func validGitHubRepository(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil,
              let name = value.split(separator: "/").last, name != ".", name != ".." else { return nil }
        return value
    }

    func connectGitHub(repository raw: String, token rawToken: String, mergeLibrary: Bool = true) async throws {
        guard usesGitHub, let repository = Self.validGitHubRepository(raw) else { throw NovaSyncFailure.message("Enter the private repository as owner/name.") }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count < 1000, !token.contains(where: \.isWhitespace) else { throw NovaSyncFailure.message("Enter a GitHub access token with Contents read and write access to this repository.") }
        let metadata = try await githubRequest("/repos/" + repository, token: token)
        try Self.verifyPrivateRepository(metadata)
        guard let repositoryID = metadata["id"]?.safeInt else { throw NovaSyncFailure.invalidResponse }
        let identity = Self.gitHubIdentity(repositoryID)
        guard user == nil || user?.id == identity else { throw NovaSyncFailure.message("Disconnect the current repository before choosing another. Your local library will stay on this device.") }
        let session = Session(access_token: token, refresh_token: "", user: User(id: identity, email: repository), repository: repository)
        try await activate(session, mergeGuest: user == nil && mergeLibrary)
    }

    static func gitHubIdentity(_ id: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("github-repo:\(id)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    static func verifyPrivateRepository(_ value: NovaSyncValue) throws {
        guard value["private"] == .bool(true), value["archived"] != .bool(true), value["disabled"] != .bool(true) else {
            throw NovaSyncFailure.message("Choose an active private GitHub repository. Nova never uploads your library to a public repository.")
        }
        if value["permissions"]?["push"] == .bool(false) { throw NovaSyncFailure.message("The GitHub token needs Contents read and write access to this repository.") }
    }

    static func libraryOnly(_ document: NovaSyncDocument) -> NovaSyncDocument {
        var result = document; result.records = result.records.filter { !$0.key.hasPrefix("connect:") }; return result
    }

    func disconnectGitHub() {
        guard usesGitHub else { return }
        captureChanges(schedule: false)
        generation = UUID(); task?.cancel(); task = nil
        keychainDelete(); session = nil; user = nil; appliedLibrary = nil
        document = NovaSyncDocument(); previous = [:]
        status = "Saved on this device"; error = nil; lastSynced = nil
        // Cached documents and the current library stay intact, including unsent edits.
    }

    private func runGitHubSync() async {
        guard let session, let repository = session.repository, let user else { return }
        captureChanges(schedule: false)
        let epoch = generation, id = user.id
        status = "Syncing with GitHub"; error = nil
        do {
            let metadata = try await githubRequest("/repos/" + repository)
            try assertCurrent(epoch, id); try Self.verifyPrivateRepository(metadata)
            guard metadata["id"]?.safeInt.map(Self.gitHubIdentity) == id else { throw NovaSyncFailure.accountChanged }
            for _ in 0..<3 {
                let path = "/repos/\(repository)/contents/nova-library.json"
                let file = try await githubRequest(path, allowMissing: true)
                try assertCurrent(epoch, id)
                let sha = file["sha"]?.string
                let remote: NovaSyncDocument
                if sha == nil {
                    guard file == .null else { throw NovaSyncFailure.invalidResponse }
                    remote = NovaSyncDocument()
                } else {
                    guard file["type"]?.string == "file" else { throw NovaSyncFailure.invalidResponse }
                    var encoded = file["content"]?.string
                    if file["encoding"]?.string == "none", let sha {
                        let blob = try await githubRequest("/repos/\(repository)/git/blobs/\(sha)")
                        try assertCurrent(epoch, id)
                        guard blob["encoding"]?.string == "base64", blob["sha"]?.string == sha else { throw NovaSyncFailure.invalidResponse }
                        encoded = blob["content"]?.string
                    } else if file["encoding"]?.string != "base64" { throw NovaSyncFailure.invalidResponse }
                    guard let encoded, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count <= 8_000_000 else { throw NovaSyncFailure.invalidDocument }
                    let decoded = try JSONDecoder().decode(NovaSyncDocument.self, from: data); try decoded.validate()
                    remote = Self.libraryOnly(decoded)
                }
                captureChanges(schedule: false)
                let candidate = try Self.libraryOnly(document).merging(remote)
                if candidate == remote {
                    document = candidate; try applyCurrent(); status = "Synced with GitHub"; lastSynced = Date(); return
                }
                let data = try JSONEncoder().encode(candidate)
                guard data.count <= 8_000_000 else { throw NovaSyncFailure.message("This library is too large to sync. Reduce custom artwork sizes; your edits remain saved here.") }
                // Check privacy again immediately before writing, including on conflict retries.
                try Self.verifyPrivateRepository(try await githubRequest("/repos/" + repository))
                try assertCurrent(epoch, id)
                var body: [String: NovaSyncValue] = ["message": .string("Sync Nova Music library"), "content": .string(data.base64EncodedString())]
                if let sha { body["sha"] = .string(sha) }
                let saved = try await githubRequest(path, method: "PUT", body: body, allowConflict: true)
                try assertCurrent(epoch, id)
                if saved == .null { continue }
                guard saved["content"]?["sha"]?.string != nil else { throw NovaSyncFailure.invalidResponse }
                captureChanges(schedule: false)
                document = try candidate.merging(Self.libraryOnly(document)); try applyCurrent()
                if document != candidate { continue }
                status = "Synced with GitHub"; lastSynced = Date(); return
            }
            throw NovaSyncFailure.message("Another device updated the library. Your edits are saved here; sync will retry.")
        } catch {
            guard generation == epoch else { return }
            self.error = error.localizedDescription; status = "Changes saved on this device"
        }
    }

    private func githubRequest(_ path: String, method: String = "GET", body: [String: NovaSyncValue]? = nil,
                               token: String? = nil, allowMissing: Bool = false, allowConflict: Bool = false) async throws -> NovaSyncValue {
        guard Date() >= githubRetryAfter else { throw NovaSyncFailure.message("GitHub asked Nova to wait before syncing again. Your library remains saved here.") }
        guard path.hasPrefix("/repos/"), !path.split(separator: "/").contains(".."), let url = URL(string: "https://api.github.com" + path),
              url.host == "api.github.com", let token = token ?? session?.access_token else { throw NovaSyncFailure.notConfigured }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(path.contains("/contents/") ? "application/vnd.github.object+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NovaMusic", forHTTPHeaderField: "User-Agent")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await network.data(for: request, delegate: GitHubRedirectPolicy.shared)
        guard let http = response as? HTTPURLResponse, http.url?.host == "api.github.com", data.count <= 16_000_000 else { throw NovaSyncFailure.invalidResponse }
        if http.statusCode == 404 && allowMissing { return .null }
        if [409,422].contains(http.statusCode) && allowConflict { return .null }
        guard (200..<300).contains(http.statusCode) else {
            if [403,429].contains(http.statusCode) {
                let delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ? http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) : nil
                githubRetryAfter = max(Date().addingTimeInterval(delay ?? 60), reset.map(Date.init(timeIntervalSince1970:)) ?? .distantPast)
            }
            let message: String
            switch http.statusCode {
            case 401: message = "Your GitHub token expired or was revoked. Reconnect GitHub; your library is saved here."
            case 403,429: message = "GitHub access is restricted or rate limited. Check repository access and try later. Your library is saved here."
            case 404: message = "That private repository was not found. Check its owner/name and token access."
            default: message = "GitHub could not sync right now. Your library is saved here."
            }
            throw NovaSyncFailure.message(message)
        }
        return try JSONDecoder().decode(NovaSyncValue.self, from: data)
    }

    private func keychainQuery() -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"nova-account"] }
    private func keychainRead() -> Data? {
        if let credentialStorage { return credentialStorage.read() }
        var query = keychainQuery(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess else { return nil }; return item as? Data
    }
    private func saveSession() throws {
        guard let session else { return }; let data = try JSONEncoder().encode(session)
        if let credentialStorage { try credentialStorage.save(data); return }
        var query = keychainQuery(); query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary,nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(keychainQuery() as CFDictionary,[kSecValueData as String:data] as CFDictionary) == errSecSuccess else { throw NovaSyncFailure.message("Could not securely save your sign-in. Try again.") }
        } else if status != errSecSuccess { throw NovaSyncFailure.message("Could not securely save your sign-in. Try again.") }
    }
    private func keychainDelete() { if let credentialStorage { credentialStorage.delete(); return }; SecItemDelete(keychainQuery() as CFDictionary) }
}

struct MusicAccountSyncSection: View {
    @ObservedObject var account: MusicAccountSync
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var reauth = false
    @State private var working = false
    @State private var addLibrary = true
    @State private var message: String?
    var body: some View {
        Group {
        if account.usesICloud { MusicICloudSyncSection(account: account) } else if account.usesGitHub { MusicGitHubSyncSection(account: account) } else {
        Section("Nova Music account") {
            if let user = account.user, !reauth {
                Text(user.email); LabeledContent("Library sync",value:account.status)
                if let date = account.lastSynced { Text("Last synced \(date.formatted(date:.omitted,time:.shortened))").font(.footnote).foregroundStyle(.secondary) }
                Button("Sync now") { Task { await account.sync() } }.disabled(working)
                Button("Sign in again") { email = user.email; creating = false; reauth = true; password = "" }.disabled(working)
                Button("Sign out") { perform { try await account.signOut() } }.disabled(working)
            } else if !account.configured {
                Text("Account sync is not available yet.")
            } else {
                Text("Use the same account in the app and browser to share your library.").font(.footnote).foregroundStyle(.secondary)
                TextField("Email address",text:$email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(working || reauth)
                SecureField(creating ? "New password (12+ characters)" : "Password",text:$password).textContentType(creating ? .newPassword : .password).disabled(working)
                if creating { SecureField("Confirm password",text:$confirmation).textContentType(.newPassword).disabled(working) }
                if !creating && !reauth { Toggle("Add this device’s library to my account",isOn:$addLibrary).disabled(working) }
                Button(creating ? "Create account" : "Sign in") { perform {
                    let address = email.trimmingCharacters(in:.whitespacesAndNewlines)
                    if creating {
                        guard password == confirmation else { throw NovaSyncFailure.message("The passwords do not match.") }
                        try await account.createAccount(email:address,password:password)
                        creating = false; message = "Check your email to confirm your account, then sign in here."
                    } else { try await account.signIn(email:address,password:password,mergeGuest:!reauth && addLibrary); reauth = false }
                } }.disabled(working)
                if reauth { Button("Cancel") { reauth = false; password = "" }.disabled(working) }
                else {
                    Button(creating ? "Back to sign in" : "Create account") { creating.toggle(); password = ""; confirmation = ""; message = nil }.disabled(working)
                    Button("Forgot password?") { perform { try await account.sendPasswordReset(email:email.trimmingCharacters(in:.whitespacesAndNewlines)); message = "If an account exists, a reset link has been sent. Open it in your browser, choose a new password, then sign in here." } }.disabled(working)
                }
            }
            if working { ProgressView() }
            if let text = message ?? account.error { Text(text).font(.footnote).foregroundStyle(.secondary) }
            Text("Sync includes your library, profile picture and playlist artwork. Imported audio and playback settings remain on their original device.").font(.footnote).foregroundStyle(.secondary)
        }
            }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true; message = nil
        Task { do { try await operation() } catch { message = error.localizedDescription }; password = ""; confirmation = ""; working = false }
    }
}


struct MusicProfileAvatar: View {
    let profile: MusicAccountProfile
    var size: CGFloat = 38
    private var photo: UIImage? {
        guard let encoded = profile.image.split(separator:",",maxSplits:1).last, !profile.image.isEmpty, let data = Data(base64Encoded:String(encoded)) else { return nil }
        return UIImage(data:data)
    }
    var body: some View {
        ZStack {
            Color(red: Double(Int(profile.color.dropFirst().prefix(2),radix:16) ?? 30)/255,
                  green: Double(Int(profile.color.dropFirst(3).prefix(2),radix:16) ?? 215)/255,
                  blue: Double(Int(profile.color.suffix(2),radix:16) ?? 96)/255)
            if let photo { Image(uiImage:photo).resizable().scaledToFill() }
            else { Text(profile.icon).font(.system(size:size * 0.5)).foregroundStyle(.black) }
        }.frame(width:size,height:size).clipShape(Circle()).accessibilityHidden(true)
    }
}
struct MusicProfileAccountButton: View {
    @ObservedObject var store: YouTubeStore
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { MusicProfileAvatar(profile:store.musicProfile) }
            .accessibilityLabel(store.musicProfile.name.isEmpty ? "Account" : "\(store.musicProfile.name), Account")
            .sheet(isPresented:$presented) {
                NavigationStack {
                    Form {
                        Section { HStack(spacing:16) { MusicProfileAvatar(profile:store.musicProfile,size:72); VStack(alignment:.leading) { Text(store.musicProfile.name.isEmpty ? "Your profile" : store.musicProfile.name).font(.title2.bold()); NavigationLink("Edit profile icon") { MusicProfileEditor(store:store) } } }.padding(.vertical,8) }
                        MusicAccountSyncSection(account:store.musicAccount)
                    }.navigationTitle("Account").toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { presented = false } } }
                }.preferredColorScheme(.dark)
            }
    }
}
struct MusicProfileEditor: View {
    @ObservedObject var store: YouTubeStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MusicAccountProfile()
    @State private var photo: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var error: String?
    var body: some View {
        Form {
            Section { HStack { Spacer(); MusicProfileAvatar(profile:draft,size:100); Spacer() }.padding(.vertical,16); TextField("Display name",text:$draft.name) }
            Section("Choose an icon") {
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:6)) {
                    ForEach(MusicAccountProfile.icons,id:\.self) { icon in
                        Button { draft.icon = icon; draft.image = "" } label: { Text(icon).font(.title).frame(maxWidth:.infinity,minHeight:44).background(draft.image.isEmpty && draft.icon == icon ? Color.white.opacity(0.18) : .clear,in:RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain).accessibilityLabel("Icon \(icon)").accessibilityAddTraits(draft.image.isEmpty && draft.icon == icon ? .isSelected : [])
                    }
                }
            }
            Section("Background color") {
                HStack { ForEach(MusicAccountProfile.colors,id:\.self) { color in
                    Button { draft.color = color } label: { MusicProfileAvatar(profile:MusicAccountProfile(icon:"",color:color),size:32).overlay { if draft.color == color { Image(systemName:"checkmark").foregroundStyle(.black) } } }.buttonStyle(.plain).accessibilityLabel(["#1ed760":"Green","#a78bfa":"Purple","#fb7185":"Pink","#38bdf8":"Blue","#fbbf24":"Yellow","#fb923c":"Orange"][color] ?? color).accessibilityAddTraits(draft.color == color ? .isSelected : [])
                } }
            }
            Section {
                PhotosPicker("Choose a profile photo",selection:$photo,matching:.images)
                if !draft.image.isEmpty { Button("Remove photo") { draft.image = "" } }
                if loadingPhoto { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary) }
                Text(store.musicAccount.user == nil ? "Enable iCloud to sync your icon across devices." : "Your profile is saved privately with your account and syncs across devices.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Edit profile").onAppear { draft = store.musicProfile }
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Save") { do { let profile = try draft.validated(); store.musicProfile = profile; store.defaults.set(try JSONEncoder().encode(profile),forKey:"music.account.profile"); store.musicAccount.changed(); dismiss() } catch { self.error = "Choose a name up to 60 characters and a smaller photo." } }.disabled(loadingPhoto) } }
            .task(id:photo) {
                guard let photo else { return }; loadingPhoto = true; defer { loadingPhoto = false }
                do {
                    guard let data = try await photo.loadTransferable(type:Data.self), data.count <= 15_000_000, let image = UIImage(data:data) else { throw NovaSyncFailure.invalidDocument }
                    try Task.checkCancellation()
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let resized = UIGraphicsImageRenderer(size:CGSize(width:256,height:256),format:format).image { _ in
                        let side = min(image.size.width,image.size.height),scale = 256/side
                        image.draw(in:CGRect(x:(256-image.size.width*scale)/2,y:(256-image.size.height*scale)/2,width:image.size.width*scale,height:image.size.height*scale))
                    }
                    guard let jpeg = resized.jpegData(compressionQuality:0.8) else { throw NovaSyncFailure.invalidDocument }
                    draft.image = "data:image/jpeg;base64," + jpeg.base64EncodedString(); draft = try draft.validated(); error = nil
                } catch { if !Task.isCancelled { self.error = "This photo could not load. Choose a smaller image." } }
            }
    }
}

@MainActor
extension MusicAccountSync {
    fileprivate var deviceID: String { actor.uuidString.lowercased() }
    private var connectedSession: MusicConnectedSession? {
        guard let value = try? document.values["connect:session"]?.decoded(MusicConnectedSession.self), value.valid else { return nil }
        return value
    }
    private var activeConnection: Bool {
        connectedSession?.isActive(status: try? document.values["connect:status"]?.decoded(MusicConnectedSnapshot.self)) == true
    }
    var controlsRemoteOutput: Bool { !carPlayOwnsOutput && !usesGitHub && user != nil && activeConnection && (!usesICloud || connectedSession.map { localPeers.contains($0.owner) } == true) && connectedSession.map { $0.owner != deviceID } == true }
    private var connectedSnapshot: MusicConnectedSnapshot? {
        guard let session = connectedSession else { return nil }
        var snapshot = session.snapshot
        if let status = try? document.values["connect:status"]?.decoded(MusicConnectedSnapshot.self), status.valid,
           status.owner == session.owner, status.command == session.command { snapshot = status }
        else { snapshot.playing = false }
        if Date().timeIntervalSince1970 * 1000 - (snapshot.at ?? session.at) >= 90000 { snapshot.playing = false }
        return snapshot
    }
    private func setConnection(_ values: [String:NovaSyncValue]) throws {
        guard user != nil else { return }
        let old = document.values; var next = old; next.merge(values,uniquingKeysWith:{ _,new in new })
        document = try document.updating(previous:old,next:next,actor:actor)
        publishLocalConnection()
        previous.merge(values,uniquingKeysWith:{ _,new in new }); connectionNeedsSync = true; try saveDocument()
    }
    private func localSnapshot() -> MusicConnectedSnapshot {
        guard let store else { return MusicConnectedSnapshot() }
        let player = store.player
        let ids = player.playlistIDs.isEmpty ? [player.currentVideoID].compactMap { $0 } : player.playlistIDs
        var queue = ids.map { id in MusicConnectedSong(player.musicTracks[id] ?? store.queueVideos.first { $0.id == id } ?? store.current.flatMap { $0.id == id ? $0 : nil } ?? .placeholder(id)) }
        let index = queue.isEmpty ? 0 : max(0,min(player.playlistIndex,queue.count - 1))
        if queue.indices.contains(index), player.duration.isFinite, player.duration > 0 { queue[index].duration = player.duration }
        var snapshot = MusicConnectedSnapshot(queue:queue,index:index,position:max(0,player.currentTime),playing:player.playing,shuffle:player.shuffled,repeat:player.repeatMode == .off ? 0 : player.repeatMode == .all ? 1 : 2,at:Date().timeIntervalSince1970 * 1000)
        if let id = player.currentVideoID {
            let lyrics = player.trackLyrics, timing = player.lyricCalibration
            snapshot.lyrics = MusicConnectedLyrics(songID:id,recordingID:player.resolvedMusicAudioID ?? id,loaded:lyrics != nil,plain:lyrics?.plainText ?? "",lines:lyrics?.lines.map { .init(time:$0.time,text:$0.text,endTime:$0.endTime) } ?? [],instrumental:lyrics?.instrumental ?? false,source:lyrics?.source ?? "Lyrics",sourceURL:lyrics?.sourceURL.absoluteString,offset:timing.offset,rate:timing.rate)
        }
        snapshot.context = player.queueEntries.indices.contains(player.playlistIndex) ? player.currentQueueOrigin : store.musicPlaybackContext
        snapshot.contextSongIDs = store.musicContextSongIDs
        snapshot.queueOrigins = ids.enumerated().map { index, _ in player.queueEntries.indices.contains(index) ? player.queueEntries[index].originContext : store.musicPlaybackContext }
        snapshot.activityAt = playbackActivityAt ?? connectedSession?.at
        snapshot.loading = player.loading || (!player.ready && !queue.isEmpty)
        return snapshot
    }
    private func updatePlaybackIntent() {
        guard let player = store?.player else { return }
        let status = try? document.values["connect:status"]?.decoded(MusicConnectedSnapshot.self)
        if let intent = playbackIntent, let command = intent.command,
           connectedSession?.command != command || status?.owner == connectedSession?.owner && status?.command == command && status?.playing == intent.playing {
            playbackIntent = nil; intentTimeout?.cancel()
        }
        if let intent = playbackIntent { player.connectedPendingPlaying = intent.playing }
        else if controlsRemoteOutput, let session = connectedSession, session.snapshot.handoff == nil,
                Date().timeIntervalSince1970 * 1000 - session.at < 15000,
                !(status?.owner == session.owner && status?.command == session.command && status?.playing == session.snapshot.playing) {
            player.connectedPendingPlaying = session.snapshot.playing
        } else { player.connectedPendingPlaying = nil }
    }
    func activateCarPlayOutput() {
        guard !carPlayOwnsOutput else { return }
        carPlayOwnsOutput = true
        commandTask?.cancel(); commandTask = nil
        freezeTask?.cancel(); freezeTask = nil; preparingCommand = nil; acknowledgedHandoff = nil
        outputTimeout?.cancel(); pendingOutputID = nil; outputIntent = nil
        intentTimeout?.cancel(); playbackIntent = nil; store?.player.connectedPendingPlaying = nil
        mirrorClockTask?.cancel(); mirrorClockTask = nil
        if remoteMirroring {
            applyingPlayback = true
            store?.player.endConnectedLyrics(); store?.player.stop(); store?.current = nil
            applyingPlayback = false; remoteMirroring = false
        }
        claimCarPlayOutput()
    }
    private func claimCarPlayOutput() {
        outputID = deviceID; outputName = "This device"
        guard user != nil else { return }
        let snapshot = localSnapshot()
        guard snapshot.valid, !snapshot.queue.isEmpty else { return }
        let session = MusicConnectedSession(owner: deviceID, command: UUID().uuidString.lowercased(), at: Date().timeIntervalSince1970 * 1000, snapshot: snapshot)
        do {
            try setConnection(["connect:session": .encoded(session)])
            appliedCommand = session.command; wasOutput = true; publishConnectionStatus()
        } catch { outputError = error.localizedDescription }
    }
    private func receiveConnection() {
        guard !usesGitHub else { return }
        if carPlayOwnsOutput, connectedSession?.owner != deviceID {
            claimCarPlayOutput()
            return
        }
        if let intent = outputIntent, let status = try? document.values["connect:status"]?.decoded(MusicConnectedSnapshot.self),
           connectedSession?.command != intent.command || status.owner == intent.id && status.command == intent.command && status.handoff == nil && status.loading != true && status.playing == intent.playing {
            pendingOutputID = nil; outputIntent = nil; outputTimeout?.cancel()
        }
        updatePlaybackIntent()
        guard let store else { return }
        outputDevices = document.values.filter { $0.key.hasPrefix("connect:device.") }.compactMap { try? $0.value.decoded(MusicConnectedDevice.self) }.filter { $0.online && UUID(uuidString:$0.id) != nil && (!usesICloud || $0.id == deviceID || localPeers.contains($0.id)) }.sorted { $0.name < $1.name }
        let session = connectedSession
        outputID = activeConnection && (session?.owner == deviceID || controlsRemoteOutput) ? session?.owner : deviceID
        let selectedDevice = outputID.flatMap { try? document.values["connect:device." + $0]?.decoded(MusicConnectedDevice.self) }
        outputName = outputID == nil || outputID == deviceID ? "This device" : selectedDevice?.name ?? "Unavailable device"
        let isOutput = session?.owner == deviceID
        if remoteMirroring && !controlsRemoteOutput {
            applyingPlayback = true
            store.player.endConnectedLyrics(); store.player.stop(); store.current = nil
            applyingPlayback = false; remoteMirroring = false
        }
        receiveLyricsDisplayStatus()
        if wasOutput && !isOutput || controlsRemoteOutput && !remoteMirroring {
            applyingPlayback = true; store.player.stop(); applyingPlayback = false
        }
        wasOutput = isOutput
        if !controlsRemoteOutput { mirrorClockTask?.cancel(); mirrorClockTask = nil }
        if isOutput, let session, session.command != appliedCommand,
           (Date().timeIntervalSince1970 * 1000 - session.at < 120000 || appliedCommand == nil), session.at <= Date().timeIntervalSince1970 * 1000 + 10000 {
            let statusCommand = try? document.values["connect:status"]?.decoded(MusicConnectedSnapshot.self).command
            let restored = appliedCommand == nil && (statusCommand == session.command || Date().timeIntervalSince1970 * 1000 - session.at >= 90000) ? connectedSnapshot : nil
            freezeTask?.cancel(); preparingCommand = nil; acknowledgedHandoff = nil
            appliedCommand = session.command
            if let handoff = session.snapshot.handoff {
                preparingCommand = session.command
                let epoch = generation
                freezeTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        self.applyingPlayback = true
                        store.player.pause()
                        self.applyingPlayback = false
                        let position = try await store.player.freezeConnectedClock()
                        guard !Task.isCancelled, self.generation == epoch, self.connectedSession?.command == session.command, self.connectedSession?.owner == self.deviceID else { return }
                        store.player.currentTime = position
                        self.preparingCommand = nil; self.acknowledgedHandoff = handoff
                        self.publishConnectionStatus(); await self.syncPlayback()
                    } catch {
                        self.applyingPlayback = false
                        if self.generation == epoch { self.outputError = "The output could not confirm its position. Try again." }
                    }
                }
            } else {
                applyPlayback(restored ?? session.snapshot)
                publishConnectionStatus()
            }
        } else if controlsRemoteOutput, let snapshot = connectedSnapshot {
            remoteMirroring = true; applyingPlayback = true; defer { applyingPlayback = false }
            store.musicPlaybackContext=snapshot.context
            store.musicContextSongIDs=snapshot.contextSongIDs ?? [:]
            let tracks = snapshot.queue.map(\.video), previousSong = store.current
            if store.queueVideos != tracks { store.queueVideos = tracks }; store.playingMusic = true
            store.player.musicTracks = Dictionary(tracks.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
            store.player.mirrorConnectedPlayback(ids:tracks.map(\.id),index:snapshot.index,position:snapshot.advancedPosition(),duration:snapshot.queue.indices.contains(snapshot.index) ? snapshot.queue[snapshot.index].duration ?? 0 : 0,playing:snapshot.playing)
            store.player.setQueueOrigins(snapshot.queueOrigins ?? Array(repeating: snapshot.context, count: tracks.count))
            store.player.shuffled = snapshot.shuffle
            store.player.repeatMode = snapshot.repeat == 0 ? .off : snapshot.repeat == 1 ? .all : .one
            store.current = tracks.indices.contains(snapshot.index) ? tracks[snapshot.index] : nil
            if let lyrics = snapshot.lyrics, lyrics.songID == store.current?.id {
                store.player.mirrorConnectedLyrics(lyrics.track,calibration:LyricCalibration(offset:lyrics.offset,rate:lyrics.rate))
            } else {
                store.player.mirrorConnectedLyrics(nil,calibration:LyricCalibration())
            }
            if let song = store.current, song != previousSong { store.player.setMetadata(song) }
            if mirrorClockTask == nil {
                mirrorClockTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard self?.controlsRemoteOutput == true, let snapshot = self?.connectedSnapshot else { return }
                        self?.store?.player.currentTime = snapshot.advancedPosition()
                        try? await Task.sleep(for:.milliseconds(100))
                    }
                }
            }
        }
    }
    private func applyPlayback(_ snapshot: MusicConnectedSnapshot) {
        guard let store, snapshot.valid else { return }
        applyingPlayback = true; defer { applyingPlayback = false }
        let tracks = snapshot.queue.map(\.video), player = store.player
        if remoteMirroring { player.endConnectedLyrics(); remoteMirroring = false }
        guard tracks.indices.contains(snapshot.index) else { store.close(); return }
        let song = tracks[snapshot.index], wasShuffled = player.shuffled
        let needsLoad = player.currentVideoID != song.id || !player.ready && !player.loading
        if needsLoad { store.play(song,minimized:store.minimized,music:true,shuffle:false,context:snapshot.context) }
        store.musicPlaybackContext=snapshot.context
        store.musicContextSongIDs=snapshot.contextSongIDs ?? [:]
        store.rememberCollectionPosition(song.id)
        store.queueVideos = tracks
        player.musicTracks = Dictionary(tracks.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
        player.connectedQueue(tracks.map(\.id),index:snapshot.index)
        player.setQueueOrigins(snapshot.queueOrigins ?? Array(repeating: snapshot.context, count: tracks.count))
        if !needsLoad && wasShuffled != snapshot.shuffle { player.shuffled = wasShuffled; player.toggleShuffle() }
        else { player.shuffled = snapshot.shuffle }
        player.repeatMode = snapshot.repeat == 0 ? .off : snapshot.repeat == 1 ? .all : .one
        if let lyrics = snapshot.lyrics, lyrics.songID == song.id {
            if lyrics.loaded { player.mirrorConnectedLyrics(lyrics.track,calibration:LyricCalibration(offset:lyrics.offset,rate:lyrics.rate)) }
            else { player.lyricCalibration = LyricCalibration(offset:lyrics.offset,rate:lyrics.rate) }
        }
        if needsLoad || snapshot.positionIntent != "preserve" { player.seek(to:snapshot.position) }
        if snapshot.playing { if !player.intendsPlayback { player.play() } } else { player.pause() }
    }
    /// Coalesce related player mutations, then send the settled snapshot immediately.
    /// Regular clock ticks do not enter this path, and mirrored updates cannot echo.
    private func schedulePlaybackPublication() {
        guard user != nil, !usesGitHub, !applyingPlayback, !remoteMirroring else { return }
        playbackActivityAt = Date().timeIntervalSince1970 * 1000
        playbackPublishTask?.cancel()
        playbackPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled, !self.applyingPlayback, !self.remoteMirroring else { return }
            var snapshot = self.localSnapshot()
            snapshot.positionIntent = "preserve"
            guard snapshot.valid else { return }
            if self.connectedSession?.owner != self.deviceID, !self.controlsRemoteOutput, !snapshot.queue.isEmpty {
                let session = MusicConnectedSession(owner: self.deviceID, command: UUID().uuidString.lowercased(), at: Date().timeIntervalSince1970 * 1000, snapshot: snapshot)
                let previousCommand = self.appliedCommand, previouslyOutput = self.wasOutput
                // Claim this already-running engine before publishing; a local
                // loopback must never reapply its loading/paused startup sample.
                self.appliedCommand = session.command; self.wasOutput = true
                do { try self.setConnection(["connect:session": .encoded(session)]) }
                catch {
                    self.appliedCommand = previousCommand; self.wasOutput = previouslyOutput
                    self.outputError = error.localizedDescription; return
                }
            }
            self.publishConnectionStatus()
            await self.syncPlayback()
        }
    }
    func showLyricsOnMac(_ id: String) {
        guard outputDevices.contains(where: { $0.id == id && $0.online && $0.capabilities?.contains("lyricsDisplay") == true }) else {
            lyricsDisplayMessage = "Open the updated Nova Music app on your Mac first."; return
        }
        let requestID = UUID().uuidString.lowercased(), at = Date().timeIntervalSince1970 * 1000
        do {
            try setConnection(["connect:display." + id: .object(["id": .string(requestID), "target": .string(id), "action": .string("lyrics"), "at": .number(at)])])
            displayRequest = (id, requestID, at); lyricsDisplayMessage = "Opening lyrics on Mac…"
            Task { await syncPlayback() }
        } catch { lyricsDisplayMessage = error.localizedDescription }
    }
    private func receiveLyricsDisplayStatus() {
        guard let request = displayRequest else { return }
        if let status = document.values["connect:display-status." + request.target], status["id"]?.string == request.id {
            lyricsDisplayMessage = "Lyrics opened on Mac"; displayRequest = nil
        } else if Date().timeIntervalSince1970 * 1000 - request.at > 30000 {
            lyricsDisplayMessage = "The Mac did not respond. Make sure it is awake and Nova Music is running."; displayRequest = nil
        }
    }
    private func publishConnectionStatus() {
        guard preparingCommand == nil, let session = connectedSession, session.owner == deviceID, session.command == appliedCommand else { return }
        var snapshot = localSnapshot(); guard snapshot.valid else { return }
        snapshot.owner = deviceID; snapshot.command = appliedCommand; snapshot.handoff = acknowledgedHandoff
        try? setConnection(["connect:status":.encoded(snapshot)])
    }
    func connectTick() async {
        guard !usesGitHub else { return }
        guard user != nil else { return }
        if usesICloud, UIApplication.shared.applicationState != .active, store?.player.playing != true { return }
        let now = Date()
        if now.timeIntervalSince(lastPresence) > 15 {
            lastPresence = now
            let device = MusicConnectedDevice(id:deviceID,name:UIDevice.current.name,at:now.timeIntervalSince1970 * 1000)
            try? setConnection(["connect:device." + deviceID:.encoded(device)])
        }
        if now.timeIntervalSince(lastStatus) > 5 { lastStatus = now; publishConnectionStatus() }
        if usesICloud {
            await syncLocalConnection()
            if outputError == nil, connectedSession == nil, store?.playingMusic == true {
                let snapshot = localSnapshot()
                if snapshot.valid, snapshot.playing, !snapshot.queue.isEmpty {
                    let session = MusicConnectedSession(owner: deviceID, command: UUID().uuidString.lowercased(), at: now.timeIntervalSince1970 * 1000, snapshot: snapshot)
                    do {
                        try setConnection(["connect:session": .encoded(session)])
                        appliedCommand = session.command; wasOutput = true; publishConnectionStatus()
                        await syncLocalConnection()
                    } catch { outputError = error.localizedDescription }
                }
            }
            return
        }
        if connectionNeedsSync || serverRevision == nil || error != nil { await sync(); return }
        let epoch = generation, id = user!.id
        do {
            let response = try await request("/rest/v1/nova_music_libraries?select=revision&user_id=eq.\(id.uuidString.lowercased())",authenticated:true)
            try assertCurrent(epoch,id)
            guard let rows = response.array, rows.count <= 1 else { throw NovaSyncFailure.invalidResponse }
            if (rows.first?["revision"]?.number ?? 0) != serverRevision { await sync() }
            else { receiveConnection() }
            if connectedSession == nil, store?.playingMusic == true {
                let snapshot = localSnapshot()
                if snapshot.valid, snapshot.playing, !snapshot.queue.isEmpty { sendPlayback { _ in snapshot } }
            }
        } catch { if generation == epoch { outputError = "Could not reach your output devices. Check your connection." } }
    }
    private func resetConnection() {
        localKey = nil; localPeers = []; localPlayback.stop()
        playbackPublishTask?.cancel(); playbackPublishTask = nil; playbackActivityAt = nil
        displayRequest = nil; lyricsDisplayMessage = nil
        outputTimeout?.cancel(); pendingOutputID = nil; outputIntent = nil
        mirrorClockTask?.cancel(); mirrorClockTask = nil
        intentTimeout?.cancel(); playbackIntent = nil; store?.player.connectedPendingPlaying = nil
        freezeTask?.cancel(); freezeTask = nil; preparingCommand = nil; acknowledgedHandoff = nil
        commandTask?.cancel(); commandTask = nil
        if wasOutput || remoteMirroring { applyingPlayback = true; store?.player.stop(); applyingPlayback = false; store?.current = nil }
        appliedCommand = nil; wasOutput = false; remoteMirroring = false
        outputDevices = []; outputID = nil; outputName = "This device"; outputError = nil
        lastPresence = .distantPast; lastStatus = .distantPast; connectionNeedsSync = true; serverRevision = nil
    }
    private func sendPlayback(output: String? = nil, transfer: Bool = false, intentID: UUID? = nil, change: @escaping (MusicConnectedSnapshot) -> MusicConnectedSnapshot) {
        let preceding = commandTask, epoch = generation
        commandTask = Task { [weak self] in
            await preceding?.value
            guard let self, !Task.isCancelled, self.generation == epoch else { return }
            await self.syncPlayback()
            guard !Task.isCancelled, self.generation == epoch else { return }
            var eagerCommand: String?
            do {
                guard (self.usesICloud ? self.outputError == nil : self.error == nil) else { throw NovaSyncFailure.message("Could not reach your devices. Check your connection.") }
                let owner = output ?? (self.controlsRemoteOutput ? self.connectedSession?.owner : nil) ?? self.deviceID
                if owner != self.deviceID && !self.outputDevices.contains(where:{ $0.id == owner && $0.online }) { throw NovaSyncFailure.message("That device is unavailable. Choose an output location.") }
                var frozen: MusicConnectedSnapshot?
                if transfer, let old = self.connectedSession, old.owner != owner {
                    let wasPlaying = self.connectedSnapshot?.playing ?? old.snapshot.playing
                    var request = self.connectedSnapshot ?? old.snapshot
                    if !self.outputDevices.contains(where:{ $0.id == old.owner && $0.online }) {
                        request.playing = wasPlaying; request.handoff = nil; frozen = request
                    } else if old.owner == self.deviceID, let store = self.store {
                        self.applyingPlayback = true; store.player.pause(); self.applyingPlayback = false
                        let position = try await store.player.freezeConnectedClock()
                        guard self.connectedSession?.command == old.command else { throw NovaSyncFailure.message("Playback changed during transfer. Choose the output again.") }
                        request = self.localSnapshot(); request.position = position; request.playing = wasPlaying; request.handoff = nil; frozen = request
                    } else {
                        let checkpoint = request
                        let handoff = UUID().uuidString.lowercased()
                        request.handoff = handoff; request.playing = false
                        let freeze = MusicConnectedSession(owner:old.owner,command:UUID().uuidString.lowercased(),at:Date().timeIntervalSince1970 * 1000,snapshot:request)
                        try self.setConnection(["connect:session":.encoded(freeze)]); await self.syncPlayback()
                        let deadline = Date().addingTimeInterval(self.usesICloud ? 5 : 4)
                        while Date() < deadline {
                            guard !Task.isCancelled, self.generation == epoch else { return }
                            guard self.connectedSession?.command == freeze.command else { throw NovaSyncFailure.message("Playback changed during transfer. Choose the output again.") }
                            if var status = try? self.document.values["connect:status"]?.decoded(MusicConnectedSnapshot.self), status.valid, status.owner == old.owner, status.command == freeze.command, status.handoff == handoff, !status.playing {
                                status.playing = wasPlaying; status.handoff = nil; frozen = status; break
                            }
                            try await Task.sleep(for:.milliseconds(self.usesICloud ? 25 : 250)); await self.syncPlayback()
                        }
                        guard self.connectedSession?.command == freeze.command else { throw NovaSyncFailure.message("Playback changed during transfer. Choose the output again.") }
                        if frozen == nil, self.usesICloud { throw NovaSyncFailure.message("The previous output did not confirm its position. Keep both apps open and try the transfer again.") }
                        if frozen == nil { var recovery = checkpoint; recovery.playing = wasPlaying; recovery.handoff = nil; frozen = recovery }
                    }
                }
                guard (self.usesICloud ? self.outputError == nil : self.error == nil) else { throw NovaSyncFailure.message("Could not reach your devices. Check your connection.") }
                var next = frozen ?? change(self.connectedSession?.owner == self.deviceID && self.appliedCommand == self.connectedSession?.command ? self.localSnapshot() : self.connectedSnapshot ?? self.localSnapshot()); next.at = Date().timeIntervalSince1970 * 1000; next.activityAt = next.at
                guard next.valid else { throw NovaSyncFailure.message("This queue cannot be played across devices.") }
                let session = MusicConnectedSession(owner:owner,command:UUID().uuidString.lowercased(),at:Date().timeIntervalSince1970 * 1000,snapshot:next)
                if let intentID, self.playbackIntent?.id == intentID { self.playbackIntent?.command = session.command }
                try self.setConnection(["connect:session":.encoded(session)])
                if transfer, self.pendingOutputID == owner { self.outputIntent = (owner,session.command,next.playing) }
                // The latest ownership read is complete; prepare our local engine
                // while the account write is delivered, rather than waiting for it.
                if owner == self.deviceID { eagerCommand = session.command; self.receiveConnection() }
                await self.syncPlayback()
                guard self.generation == epoch else { return }
                if (self.usesICloud ? self.outputError != nil : self.error != nil) { throw NovaSyncFailure.message("Playback change could not be sent. Check your connection.") }
                self.outputError = nil
            } catch {
                self.applyingPlayback = false
                if let eagerCommand, self.appliedCommand == eagerCommand { self.applyingPlayback = true; self.store?.player.pause(); self.applyingPlayback = false }
                if transfer, self.pendingOutputID == output { self.pendingOutputID = nil; self.outputIntent = nil; self.outputTimeout?.cancel() }
                if let intentID, self.playbackIntent?.id == intentID { self.playbackIntent = nil; self.intentTimeout?.cancel(); self.store?.player.connectedPendingPlaying = nil }
                self.outputError = error.localizedDescription
            }
        }
    }
    func selectOutput(_ id: String) {
        guard !usesGitHub else { return }
        carPlayOwnsOutput = false
        guard id != connectedSession?.owner else { return }
        pendingOutputID = id; outputIntent = nil; outputError = nil; outputTimeout?.cancel()
        outputTimeout = Task { [weak self] in
            try? await Task.sleep(for:.seconds(30)); guard !Task.isCancelled, self?.pendingOutputID == id else { return }
            self?.pendingOutputID = nil; self?.outputIntent = nil; self?.outputError = "The selected output did not respond. Choose another speaker."
        }
        sendPlayback(output:id,transfer:true) { $0 }
    }
    func routePlay(_ song: YouTubeVideo, queue: [YouTubeVideo], shuffle: Bool?, context: String? = nil) -> Bool {
        guard !carPlayOwnsOutput, !usesGitHub, user != nil, !applyingPlayback else { return false }
        if usesICloud && !controlsRemoteOutput { return false }
        let tracks = queue.contains(where:{ $0.id == song.id }) ? queue : [song]
        sendPlayback { current in MusicConnectedSnapshot(queue:tracks.map(MusicConnectedSong.init),index:tracks.firstIndex { $0.id == song.id } ?? 0,playing:true,shuffle:shuffle ?? current.shuffle,repeat:current.repeat,context:context,queueOrigins:Array(repeating:context,count:tracks.count)) }
        return true
    }
    func routePlaylist(_ playlist: YouTubePlaylist,index: Int,shuffle: Bool?) -> Bool {
        guard !carPlayOwnsOutput, !usesGitHub, user != nil, !applyingPlayback else { return false }
        if usesICloud && !controlsRemoteOutput { return false }
        store?.refreshSmartPlaylists()
        let playlist = playlist.smartRules == nil ? playlist : store?.playlist(playlist.id) ?? playlist
        if playlist.videos.isEmpty, let id = playlist.youtubePlaylistID {
            let epoch = generation
            Task { [weak self] in
                do { let tracks = try await YouTubeAPI.musicRankedSongs(id); guard let self, self.generation == epoch, !tracks.isEmpty else { return }; _ = self.routePlay(tracks[min(max(0,index),tracks.count - 1)],queue:tracks,shuffle:shuffle,context:"playlist:" + playlist.id.uuidString.lowercased()) }
                catch { self?.store?.musicActionError = error.localizedDescription }
            }
        } else if !playlist.videos.isEmpty {
            let index = shuffle == true ? playlist.videos.indices.randomElement() ?? 0 : min(max(0,index),playlist.videos.count - 1)
            _ = routePlay(playlist.videos[index],queue:playlist.videos,shuffle:shuffle,context:"playlist:" + playlist.id.uuidString.lowercased())
        }
        return true
    }
    private func routeControl(_ action: MusicConnectedAction) -> Bool {
        guard controlsRemoteOutput, !applyingPlayback else { return false }
        var intentID: UUID?
        let desired: Bool?
        switch action { case .play: desired = true; case .pause: desired = false; default: desired = nil }
        if let desired {
            let id = UUID(); intentID = id; playbackIntent = (id,desired,nil)
            store?.player.connectedPendingPlaying = desired
            intentTimeout?.cancel()
            intentTimeout = Task { [weak self] in
                try? await Task.sleep(for:.seconds(15))
                guard !Task.isCancelled, let self, self.playbackIntent?.id == id else { return }
                self.playbackIntent = nil; self.store?.player.connectedPendingPlaying = nil
                self.outputError = "The output did not respond. Choose another output location."
            }
        }
        let known = store?.player.musicTracks ?? [:]
        let origin = store?.player.pendingEnqueueOrigin
        let shuffleAddition = store?.player.pendingEnqueueShuffle ?? false
        sendPlayback(intentID:intentID) { current in
            var next = current; next.position = current.advancedPosition(); next.positionIntent = "preserve"
            next.queueOrigins = current.queueOrigins ?? Array(repeating: current.context, count: current.queue.count)
            switch action {
            case .play: next.playing = true
            case .pause: next.playing = false
            case .seek(let position): if position.isFinite { next.position = max(0,position); next.positionIntent = "seek" }
            case .next:
                next.positionIntent = "seek"
                if next.index + 1 < next.queue.count { next.index += 1; next.position = 0; next.playing = true }
                else if next.repeat == 1 { next.index = 0; next.position = 0 }
            case .previous:
                next.positionIntent = "seek"
                if next.position > 3 { next.position = 0 } else { next.index = max(0,next.index - 1); next.position = 0 }
            case .shuffle: next.shuffle.toggle()
            case .repeatMode: next.repeat = (next.repeat + 1) % 3
            case .stop: next.queue = []; next.queueOrigins = []; next.index = 0; next.position = 0; next.playing = false
            case .enqueue(let ids,let immediate):
                let songs = (shuffleAddition ? ids.shuffled() : ids).compactMap { known[$0].map(MusicConnectedSong.init) }
                let insertion = immediate ? min(next.index + 1,next.queue.count) : next.queue.count
                next.queue.insert(contentsOf:songs,at:insertion)
                next.queueOrigins?.insert(contentsOf:Array(repeating:origin,count:songs.count),at:insertion)
            case .clear: next.queue = Array(next.queue.prefix(next.index + 1)); next.queueOrigins = next.queueOrigins.map { Array($0.prefix(next.index + 1)) }
            case .remove(let offsets):
                for offset in offsets.sorted(by:>) { let index = next.index + 1 + offset; if next.queue.indices.contains(index) { next.queue.remove(at:index); next.queueOrigins?.remove(at:index) } }
            case .move(let offsets,let destination):
                var tail = Array(next.queue.dropFirst(next.index + 1))
                if offsets.allSatisfy({ tail.indices.contains($0) }) && (0...tail.count).contains(destination) { tail.move(fromOffsets:offsets,toOffset:destination); next.queue = Array(next.queue.prefix(next.index + 1)) + tail
                    if var origins = next.queueOrigins { var originTail = Array(origins.dropFirst(next.index + 1)); originTail.move(fromOffsets:offsets,toOffset:destination); origins = Array(origins.prefix(next.index + 1)) + originTail; next.queueOrigins = origins } }
            case .entry(let index): if next.queue.indices.contains(index) { next.positionIntent = "seek"; next.index = index; next.position = 0; next.playing = true }
            }
            if let origins = next.queueOrigins, origins.indices.contains(next.index) { next.context = origins[next.index] }
            return next
        }
        return true
    }
}

struct MusicOutputButton: View {
    @ObservedObject var account: MusicAccountSync
    @State private var showing = false
    @State private var routeIcon = "iphone"
    private func deviceIcon(_ name: String) -> String {
        let name = name.lowercased()
        if name.contains("ipad") { return "ipad" }
        if name.contains("iphone") || name.contains("phone") { return "iphone" }
        if name.contains("mac") || name.contains("computer") || name.contains("browser") { return "desktopcomputer" }
        if name.contains("airpod") { return "airpodspro" }
        if name.contains("headphone") { return "headphones" }
        return "hifispeaker.fill"
    }
    private func updateRouteIcon() {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        if ports.contains(where: { $0.portType == .headphones || $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE }) { routeIcon = "headphones" }
        else if ports.contains(where: { $0.portType == .airPlay }) { routeIcon = "airplay.audio" }
        else { routeIcon = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    }
    var body: some View {
        Button { showing = true } label: {
            Image(systemName:account.controlsRemoteOutput ? deviceIcon(account.outputName) : routeIcon).frame(width:36,height:44)
                .foregroundStyle(account.controlsRemoteOutput ? Color.green : Color.primary)
        }.accessibilityLabel("Output location").accessibilityValue(account.outputName)
        .onAppear { updateRouteIcon() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in updateRouteIcon() }
        .sheet(isPresented:$showing) {
            NavigationStack {
                List {
                    Section("Playing on") {
                        if account.user == nil { Text("Enable iCloud with the same Apple Account on both devices to connect playback.") }
                        Button { account.selectOutput(account.deviceID) } label: {
                            HStack { Label("This device",systemImage:"iphone"); Spacer(); if account.pendingOutputID == account.deviceID { ProgressView().accessibilityLabel("Connecting speaker") } else if account.outputID == account.deviceID || account.outputID == nil { Image(systemName:"checkmark").accessibilityLabel("Selected") } }
                        }.disabled(account.user == nil || account.pendingOutputID != nil)
                        ForEach(account.outputDevices.filter { $0.id != account.deviceID }) { device in
                            Button { account.selectOutput(device.id) } label: {
                                HStack { Label(device.name,systemImage:deviceIcon(device.name)); Spacer(); if account.pendingOutputID == device.id { ProgressView().accessibilityLabel("Connecting speaker") } else if account.outputID == device.id { Image(systemName:"checkmark").accessibilityLabel("Selected") } }
                            }.disabled(account.pendingOutputID != nil)
                        }
                        if let id = account.outputID, id != account.deviceID, !account.outputDevices.contains(where:{ $0.id == id }) {
                            HStack { Text("\(account.outputName) · unavailable"); Spacer(); Image(systemName:"checkmark").accessibilityLabel("Selected") }.foregroundStyle(.secondary)
                        }
                        if account.user != nil && account.outputDevices.count < 2 { Text("Open Nova Music on the same Wi-Fi network to see it here.").foregroundStyle(.secondary) }
                        if let error = account.outputError { Text(error).foregroundStyle(.red) }
                        Text("Current output: \(account.outputName)").font(.footnote)
                    }
                    Section("Lyrics on Mac") {
                        ForEach(account.outputDevices.filter { $0.capabilities?.contains("lyricsDisplay") == true }) { device in
                            Button { account.showLyricsOnMac(device.id) } label: {
                                Label("Show lyrics on " + device.name, systemImage: "text.quote")
                            }
                        }
                        if !account.outputDevices.contains(where: { $0.capabilities?.contains("lyricsDisplay") == true }) {
                            Text("Leave Nova Music running on your Mac to open its lyrics display here.").foregroundStyle(.secondary)
                        }
                        if let message = account.lyricsDisplayMessage { Text(message).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
                    }
                    Section("Speakers and headphones") {
                        HStack { Text("AirPlay and Bluetooth"); Spacer(); AudioRoutePicker().frame(width:40,height:40) }
                    }
                }.navigationTitle("Output location").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { showing = false } } }
                    .task { await account.connectTick() }
            }.presentationDetents([.medium,.large])
        }
    }
}

struct MusicGitHubSyncSection: View {
    @ObservedObject var account: MusicAccountSync
    @State private var repository = ""
    @State private var token = ""
    @State private var reconnecting = false
    @State private var mergeLibrary = true
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Section("Private GitHub library sync") {
            if account.user != nil && !reconnecting {
                Text(account.gitHubRepository).textSelection(.enabled)
                LabeledContent("Library", value: account.status)
                if let date = account.lastSynced { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary) }
                Button("Sync now") { Task { working = true; await account.sync(); working = false } }.disabled(working)
                Button("Update GitHub token") { repository = account.gitHubRepository; reconnecting = true }.disabled(working)
                Button("Disconnect GitHub") { account.disconnectGitHub() }.disabled(working)
            } else {
                Text("Use the same private repository on each device. Your current library stays available while GitHub is offline.").font(.footnote).foregroundStyle(.secondary)
                TextField("owner/repository", text: $repository).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(working || reconnecting)
                SecureField("GitHub access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(working)
                if !reconnecting { Toggle("Add this device’s library", isOn: $mergeLibrary).disabled(working) }
                Button(reconnecting ? "Update token" : "Connect GitHub") {
                    working = true; message = nil
                    Task {
                        do { try await account.connectGitHub(repository: repository, token: token, mergeLibrary: !reconnecting && mergeLibrary); reconnecting = false }
                        catch { message = error.localizedDescription }
                        token = ""; working = false
                    }
                }.disabled(working || token.isEmpty || repository.isEmpty)
                if reconnecting { Button("Cancel") { reconnecting = false; token = "" }.disabled(working) }
                Link("Create a private repository", destination: URL(string: "https://github.com/new")!)
                Link("Create an access token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new?name=Nova%20Music&contents=write")!)
                Text("Choose a private repository and give a fine-grained token access only to that repository, with Contents set to Read and write. Enter the token here, never in a public repository.").font(.footnote).foregroundStyle(.secondary)
            }
            if working { ProgressView() }
            if let error = message ?? account.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            Text("Syncs library metadata and custom artwork. Imported audio stays on its original device. Tokens are saved in this device’s Keychain. Disconnecting keeps your library and unsent edits here. Playback and AirPlay work without GitHub; live device controls have been removed.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}


private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = GitHubRedirectPolicy()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == "api.github.com", request.url?.user == nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

struct MusicICloudSyncSection: View {
    @ObservedObject var account: MusicAccountSync
    @State private var working = false
    @State private var addLibrary = true
    @State private var message: String?
    var body: some View {
        Section("iCloud sync") {
            LabeledContent("Library", value: account.status)
            if account.user != nil {
                Button("Sync now") { Task { working = true; await account.sync(); working = false } }.disabled(working)
                Button("Turn off iCloud sync") { account.disableICloud() }.disabled(working)
            } else {
                Toggle("Add this device’s library to iCloud", isOn: $addLibrary)
                Button("Enable iCloud sync") {
                    Task {
                        working = true; defer { working = false }
                        do { try await account.enableICloud(mergeLibrary: addLibrary); message = nil }
                        catch { message = error.localizedDescription }
                    }
                }.disabled(working)
            }
            if working { ProgressView() }
            if let message = message ?? account.error { Text(message).foregroundStyle(.secondary) }
            if let date = account.lastSynced { Text("Last synced \(date.formatted(date: .omitted, time: .shortened))").font(.footnote) }
            Text("Your library, playlists, profile and artwork sync privately through iCloud. Open Nova Music on both devices to share playback, queues and lyrics using Output Location. Imported audio stays on its original device. Now Playing connects directly over your local Wi-Fi network. Allow Local Network access on both devices.").font(.footnote).foregroundStyle(.secondary)
            Text("Turning off sync keeps your library here and in iCloud.").font(.footnote).foregroundStyle(.secondary)
        }.onAppear { if account.error == NovaCloudFailure.accountChanged.localizedDescription { addLibrary = false } }
    }
}
