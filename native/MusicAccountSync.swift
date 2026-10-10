import Foundation
import SwiftUI
import Combine
import Security
import UIKit
import PhotosUI

@MainActor
struct MusicAccountCredentialStorage {
    var read: () -> Data?
    var save: (Data) throws -> Void
    var delete: () -> Void
}

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
    @Published private(set) var outputDevices: [MusicConnectedDevice] = []
    @Published private(set) var outputName = "This device"
    @Published private(set) var outputID: String?
    @Published private(set) var outputError: String?
    private var connectTask: Task<Void,Never>?, commandTask: Task<Void,Never>?
    private var mirrorClockTask: Task<Void,Never>?
    private var freezeTask: Task<Void,Never>?
    private var playbackIntent: (id: UUID, playing: Bool, command: String?)?
    private var intentTimeout: Task<Void,Never>?
    private var preparingCommand: String?, acknowledgedHandoff: String?
    private var appliedCommand: String?, lastPresence = Date.distantPast, lastStatus = Date.distantPast
    private var applyingPlayback = false, remoteMirroring = false, wasOutput = false
    private var appliedLibrary: [String:NovaSyncValue]?
    private var connectionNeedsSync = true
    private var serverRevision: Double?
    private let actor: UUID
    private let url: URL?
    private let key: String
    private let service: String
    private let network: URLSession
    private let credentialStorage: MusicAccountCredentialStorage?
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

    init(store: YouTubeStore, network: URLSession = .shared, credentialService: String? = nil, credentialStorage: MusicAccountCredentialStorage? = nil) {
        self.store = store
        self.network = network
        self.credentialStorage = credentialStorage
        service = credentialService ?? (Bundle.main.bundleIdentifier ?? "NovaMusic") + ".account-sync"
        let raw = Bundle.main.object(forInfoDictionaryKey:"NovaSyncURL") as? String ?? ""
        let candidate = URL(string:raw)
        url = candidate?.scheme == "https" && candidate?.user == nil && candidate?.password == nil ? candidate : nil
        key = Bundle.main.object(forInfoDictionaryKey:"NovaSyncPublishableKey") as? String ?? ""
        actor = store.defaults.string(forKey:"music.sync.device").flatMap(UUID.init(uuidString:)) ?? UUID()
        store.defaults.set(actor.uuidString,forKey:"music.sync.device")
        store.player.connectedCommand = { [weak self] action in self?.routeControl(action) ?? false }
        Publishers.MergeMany(store.player.$playing.map { _ in () }.eraseToAnyPublisher(),store.player.$currentVideoID.map { _ in () }.eraseToAnyPublisher(),store.player.$trackLyrics.map { _ in () }.eraseToAnyPublisher(),store.player.$lyricCalibration.map { _ in () }.eraseToAnyPublisher())
            .sink { [weak self] _ in self?.lastStatus = .distantPast }.store(in:&subscriptions)
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
        connectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.connectTick()
                try? await Task.sleep(for:.seconds(2))
            }
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30))
                guard !Task.isCancelled else { return }; await self?.sync()
            }
        }
    }
    private func validateEmail(_ email: String) throws {
        guard configured else { throw NovaSyncFailure.notConfigured }
        guard email.range(of:"^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$",options:.regularExpression) != nil else { throw NovaSyncFailure.message("Enter a valid email address.") }
    }
    func signIn(email: String, password: String, mergeGuest: Bool) async throws {
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
    func changed() { captureChanges(schedule: true) }
    private func captureChanges(schedule: Bool) {
        guard user != nil, !applying, let store else { return }
        do {
            let next = try MusicAccountLibrary.values(store,preserving:document.values)
            guard next != previous else { return }
            document = try document.updating(previous:previous,next:next,actor:actor); previous = next; connectionNeedsSync = true; try saveDocument()
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
        receiveConnection()
        previous = try MusicAccountLibrary.values(store,preserving:document.values); try saveDocument()
    }
    func signOut() async throws {
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
        guard configured, let url, let endpoint = URL(string:path,relativeTo:url) else { throw NovaSyncFailure.notConfigured }
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
                Text(store.musicAccount.user == nil ? "Sign in to sync your icon across devices." : "Your profile is saved privately with your account and syncs across devices.").font(.footnote).foregroundStyle(.secondary)
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
    var controlsRemoteOutput: Bool { user != nil && connectedSession.map { $0.owner != deviceID } == true }
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
    private func receiveConnection() {
        updatePlaybackIntent()
        guard let store else { return }
        outputDevices = document.values.filter { $0.key.hasPrefix("connect:device.") }.compactMap { try? $0.value.decoded(MusicConnectedDevice.self) }.filter { $0.online && UUID(uuidString:$0.id) != nil }.sorted { $0.name < $1.name }
        let session = connectedSession
        outputID = session?.owner
        let selectedDevice = outputID.flatMap { try? document.values["connect:device." + $0]?.decoded(MusicConnectedDevice.self) }
        outputName = outputID == nil || outputID == deviceID ? "This device" : selectedDevice?.name ?? "Unavailable device"
        let isOutput = session?.owner == deviceID
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
                        self.publishConnectionStatus(); await self.sync()
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
            let tracks = snapshot.queue.map(\.video), previousSong = store.current
            if store.queueVideos != tracks { store.queueVideos = tracks }; store.playingMusic = true
            store.player.musicTracks = Dictionary(tracks.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
            store.player.mirrorConnectedPlayback(ids:tracks.map(\.id),index:snapshot.index,position:snapshot.advancedPosition(),duration:snapshot.queue.indices.contains(snapshot.index) ? snapshot.queue[snapshot.index].duration ?? 0 : 0,playing:snapshot.playing)
            store.player.shuffled = snapshot.shuffle
            store.player.repeatMode = snapshot.repeat == 0 ? .off : snapshot.repeat == 1 ? .all : .one
            store.current = tracks.indices.contains(snapshot.index) ? tracks[snapshot.index] : nil
            if let lyrics = snapshot.lyrics, lyrics.songID == store.current?.id {
                store.player.mirrorConnectedLyrics(lyrics.track,calibration:LyricCalibration(offset:lyrics.offset,rate:lyrics.rate))
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
        if needsLoad { store.play(song,music:true,shuffle:false) }
        store.queueVideos = tracks
        player.musicTracks = Dictionary(tracks.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
        player.connectedQueue(tracks.map(\.id),index:snapshot.index)
        if !needsLoad && wasShuffled != snapshot.shuffle { player.shuffled = wasShuffled; player.toggleShuffle() }
        else { player.shuffled = snapshot.shuffle }
        player.repeatMode = snapshot.repeat == 0 ? .off : snapshot.repeat == 1 ? .all : .one
        if let lyrics = snapshot.lyrics, lyrics.songID == song.id { player.lyricCalibration = LyricCalibration(offset:lyrics.offset,rate:lyrics.rate) }
        if needsLoad || snapshot.positionIntent != "preserve" { player.seek(to:snapshot.position) }
        if snapshot.playing { if !player.intendsPlayback { player.play() } } else { player.pause() }
    }
    private func publishConnectionStatus() {
        guard preparingCommand == nil, let session = connectedSession, session.owner == deviceID, session.command == appliedCommand else { return }
        var snapshot = localSnapshot(); guard snapshot.valid else { return }
        snapshot.owner = deviceID; snapshot.command = appliedCommand; snapshot.handoff = acknowledgedHandoff
        try? setConnection(["connect:status":.encoded(snapshot)])
    }
    fileprivate func connectTick() async {
        guard user != nil else { return }
        let now = Date()
        if now.timeIntervalSince(lastPresence) > 15 {
            lastPresence = now
            let device = MusicConnectedDevice(id:deviceID,name:UIDevice.current.name,at:now.timeIntervalSince1970 * 1000)
            try? setConnection(["connect:device." + deviceID:.encoded(device)])
        }
        if now.timeIntervalSince(lastStatus) > 5 { lastStatus = now; publishConnectionStatus() }
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
            await self.sync()
            guard !Task.isCancelled, self.generation == epoch else { return }
            do {
                guard self.error == nil else { throw NovaSyncFailure.message("Could not reach your devices. Check your connection.") }
                let owner = output ?? self.connectedSession?.owner ?? self.deviceID
                if owner != self.deviceID && !self.outputDevices.contains(where:{ $0.id == owner && $0.online }) { throw NovaSyncFailure.message("That device is unavailable. Choose an output location.") }
                var frozen: MusicConnectedSnapshot?
                if transfer, let old = self.connectedSession, old.owner != owner {
                    let wasPlaying = self.connectedSnapshot?.playing ?? old.snapshot.playing
                    var request = self.connectedSnapshot ?? old.snapshot
                    if !self.outputDevices.contains(where:{ $0.id == old.owner && $0.online }) {
                        request.playing = wasPlaying; request.handoff = nil; frozen = request
                    } else {
                        let checkpoint = request
                        let handoff = UUID().uuidString.lowercased()
                        request.handoff = handoff; request.playing = false
                        let freeze = MusicConnectedSession(owner:old.owner,command:UUID().uuidString.lowercased(),at:Date().timeIntervalSince1970 * 1000,snapshot:request)
                        try self.setConnection(["connect:session":.encoded(freeze)]); await self.sync()
                        let deadline = Date().addingTimeInterval(4)
                        while Date() < deadline {
                            guard !Task.isCancelled, self.generation == epoch else { return }
                            guard self.connectedSession?.command == freeze.command else { throw NovaSyncFailure.message("Playback changed during transfer. Choose the output again.") }
                            if var status = try? self.document.values["connect:status"]?.decoded(MusicConnectedSnapshot.self), status.valid, status.owner == old.owner, status.command == freeze.command, status.handoff == handoff, !status.playing {
                                status.playing = wasPlaying; status.handoff = nil; frozen = status; break
                            }
                            try await Task.sleep(for:.milliseconds(250)); await self.sync()
                        }
                        guard self.connectedSession?.command == freeze.command else { throw NovaSyncFailure.message("Playback changed during transfer. Choose the output again.") }
                        if frozen == nil { var recovery = checkpoint; recovery.playing = wasPlaying; recovery.handoff = nil; frozen = recovery }
                    }
                }
                guard self.error == nil else { throw NovaSyncFailure.message("Could not reach your devices. Check your connection.") }
                var next = frozen ?? change(self.connectedSession?.owner == self.deviceID && self.appliedCommand == self.connectedSession?.command ? self.localSnapshot() : self.connectedSnapshot ?? self.localSnapshot()); next.at = Date().timeIntervalSince1970 * 1000
                guard next.valid else { throw NovaSyncFailure.message("This queue cannot be played across devices.") }
                let session = MusicConnectedSession(owner:owner,command:UUID().uuidString.lowercased(),at:Date().timeIntervalSince1970 * 1000,snapshot:next)
                if let intentID, self.playbackIntent?.id == intentID { self.playbackIntent?.command = session.command }
                try self.setConnection(["connect:session":.encoded(session)])
                await self.sync()
                guard self.generation == epoch else { return }
                if self.error != nil { throw NovaSyncFailure.message("Playback change could not be sent. Check your connection.") }
                self.outputError = nil
            } catch {
                if let intentID, self.playbackIntent?.id == intentID { self.playbackIntent = nil; self.intentTimeout?.cancel(); self.store?.player.connectedPendingPlaying = nil }
                self.outputError = error.localizedDescription
            }
        }
    }
    func selectOutput(_ id: String) {
        guard id != connectedSession?.owner else { return }
        sendPlayback(output:id,transfer:true) { $0 }
    }
    func routePlay(_ song: YouTubeVideo, queue: [YouTubeVideo], shuffle: Bool?) -> Bool {
        guard user != nil, !applyingPlayback else { return false }
        let tracks = queue.contains(where:{ $0.id == song.id }) ? queue : [song]
        sendPlayback { current in MusicConnectedSnapshot(queue:tracks.map(MusicConnectedSong.init),index:tracks.firstIndex { $0.id == song.id } ?? 0,playing:true,shuffle:shuffle ?? current.shuffle,repeat:current.repeat) }
        return true
    }
    func routePlaylist(_ playlist: YouTubePlaylist,index: Int,shuffle: Bool?) -> Bool {
        guard user != nil, !applyingPlayback else { return false }
        store?.refreshSmartPlaylists()
        let playlist = playlist.smartRules == nil ? playlist : store?.playlist(playlist.id) ?? playlist
        if playlist.videos.isEmpty, let id = playlist.youtubePlaylistID {
            let epoch = generation
            Task { [weak self] in
                do { let tracks = try await YouTubeAPI.musicRankedSongs(id); guard let self, self.generation == epoch, !tracks.isEmpty else { return }; _ = self.routePlay(tracks[min(max(0,index),tracks.count - 1)],queue:tracks,shuffle:shuffle) }
                catch { self?.store?.musicActionError = error.localizedDescription }
            }
        } else if !playlist.videos.isEmpty {
            let index = shuffle == true ? playlist.videos.indices.randomElement() ?? 0 : min(max(0,index),playlist.videos.count - 1)
            _ = routePlay(playlist.videos[index],queue:playlist.videos,shuffle:shuffle)
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
        sendPlayback(intentID:intentID) { current in
            var next = current; next.position = current.advancedPosition(); next.positionIntent = "preserve"
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
            case .stop: next.queue = []; next.index = 0; next.position = 0; next.playing = false
            case .enqueue(let ids,let immediate):
                let songs = ids.compactMap { known[$0].map(MusicConnectedSong.init) }
                next.queue.insert(contentsOf:songs,at:immediate ? min(next.index + 1,next.queue.count) : next.queue.count)
            case .clear: next.queue = Array(next.queue.prefix(next.index + 1))
            case .remove(let offsets):
                for offset in offsets.sorted(by:>) { let index = next.index + 1 + offset; if next.queue.indices.contains(index) { next.queue.remove(at:index) } }
            case .move(let offsets,let destination):
                var tail = Array(next.queue.dropFirst(next.index + 1))
                if offsets.allSatisfy({ tail.indices.contains($0) }) && (0...tail.count).contains(destination) { tail.move(fromOffsets:offsets,toOffset:destination); next.queue = Array(next.queue.prefix(next.index + 1)) + tail }
            case .entry(let index): if next.queue.indices.contains(index) { next.positionIntent = "seek"; next.index = index; next.position = 0; next.playing = true }
            }
            return next
        }
        return true
    }
}

struct MusicOutputButton: View {
    @ObservedObject var account: MusicAccountSync
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Image(systemName:account.controlsRemoteOutput ? "hifispeaker.fill" : "hifispeaker").frame(width:36,height:44)
                .foregroundStyle(account.controlsRemoteOutput ? Color.green : Color.primary)
        }.accessibilityLabel("Output location").accessibilityValue(account.outputName)
        .sheet(isPresented:$showing) {
            NavigationStack {
                List {
                    Section("Playing on") {
                        if account.user == nil { Text("Sign in to the same Nova Music account on both devices to connect playback.") }
                        Button { account.selectOutput(account.deviceID) } label: {
                            HStack { Label("This device",systemImage:"iphone"); Spacer(); if account.outputID == account.deviceID || account.outputID == nil { Image(systemName:"checkmark").accessibilityLabel("Selected") } }
                        }.disabled(account.user == nil)
                        ForEach(account.outputDevices.filter { $0.id != account.deviceID }) { device in
                            Button { account.selectOutput(device.id) } label: {
                                HStack { Label(device.name,systemImage:"desktopcomputer"); Spacer(); if account.outputID == device.id { Image(systemName:"checkmark").accessibilityLabel("Selected") } }
                            }
                        }
                        if let id = account.outputID, id != account.deviceID, !account.outputDevices.contains(where:{ $0.id == id }) {
                            HStack { Text("\(account.outputName) · unavailable"); Spacer(); Image(systemName:"checkmark").accessibilityLabel("Selected") }.foregroundStyle(.secondary)
                        }
                        if account.user != nil && account.outputDevices.count < 2 { Text("Open Nova Music on your other device to see it here.").foregroundStyle(.secondary) }
                        if let error = account.outputError { Text(error).foregroundStyle(.red) }
                        Text("Current output: \(account.outputName)").font(.footnote)
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
