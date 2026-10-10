import AppKit
import WebKit
import Security

private let musicURL = URL(string: "https://mcnoren.github.io/nova-music-web/")!
private let authKey = "nova-music-auth-session-v1"

private enum Credentials {
    private static let queue = DispatchQueue(label:"com.nova.music.mac.credentials",qos:.userInitiated)
    static func read() async -> String? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning:readItem()) } }
    }
    static func save(_ value: String?) async -> Bool {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning:saveItem(value)) } }
    }
    static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.nova.music.mac.account",kSecAttrAccount as String:"session"] }
    private static func readItem() -> String? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    private static func saveItem(_ value: String?) -> Bool {
        guard let value else { let status = SecItemDelete(query as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound }
        guard value.utf8.count < 256_000, let data = value.data(using:.utf8),
              let session = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              session["access_token"] is String, session["refresh_token"] is String else { return false }
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary,nil) == errSecSuccess
    }
}

@MainActor
final class MusicApplication: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private var loading: NSProgressIndicator!
    private var message: NSTextField!
    private var retry: NSButton!
    private var lyricsEnteredFullscreen = false
    private var rulesInstalled = false
    private var setupTask: Task<Void,Never>?
    private let playbackActivity = PlaybackActivity()
    private let nativeAudio = NativeMusicAudio()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = Bundle.main.url(forResource:"icon-512",withExtension:"png") { NSApp.applicationIconImage = NSImage(contentsOf:icon) }
        makeMenus()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.add(self,name:"novaDesktop")
        installScripts(config,session:nil)
        web = WKWebView(frame:.zero,configuration:config)
        web.navigationDelegate = self; web.uiDelegate = self
        nativeAudio.remoteAction = { [weak self] value in self?.command(value) }
        nativeAudio.emit = { [weak self] value in
            guard let self, let data = try? JSONSerialization.data(withJSONObject:value),let json = String(data:data,encoding:.utf8) else { return }
            self.web.evaluateJavaScript("window.dispatchEvent(new CustomEvent('nova-native-audio',{detail:\(json)}))",completionHandler:nil)
        }
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 NovaMusicMac/1.0"
        web.translatesAutoresizingMaskIntoConstraints = false
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Nova Music"; window.minSize = NSSize(width:760,height:540)
        window.setFrameAutosaveName("NovaMusicWindow"); window.center(); window.delegate = self
        window.contentView?.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),web.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),web.topAnchor.constraint(equalTo:window.contentView!.topAnchor),web.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
        loading = NSProgressIndicator(); loading.style = .spinning; loading.translatesAutoresizingMaskIntoConstraints = false
        message = NSTextField(labelWithString:"Opening Nova Music…"); message.textColor = .secondaryLabelColor; message.translatesAutoresizingMaskIntoConstraints = false
        retry = NSButton(title:"Try again",target:self,action:#selector(reload)); retry.translatesAutoresizingMaskIntoConstraints = false; retry.isHidden = true
        for view in [loading!,message!,retry!] as [NSView] { window.contentView?.addSubview(view) }
        NSLayoutConstraint.activate([loading.centerXAnchor.constraint(equalTo:window.contentView!.centerXAnchor),loading.centerYAnchor.constraint(equalTo:window.contentView!.centerYAnchor,constant:-28),message.centerXAnchor.constraint(equalTo:loading.centerXAnchor),message.topAnchor.constraint(equalTo:loading.bottomAnchor,constant:16),retry.centerXAnchor.constraint(equalTo:loading.centerXAnchor),retry.topAnchor.constraint(equalTo:message.bottomAnchor,constant:16)])
        loading.startAnimation(nil)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        setupTask = Task {
            // Await compilation so the first playback request is filtered too.
            guard let rules = await HDYouTubeAdFilter.rules() else {
                showError("Ad protection could not start. Try again before playing music."); return
            }
            let savedSession = await Credentials.read()
            guard !Task.isCancelled else { return }
            installScripts(config,session:savedSession)
            config.userContentController.add(rules); rulesInstalled = true
            web.load(URLRequest(url:musicURL,cachePolicy:.reloadRevalidatingCacheData))
        }
    }
    private func installScripts(_ config: WKWebViewConfiguration,session: String?) {
        config.userContentController.removeAllUserScripts()
        // Inject in YouTube frames before their player responses are consumed.
        let filter = "if (/(^|\\.)youtube(?:-nocookie)?\\.com$/.test(location.hostname)) {\n" + HDYouTubeAdFilter.script + "\n}"
        config.userContentController.addUserScript(WKUserScript(source:filter,injectionTime:.atDocumentStart,forMainFrameOnly:false))
        var bridge = """
        if(location.origin==='https://mcnoren.github.io' && location.pathname.startsWith('/nova-music-web/')) {
          window.novaDesktop=Object.freeze({nativeAudio:true,post:message=>window.webkit.messageHandlers.novaDesktop.postMessage(message)});
        """
        if let saved = session, let data = try? JSONSerialization.data(withJSONObject:[saved]), let json = String(data:data,encoding:.utf8) {
            bridge += "if(!sessionStorage.getItem('\(authKey)'))sessionStorage.setItem('\(authKey)',\(json)[0]);"
        }
        bridge += "}"
        config.userContentController.addUserScript(WKUserScript(source:bridge,injectionTime:.atDocumentStart,forMainFrameOnly:true))
    }
    private func trusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == musicURL.host && url.port == nil && url.path.hasPrefix(musicURL.path)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, trusted(message.frameInfo.request.url), let value = message.body as? [String:Any], let type = value["type"] as? String else { return }
        if type == "audio" { nativeAudio.handle(value)
        } else if type == "session" {
            let session = value["value"] as? String
            Task {
                if await Credentials.save(session) { installScripts(web.configuration,session:session) } else {
                    let alert = NSAlert(); alert.messageText = "Your sign-in could not be saved"; alert.informativeText = "Music can still play. You may need to sign in again after closing the app."; _ = await alert.beginSheetModal(for:window)
                }
            }
        } else if type == "playback", let playing = value["playing"] as? Bool {
            playbackActivity.setPlaying(playing)
        } else if type == "lyricsFullscreen", let enabled = value["enabled"] as? Bool {
            if enabled && !window.styleMask.contains(.fullScreen) { lyricsEnteredFullscreen = true; window.toggleFullScreen(nil) }
            else if !enabled && lyricsEnteredFullscreen && window.styleMask.contains(.fullScreen) { lyricsEnteredFullscreen = false; window.toggleFullScreen(nil) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        if trusted(action.request.url) { decisionHandler(.allow) }
        else { if let url = action.request.url, ["https","http"].contains(url.scheme) { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["https","http"].contains(url.scheme) { NSWorkspace.shared.open(url) }; return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage text: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = text; alert.beginSheetModal(for:window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage text: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = text; alert.addButton(withTitle:"Continue"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard trusted(frame.request.url) else { completionHandler(nil); return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for:window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
    func applicationWillTerminate(_ notification: Notification) { nativeAudio.stop();playbackActivity.setPlaying(false) }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { nativeAudio.stop();playbackActivity.setPlaying(false) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.stopAnimation(nil); loading.isHidden = true; message.isHidden = true; retry.isHidden = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { showError("Nova Music could not connect. Check your connection and try again.") } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { nativeAudio.stop();playbackActivity.setPlaying(false); showError("The music window stopped. Reload to continue.") }
    private func showError(_ text: String) { loading.stopAnimation(nil); loading.isHidden = true; message.stringValue = text; message.isHidden = false; retry.isHidden = false }
    @objc private func reload() {
        if rulesInstalled { web.reloadFromOrigin() }
        else { setupTask = Task { if let rules = await HDYouTubeAdFilter.rules() { web.configuration.userContentController.add(rules); rulesInstalled = true; web.load(URLRequest(url:musicURL)) } else { showError("Ad protection could not start. Try again.") } } }
    }
    @objc private func home() { command("home") }
    @objc private func search() { command("search") }
    @objc private func lyrics() { command("lyrics") }
    @objc private func output() { command("output") }
    @objc private func play() { command("play") }
    private func command(_ value: String) { web.evaluateJavaScript("window.dispatchEvent(new CustomEvent('nova-desktop-command',{detail:'\(value)'}))",completionHandler:nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func makeMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu(); appMenu.addItem(withTitle:"About Nova Music",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:""); appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Hide Nova Music",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h"); appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Nova Music",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenu(title:"Edit")
        for (title,selector,key) in [("Undo",Selector(("undo:")),"z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:selector,keyEquivalent:key) }
        let editItem = NSMenuItem(title:"Edit",action:nil,keyEquivalent:""); editItem.submenu = edit; menu.addItem(editItem)
        let view = NSMenu(title:"View")
        for (title,selector,key) in [("Home",#selector(home),"1"),("Search",#selector(search),"f"),("Full Screen Lyrics",#selector(lyrics),"l"),("Output Location",#selector(output),"d"),("Reload",#selector(reload),"r")] { let item = view.addItem(withTitle:title,action:selector,keyEquivalent:key); item.target = self }
        view.addItem(.separator()); view.addItem(withTitle:"Enter Full Screen",action:#selector(NSWindow.toggleFullScreen(_:)),keyEquivalent:"f").keyEquivalentModifierMask = [.command,.control]
        let viewItem = NSMenuItem(title:"View",action:nil,keyEquivalent:""); viewItem.submenu = view; menu.addItem(viewItem)
        NSApp.mainMenu = menu
    }
}

// The application retains its delegate for its entire event loop.
@main
struct NovaMusicMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MusicApplication()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
