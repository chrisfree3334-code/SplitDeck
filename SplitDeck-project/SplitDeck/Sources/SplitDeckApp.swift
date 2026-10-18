import SwiftUI
import WebKit
import LocalAuthentication
import Security
import UniformTypeIdentifiers
import EventKit
import EventKitUI
import NetworkExtension

@main
struct SplitDeckApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

extension View {
    @ViewBuilder func sdGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

func q(_ s: String) -> String {
    (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
}

enum Engines {
    static let names = ["DuckDuckGo", "Google", "Bing", "Brave", "Ecosia"]
    static let urls = ["DuckDuckGo": "https://duckduckgo.com/?q=", "Google": "https://www.google.com/search?q=",
                       "Bing": "https://www.bing.com/search?q=", "Brave": "https://search.brave.com/search?q=",
                       "Ecosia": "https://www.ecosia.org/search?q="]
    static let home = ["DuckDuckGo": "https://duckduckgo.com", "Google": "https://www.google.com",
                       "Bing": "https://www.bing.com", "Brave": "https://search.brave.com",
                       "Ecosia": "https://www.ecosia.org"]
    static var currentHome: String {
        home[UserDefaults.standard.string(forKey: "engine") ?? "DuckDuckGo"] ?? "https://duckduckgo.com"
    }
}

// MARK: Vault (Keychain, device-only, Face ID gated)

struct Login: Codable, Identifiable { var id = UUID(); var site: String; var user: String; var pass: String }
struct Card: Codable, Identifiable { var id = UUID(); var name: String; var number: String; var exp: String; var cvc: String }

enum Store {
    static func read<T: Decodable>(_ key: String, _ t: T.Type) -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    static func write<T: Encodable>(_ key: String, _ v: T) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class Vault: ObservableObject {
    @Published var logins: [Login] = Store.read("logins", [Login].self) ?? []
    @Published var cards: [Card] = Store.read("cards", [Card].self) ?? []
    @Published var unlocked = false

    func unlock() async {
        let ok = try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your saved logins and cards")
        unlocked = ok == true
    }
    func lock() { unlocked = false }
    func save() { Store.write("logins", logins); Store.write("cards", cards) }

    func match(host: String) -> [Login] {
        let h = host.replacingOccurrences(of: "www.", with: "")
        return logins.filter { l in
            let s = l.site.contains("://") ? l.site : "https://" + l.site
            let lh = (URL(string: s)?.host ?? "").replacingOccurrences(of: "www.", with: "")
            return !lh.isEmpty && (lh == h || h.hasSuffix("." + lh))
        }
    }

    func parseCSV(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], f = "", quoted = false
        let ch = Array(s); var i = 0
        while i < ch.count {
            let c = ch[i]
            if quoted {
                if c == "\"" { if i + 1 < ch.count && ch[i + 1] == "\"" { f.append("\""); i += 1 } else { quoted = false } }
                else { f.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(f); f = "" }
            else if c == "\n" || c == "\r\n" { row.append(f); rows.append(row); row = []; f = "" }
            else if c != "\r" { f.append(c) }
            i += 1
        }
        if !f.isEmpty || !row.isEmpty { row.append(f); rows.append(row) }
        return rows
    }

    func importCSV(_ s: String) -> Int {
        let rows = parseCSV(s)
        guard let h = rows.first?.map({ $0.lowercased() }) else { return 0 }
        func col(_ n: [String]) -> Int? { h.firstIndex { n.contains($0) } }
        guard let u = col(["url", "login_uri", "website"]),
              let n = col(["username", "login_username", "user"]),
              let p = col(["password", "login_password"]) else { return 0 }
        var added = 0
        for r in rows.dropFirst() where r.count > max(u, n, p) && !r[p].isEmpty {
            logins.append(Login(site: r[u], user: r[n], pass: r[p])); added += 1
        }
        save()
        return added
    }
}

// MARK: Blocking rules and page scripts

enum Rules {
    static let hosts = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "adservice.google.com", "connect.facebook.net", "scorecardresearch.com", "taboola.com", "outbrain.com",
        "criteo.com", "adnxs.com", "amazon-adsystem.com", "hotjar.com", "quantserve.com", "pubmatic.com",
        "rubiconproject.com", "openx.net", "moatads.com", "ads-twitter.com", "analytics.tiktok.com",
        "mathtag.com", "casalemedia.com", "smartadserver.com", "adsrvr.org", "bluekai.com", "demdex.net"]

    @MainActor
    static func compile() async -> WKContentRuleList? {
        var rules: [[String: Any]] = hosts.map { h -> [String: Any] in
            ["trigger": ["url-filter": "^https?://([^/]*\\.)?" + h.replacingOccurrences(of: ".", with: "\\."), "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"],
                      "action": ["type": "css-display-none",
                                 "selector": "#onetrust-consent-sdk,#CybotCookiebotDialog,.qc-cmp2-container,#didomi-host,#cookie-banner,.cookie-banner,.cc-window,#truste-consent-track"]])
        guard let d = try? JSONSerialization.data(withJSONObject: rules),
              let s = String(data: d, encoding: .utf8),
              let store = WKContentRuleListStore.default() else { return nil }
        return try? await store.compileContentRuleList(forIdentifier: "sd2", encodedContentRuleList: s)
    }

    static let decline = "(function(){var s=['#onetrust-reject-all-handler','#CybotCookiebotDialogBodyButtonDecline','#didomi-notice-disagree-button','.fc-cta-do-not-consent','button.cc-deny','[data-testid=reject-all]','[aria-label=\"Reject all\"]','.js-reject-cookies'];var n=0;var t=setInterval(function(){s.forEach(function(x){var b=document.querySelector(x);if(b)b.click()});if(++n>20)clearInterval(t)},500)})();"

    static let capture = "document.addEventListener('submit',function(e){var f=e.target;var p=f.querySelector('input[type=password]');if(!p||!p.value)return;var u=f.querySelector('input[type=email],input[type=text],input[autocomplete=username]');window.webkit.messageHandlers.cred.postMessage({site:location.origin,user:u?u.value:'',pass:p.value})},true);"

    static let raf = "(function(){var raf=window.requestAnimationFrame.bind(window);var last=0;window.requestAnimationFrame=function(cb){return raf(function ts(t){var f=window.__sdFps||0;if(f&&t-last<1000/f-2){raf(ts);return}last=t;cb(t)})}})();"

    static let popupKill = "(function(){document.querySelectorAll('*').forEach(function(e){var s=getComputedStyle(e);if((s.position==='fixed'||s.position==='sticky')&&(parseInt(s.zIndex)||0)>=100&&e.getBoundingClientRect().height>80){e.remove()}});document.documentElement.style.overflow='auto';if(document.body)document.body.style.overflow='auto'})();"
}

// MARK: - VPN Service (IKEv2 via NEVPNManager)

struct VPNServer: Identifiable, Codable, Hashable {
    var id: String { address }
    var provider: String
    var name: String
    var address: String
    var remoteID: String

    func hash(into hasher: inout Hasher) { hasher.combine(address) }
    static func == (lhs: VPNServer, rhs: VPNServer) -> Bool { lhs.address == rhs.address }
}

@MainActor
final class VPNService: ObservableObject {
    static let presets: [VPNServer] = [
        // hide.me (Audited, verified no-log, native free IKEv2 servers)
        VPNServer(provider: "hide.me", name: "hide.me – Netherlands (Free)", address: "free-nl.hide.me", remoteID: "hide.me"),
        VPNServer(provider: "hide.me", name: "hide.me – United States (Free)", address: "free-us.hide.me", remoteID: "hide.me"),
        VPNServer(provider: "hide.me", name: "hide.me – Germany (Free)", address: "free-de.hide.me", remoteID: "hide.me"),
        VPNServer(provider: "hide.me", name: "hide.me – Canada (Free)", address: "free-ca.hide.me", remoteID: "hide.me"),

        // Proton VPN (Swiss privacy, free endpoints)
        VPNServer(provider: "Proton VPN", name: "Proton – Netherlands (Free)", address: "nl-free-01.protonvpn.net", remoteID: "nl-free-01.protonvpn.net"),
        VPNServer(provider: "Proton VPN", name: "Proton – United States (Free)", address: "us-free-01.protonvpn.net", remoteID: "us-free-01.protonvpn.net"),
        VPNServer(provider: "Proton VPN", name: "Proton – Japan (Free)", address: "jp-free-01.protonvpn.net", remoteID: "jp-free-01.protonvpn.net"),
    ]

    @Published var status: NEVPNStatus = .disconnected
    @Published var errorMessage: String?
    @Published var selectedServer: VPNServer = presets[0]
    @Published var isConfigured: Bool = false

    private let manager = NEVPNManager.shared()

    init() {
        if let savedAddr = UserDefaults.standard.string(forKey: "vpn_server_address"),
           let match = Self.presets.first(where: { $0.address == savedAddr }) {
            selectedServer = match
        }

        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = self.manager.connection.status
            }
        }

        Task { await reloadConfiguration() }
    }

    func reloadConfiguration() async {
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                manager.loadFromPreferences { err in
                    if let err { c.resume(throwing: err) } else { c.resume() }
                }
            }
            status = manager.connection.status
            isConfigured = manager.protocolConfiguration != nil
        } catch {
            status = .invalid
            isConfigured = false
        }
    }

    var statusTitle: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return isConfigured ? "Disconnected" : "Not Configured"
        case .reasserting: return "Reconnecting…"
        case .invalid: return "Not Configured"
        @unknown default: return "Unknown"
        }
    }

    var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        case .disconnected: return isConfigured ? .secondary : .gray
        default: return .secondary
        }
    }

    func configure(server: VPNServer, username: String, password: String) async {
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                manager.loadFromPreferences { err in
                    if let err { c.resume(throwing: err) } else { c.resume() }
                }
            }

            guard let passwordRef = keychainSave(password) else {
                throw NSError(domain: "SplitDeckVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to securely store VPN password in Keychain."])
            }

            let proto = NEVPNProtocolIKEv2()
            proto.serverAddress = server.address
            proto.remoteIdentifier = server.remoteID
            proto.authenticationMethod = .none
            proto.useExtendedAuthentication = true
            proto.username = username
            proto.passwordReference = passwordRef

            // Standard cryptographic suites for maximum compatibility with hide.me, Proton & strongSwan
            proto.ikeSecurityAssociationParameters.encryptionAlgorithm = .algorithmAES256GCM
            proto.ikeSecurityAssociationParameters.integrityAlgorithm = .SHA256
            proto.ikeSecurityAssociationParameters.diffieHellmanGroup = .group14
            proto.ikeSecurityAssociationParameters.lifetimeMinutes = 1440

            proto.childSecurityAssociationParameters.encryptionAlgorithm = .algorithmAES256GCM
            proto.childSecurityAssociationParameters.integrityAlgorithm = .SHA256
            proto.childSecurityAssociationParameters.diffieHellmanGroup = .group14
            proto.childSecurityAssociationParameters.lifetimeMinutes = 1440

            proto.disconnectOnSleep = false
            proto.deadPeerDetectionRate = .medium

            manager.protocolConfiguration = proto
            manager.localizedDescription = "SplitDeck VPN (\(server.provider))"
            manager.isEnabled = true
            selectedServer = server

            UserDefaults.standard.set(server.address, forKey: "vpn_server_address")
            UserDefaults.standard.set(username, forKey: "vpn_saved_username")

            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                manager.saveToPreferences { err in
                    if let err { c.resume(throwing: err) } else { c.resume() }
                }
            }

            isConfigured = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect() async {
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                manager.loadFromPreferences { err in
                    if let err { c.resume(throwing: err) } else { c.resume() }
                }
            }
            try manager.connection.startVPNTunnel()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        manager.connection.stopVPNTunnel()
    }

    private func keychainSave(_ password: String) -> Data? {
        guard let data = password.data(using: .utf8) else { return nil }
        let acct = "SplitDeck_VPN_Key"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: acct
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecReturnPersistentRef as String] = true

        var ref: AnyObject?
        let status = SecItemAdd(add as CFDictionary, &ref)
        if status == errSecSuccess, let persistentRef = ref as? Data {
            return persistentRef
        }
        return nil
    }
}

// MARK: - VPN View

struct VPNView: View {
    @ObservedObject var vpn: VPNService
    @Environment(\.dismiss) private var dismiss

    @State private var username = UserDefaults.standard.string(forKey: "vpn_saved_username") ?? ""
    @State private var password = ""
    @State private var useCustom = false
    @State private var customServer = ""
    @State private var customRemoteID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection Status") {
                    HStack {
                        Circle().fill(vpn.statusColor).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vpn.statusTitle).font(.headline)
                            if vpn.status == .connected {
                                Text("Routing traffic via \(vpn.selectedServer.name)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if vpn.status == .connected {
                            Button("Disconnect") { vpn.disconnect() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        } else if vpn.status == .connecting || vpn.status == .reasserting || vpn.status == .disconnecting {
                            ProgressView()
                        } else if vpn.isConfigured {
                            Button("Connect") { Task { await vpn.connect() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }

                Section("Free Trusted Provider") {
                    Picker("Server", selection: $vpn.selectedServer) {
                        Section("hide.me (Audited No-Logs, Free IKEv2)") {
                            ForEach(VPNService.presets.filter { $0.provider == "hide.me" }) { s in
                                Text(s.name).tag(s)
                            }
                        }
                        Section("Proton VPN (Free Tier)") {
                            ForEach(VPNService.presets.filter { $0.provider == "Proton VPN" }) { s in
                                Text(s.name).tag(s)
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Toggle("Use custom IKEv2 server", isOn: $useCustom.animation())
                    if useCustom {
                        TextField("Server Hostname or IP", text: $customServer)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Remote ID", text: $customRemoteID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    TextField("VPN Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("VPN Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Credentials")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if vpn.selectedServer.provider == "hide.me" {
                            Text("• **hide.me Free**: Sign up free at hide.me (no credit card required). Enter your hide.me account username and password above.")
                        } else if vpn.selectedServer.provider == "Proton VPN" {
                            Text("• **Proton VPN**: Sign up free at protonvpn.com. Go to Account → Settings → OpenVPN / IKEv2 credentials and copy your generated credentials.")
                        } else {
                            Text("• Enter standard credentials for your self-hosted strongSwan or private IKEv2 server.")
                        }
                    }
                    .font(.caption)
                }

                Section {
                    Button {
                        let targetServer = useCustom
                            ? VPNServer(provider: "Custom", name: "Custom (\(customServer))", address: customServer, remoteID: customRemoteID.isEmpty ? customServer : customRemoteID)
                            : vpn.selectedServer

                        Task {
                            await vpn.configure(server: targetServer, username: username, password: password)
                            if vpn.errorMessage == nil {
                                await vpn.connect()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label(vpn.status == .connected ? "Update Configuration" : "Save & Connect", systemImage: "lock.shield")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || (useCustom && customServer.isEmpty))
                }

                if let err = vpn.errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("VPN Shield")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: One browser pane

final class Pane: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    let webView: WKWebView
    @Published var address: String
    @Published var collapsed = false
    @Published var hasLogin = false
    @Published var hasCard = false
    @Published var canBack = false
    @Published var canForward = false
    @Published var host = ""
    @Published var title = ""
    var onCredential: ((Login) -> Void)?
    static var fps = 0
    private var obs: NSKeyValueObservation?
    private var lastY: CGFloat = 0
    static let setJS = "function S(e,v){Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}))}"

    init(start: String) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        config.userContentController.addUserScript(WKUserScript(source: Rules.raf, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: Rules.decline, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: Rules.capture, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        webView = wv
        address = start
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
        config.userContentController.add(self, name: "cred")
        obs = wv.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            guard let self else { return }
            let y = sv.contentOffset.y
            let dy = y - self.lastY
            self.lastY = y
            if dy > 6 && y > 80 { if !self.collapsed { self.collapsed = true } }
            else if dy < -6 { if self.collapsed { self.collapsed = false } }
        }
        load(start)
    }

    func load(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let url: URL?
        if t.contains(" ") || !t.contains(".") {
            let s = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
            let name = UserDefaults.standard.string(forKey: "engine") ?? "DuckDuckGo"
            url = URL(string: (Engines.urls[name] ?? Engines.urls["DuckDuckGo"]!) + s)
        } else {
            if !t.lowercased().hasPrefix("http") { t = "https://" + t }
            url = URL(string: t)
        }
        if let url { webView.load(URLRequest(url: url)) }
    }

    func setDesktop(_ on: Bool) {
        webView.customUserAgent = on
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            : nil
        webView.reload()
    }

    func applyFPS() { webView.evaluateJavaScript("window.__sdFps=\(Pane.fps)") }

    func fill(login l: Login) {
        webView.evaluateJavaScript("(function(u,p){\(Pane.setJS)var w=document.querySelector('input[type=password]');if(!w)return;var f=w.form||document;var e=f.querySelector('input[type=email],input[type=text],input[autocomplete=username]');if(e)S(e,u);S(w,p)})(\(q(l.user)),\(q(l.pass)))")
    }

    func fill(card c: Card) {
        webView.evaluateJavaScript("(function(c){\(Pane.setJS)[['cc-number',c[0]],['cc-name',c[1]],['cc-exp',c[2]],['cc-csc',c[3]]].forEach(function(x){var e=document.querySelector('[autocomplete='+x[0]+']');if(e)S(e,x[1])})})([\(q(c.number)),\(q(c.name)),\(q(c.exp)),\(q(c.cvc))])")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: String], let p = d["pass"], !p.isEmpty else { return }
        onCredential?(Login(site: d["site"] ?? "", user: d["user"] ?? "", pass: p))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated,
           let u = navigationAction.request.url {
            webView.load(URLRequest(url: u))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__sdFps=\(Pane.fps)")
        canBack = webView.canGoBack
        canForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url { address = u.absoluteString; host = u.host ?? "" }
        title = webView.title ?? ""
        canBack = webView.canGoBack
        canForward = webView.canGoForward
        webView.evaluateJavaScript("((document.querySelector('input[type=password]')?1:0)+(document.querySelector('[autocomplete=cc-number]')?2:0))") { [weak self] r, _ in
            let v = (r as? Int) ?? 0
            self?.hasLogin = (v & 1) != 0
            self?.hasCard = (v & 2) != 0
        }
    }
}

struct WebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        attach(v)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { attach(v) }
    private func attach(_ v: UIView) {
        guard webView.superview !== v else { return }
        v.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = v.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.addSubview(webView)
    }
}

struct PaneView: View {
    @ObservedObject var pane: Pane
    var bottomGap: CGFloat
    var autofill: () -> Void
    var calendar: () -> Void
    var removePopups: () -> Void
    var settings: () -> Void
    var vpn: () -> Void
    var vpnOn: Bool
    @State private var desktop = false
    @FocusState private var focused: Bool

    private var mini: Bool { pane.collapsed && !focused }

    var body: some View {
        ZStack(alignment: .bottom) {
            WebHost(webView: pane.webView)
            bar
                .padding(.horizontal, 12)
                .padding(.bottom, focused ? 8 : (mini ? max(bottomGap - 22, 4) : bottomGap))
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: mini)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: focused)
        }
        .clipped()
    }

    private func roundButton(_ icon: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .sdGlass(Circle())
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    private func icon(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var bar: some View {
        if mini {
            Button { pane.collapsed = false } label: {
                Text(pane.host.isEmpty ? "Search" : pane.host.replacingOccurrences(of: "www.", with: ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
            .sdGlass(Capsule())
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
            HStack(spacing: 8) {
                if !focused { roundButton("chevron.left", pane.canBack) { pane.webView.goBack() } }
                HStack(spacing: 0) {
                    TextField("Search or enter site", text: $pane.address)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit { pane.load(pane.address); focused = false }
                    if !focused {
                        if pane.hasLogin { icon("key.fill") { autofill() } }
                        if pane.hasCard { icon("creditcard.fill") { autofill() } }
                        Menu {
                            Button { pane.webView.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                            Button { desktop.toggle(); pane.setDesktop(desktop) } label: {
                                Label(desktop ? "Mobile site" : "Desktop site", systemImage: desktop ? "iphone" : "desktopcomputer")
                            }
                            Button { removePopups() } label: { Label("Remove popups", systemImage: "xmark.rectangle") }
                            Button { calendar() } label: { Label("Add to Calendar", systemImage: "calendar.badge.plus") }
                            Divider()
                            Button { vpn() } label: { Label(vpnOn ? "VPN (on)" : "VPN", systemImage: vpnOn ? "lock.shield.fill" : "lock.shield") }
                            Button { settings() } label: { Label("Settings", systemImage: "gearshape") }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 40, height: 44)
                                .contentShape(Rectangle())
                        }
                    } else {
                        icon("xmark.circle.fill") { focused = false }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .frame(height: 48)
                .sdGlass(Capsule())
                if !focused { roundButton("chevron.right", pane.canForward) { pane.webView.goForward() } }
            }
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }
}

// MARK: Calendar

struct EventEditor: UIViewControllerRepresentable {
    let title: String
    let url: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.notes = url
        ev.startDate = Date().addingTimeInterval(3600)
        ev.endDate = ev.startDate.addingTimeInterval(3600)
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = ev
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: { dismiss() }) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { done() }
    }
}

// MARK: Settings

struct SettingsView: View {
    @AppStorage("engine") private var engine = "DuckDuckGo"
    @AppStorage("block") private var blockOn = true
    @AppStorage("battery") private var battery = 0
    var openVault: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Default search engine") {
                    Picker("Search with", selection: $engine) {
                        ForEach(Engines.names, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Privacy") {
                    Toggle("Block ads and trackers", isOn: $blockOn)
                }
                Section {
                    Picker("Mode", selection: $battery) {
                        Text("Off").tag(0)
                        Text("Auto (follows Low Power Mode)").tag(1)
                        Text("Saver (60 fps animations)").tag(2)
                        Text("Max saver (30 fps animations)").tag(3)
                    }
                } header: { Text("Battery saver") } footer: {
                    Text("This slows page animations. iOS controls scrolling smoothness, so for that also use Low Power Mode or Settings > Accessibility > Motion > Limit Frame Rate.")
                }
                Section { Button("Passwords and cards") { openVault() } }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

// MARK: Vault screen

struct VaultView: View {
    @ObservedObject var vault: Vault
    var fill: (Login?, Card?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var msg = ""
    @State private var ls = ""
    @State private var lu = ""
    @State private var lp = ""
    @State private var cn = ""
    @State private var cnum = ""
    @State private var cexp = ""
    @State private var ccvc = ""

    var body: some View {
        NavigationStack {
            Group {
                if vault.unlocked { content }
                else { Button("Unlock with Face ID") { Task { await vault.unlock() } }.task { await vault.unlock() } }
            }
            .navigationTitle("Passwords and cards")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private var content: some View {
        List {
            Section("Logins (tap to fill)") {
                ForEach(vault.logins) { l in
                    Button { fill(l, nil); dismiss() } label: {
                        VStack(alignment: .leading) {
                            Text(l.site).lineLimit(1)
                            Text(l.user).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { vault.logins.remove(atOffsets: $0); vault.save() }
                Button("Import CSV") { importing = true }
                if !msg.isEmpty { Text(msg).font(.caption) }
            }
            Section("Add a login") {
                TextField("Website, e.g. example.com", text: $ls)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Username or email", text: $lu)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $lp)
                Button("Save login") {
                    guard !ls.isEmpty, !lp.isEmpty else { return }
                    vault.logins.append(Login(site: ls, user: lu, pass: lp))
                    vault.save()
                    ls = ""; lu = ""; lp = ""
                }
            }
            Section("Cards (tap to fill)") {
                ForEach(vault.cards) { c in
                    Button { fill(nil, c); dismiss() } label: { Text("\(c.name) ending \(c.number.suffix(4))") }
                }.onDelete { vault.cards.remove(atOffsets: $0); vault.save() }
                TextField("Name on card", text: $cn)
                TextField("Card number", text: $cnum).keyboardType(.numberPad)
                TextField("MM/YY", text: $cexp)
                SecureField("CVC", text: $ccvc).keyboardType(.numberPad)
                Button("Save card") {
                    guard !cnum.isEmpty else { return }
                    vault.cards.append(Card(name: cn, number: cnum, exp: cexp, cvc: ccvc))
                    vault.save()
                    cn = ""; cnum = ""; cexp = ""; ccvc = ""
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { r in
            if case .success(let url) = r, url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let t = try? String(contentsOf: url, encoding: .utf8) {
                    msg = "Imported \(vault.importCSV(t)) logins. Delete the CSV file now."
                }
            }
        }
    }
}

// MARK: Main screen

enum Sheet: Identifiable {
    case vault, settings, calendar, vpn
    var id: Int {
        switch self {
        case .vault: return 0
        case .settings: return 1
        case .calendar: return 2
        case .vpn: return 3
        }
    }
}

struct ContentView: View {
    @StateObject private var first = Pane(start: Engines.currentHome)
    @StateObject private var second = Pane(start: "https://en.wikipedia.org")
    @StateObject private var vault = Vault()
    @StateObject private var vpnService = VPNService()
    @Environment(\.scenePhase) private var phase
    @AppStorage("block") private var blockOn = true
    @AppStorage("battery") private var battery = 0
    @AppStorage("engine") private var engine = "DuckDuckGo"
    @State private var split: CGFloat = 0.5
    @State private var splitOn = false
    @State private var showSecond = false
    @State private var rules: WKContentRuleList?
    @State private var sheet: Sheet?
    @State private var pending: Login?
    @State private var calTitle = ""
    @State private var calURL = ""
    private let handle: CGFloat = 16

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground).ignoresSafeArea()
            deck.ignoresSafeArea(.container)
            topBar
        }
        .sheet(item: $sheet) { s in sheetView(s) }
        .alert("Save password?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Save") { if let p = pending { vault.logins.append(p); vault.save() }; pending = nil }
            Button("Not now", role: .cancel) { pending = nil }
        } message: { Text(pending?.site ?? "") }
        .task {
            first.onCredential = { pending = $0 }
            second.onCredential = { pending = $0 }
            rules = await Rules.compile()
            apply()
            applyFPS()
        }
        .onChange(of: blockOn) { _, _ in apply() }
        .onChange(of: battery) { _, _ in applyFPS() }
        .onChange(of: engine) { _, _ in loadHome() }
        .onChange(of: phase) { _, p in if p != .active { vault.lock() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in applyFPS() }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 0) {
                if !splitOn {
                    Button { withAnimation(.snappy) { showSecond.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.on.square")
                            Text(showSecond ? "2" : "1").monospacedDigit()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(height: 36)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                }
                Button { withAnimation(.snappy) { splitOn.toggle() } } label: {
                    Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 4)
            .sdGlass(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private var deck: some View {
        GeometryReader { geo in
            let horizontal = geo.size.width > geo.size.height
            let total = horizontal ? geo.size.width : geo.size.height
            let firstSize = (total - handle) * split
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            if splitOn {
                layout {
                    pane(first, gap: horizontal ? 30 : 12)
                        .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                    divider(horizontal: horizontal, total: total)
                    pane(second, gap: 30)
                }
                .coordinateSpace(.named("deck"))
            } else {
                pane(showSecond ? second : first, gap: 30)
            }
        }
    }

    private func pane(_ p: Pane, gap: CGFloat) -> some View {
        PaneView(pane: p,
                 bottomGap: gap,
                 autofill: { autofill(p) },
                 calendar: { calTitle = p.title.isEmpty ? p.host : p.title; calURL = p.address; sheet = .calendar },
                 removePopups: { p.webView.evaluateJavaScript(Rules.popupKill) },
                 settings: { sheet = .settings },
                 vpn: { sheet = .vpn },
                 vpnOn: vpnService.status == .connected)
            .id(p.id)
    }

    @ViewBuilder private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .vault: VaultView(vault: vault, fill: fill)
        case .settings: SettingsView(openVault: { sheet = .vault })
        case .calendar: EventEditor(title: calTitle, url: calURL).ignoresSafeArea()
        case .vpn: VPNView(vpn: vpnService)
        }
    }

    private func autofill(_ p: Pane) {
        Task {
            if !vault.unlocked { await vault.unlock() }
            guard vault.unlocked else { return }
            if p.hasLogin, let l = vault.match(host: p.host).first { p.fill(login: l) }
            else if p.hasCard, let c = vault.cards.first { p.fill(card: c) }
            else { sheet = .vault }
        }
    }

    private func apply() {
        for p in [first, second] {
            let u = p.webView.configuration.userContentController
            u.removeAllContentRuleLists()
            if blockOn, let r = rules { u.add(r) }
            p.webView.reload()
        }
    }

    private func loadHome() {
        let url = Engines.home[engine] ?? "https://duckduckgo.com"
        first.load(url)
        second.load(url)
    }

    private func applyFPS() {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if battery == 3 { Pane.fps = 30 }
        else if battery == 2 || (battery == 1 && low) { Pane.fps = 60 }
        else { Pane.fps = 0 }
        first.applyFPS()
        second.applyFPS()
    }

    private func fill(_ l: Login?, _ c: Card?) {
        let panes = splitOn ? [first, second] : [showSecond ? second : first]
        for p in panes {
            if let l { p.fill(login: l) }
            if let c { p.fill(card: c) }
        }
    }

    private func divider(horizontal: Bool, total: CGFloat) -> some View {
        ZStack {
            Color(.systemBackground)
            Capsule().fill(Color.secondary.opacity(0.6))
                .frame(width: horizontal ? 4 : 40, height: horizontal ? 40 : 4)
        }
        .frame(width: horizontal ? handle : nil, height: horizontal ? nil : handle)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .named("deck"))
                .onChanged { v in
                    let pos = horizontal ? v.location.x : v.location.y
                    split = min(0.8, max(0.2, (pos - handle / 2) / (total - handle)))
                }
        )
        .onTapGesture(count: 2) { split = 0.5 }
    }
}
