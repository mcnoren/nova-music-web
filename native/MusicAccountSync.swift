import Foundation
import SwiftUI
import Combine
import Security
import UIKit
import PhotosUI

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
        var request = URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue(key,forHTTPHeaderField:"apikey"); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let bearer = authenticated ? try await accessToken() : token
        if let bearer { request.setValue("Bearer \(bearer)",forHTTPHeaderField:"Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse, http.url?.host == url.host else { throw NovaSyncFailure.invalidResponse }
        let value = (try? JSONDecoder().decode(NovaSyncValue.self,from:data)) ?? .object([:])
        guard (200..<300).contains(http.statusCode) else { throw NovaSyncFailure.message(http.statusCode == 401 && authenticated ? "Your session expired. Sign in again to sync." : value["msg"]?.string ?? value["message"]?.string ?? value["error_description"]?.string ?? "Sync could not finish. Your library remains saved here.") }
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
            Text("Sync includes library metadata. Your profile picture syncs too. Imported audio, library artwork and playback settings remain on their original device.").font(.footnote).foregroundStyle(.secondary)
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
