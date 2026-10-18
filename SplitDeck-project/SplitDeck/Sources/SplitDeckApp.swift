import SwiftUI
import WebKit
import LocalAuthentication
import Security
import UniformTypeIdentifiers
import EventKit
import EventKitUI
import NetworkExtension
import PhotosUI

@main
struct SplitDeckApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

// Colour for bar icons and text when "Adapt to Page" is off.
enum TextColors {
    static let names = ["System", "White", "Black", "Blue", "Orange", "Mint", "Pink"]

    static func color(_ n: String) -> Color? {
        switch n {
        case "White": return .white
        case "Black": return .black
        case "Blue": return Color(red: 0.04, green: 0.52, blue: 1.0)
        case "Orange": return Color(red: 1.0, green: 0.58, blue: 0.0)
        case "Mint": return Color(red: 0.39, green: 0.9, blue: 0.75)
        case "Pink": return Color(red: 1.0, green: 0.5, blue: 0.72)
        default: return nil
        }
    }

    // Light text sits on a dark surface and vice versa; nil = follow the phone's light/dark mode.
    static func isLight(_ n: String) -> Bool? {
        switch n {
        case "White", "Mint", "Pink": return true
        case "Black": return false
        default: return nil
        }
    }

    static func ink(adaptive: Bool, name: String) -> AnyShapeStyle {
        if !adaptive, let c = color(name) { return AnyShapeStyle(c) }
        return AnyShapeStyle(.primary)
    }
}

enum BarColors {
    static let names = ["System", "White", "Black", "Graphite", "Blue", "Green", "Purple", "Orange"]

    static func color(_ n: String, scheme: ColorScheme) -> Color {
        switch n {
        case "White": return .white
        case "Black": return .black
        case "Graphite": return Color(red: 0.23, green: 0.24, blue: 0.27)
        case "Blue": return Color(red: 0.0, green: 0.38, blue: 0.85)
        case "Green": return Color(red: 0.13, green: 0.52, blue: 0.32)
        case "Purple": return Color(red: 0.43, green: 0.29, blue: 0.78)
        case "Orange": return Color(red: 0.90, green: 0.43, blue: 0.10)
        default: return scheme == .dark ? Color(white: 0.16) : Color(white: 0.97)
        }
    }

    static func isDark(_ n: String, scheme: ColorScheme) -> Bool {
        switch n {
        case "White": return false
        case "System": return scheme == .dark
        default: return true
        }
    }

    static func swatch(_ n: String) -> Color { n == "System" ? Color(.systemGray3) : color(n, scheme: .light) }
}

// Bar surface: Liquid Glass (tinted towards the page colour for readability) or a solid colour.
struct SDSurface: ViewModifier {
    let shape: AnyShape
    let dark: Bool?
    @AppStorage("barStyle") private var style = 0
    @AppStorage("barColor") private var colorName = "System"
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder func body(content: Content) -> some View {
        if style == 1 {
            content
                .environment(\.colorScheme, BarColors.isDark(colorName, scheme: scheme) ? .dark : .light)
                .background(BarColors.color(colorName, scheme: scheme), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        } else {
            let tint: Color = dark.map { $0 ? Color.black.opacity(0.42) : Color.white.opacity(0.62) }
                ?? Color(.systemBackground).opacity(0.5)
            if #available(iOS 26.0, *) {
                content.glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
            } else {
                content.background(shape.fill(tint)).background(.regularMaterial, in: shape)
            }
        }
    }
}

extension View {
    func sdGlass<S: Shape>(_ shape: S, dark: Bool? = nil) -> some View {
        modifier(SDSurface(shape: AnyShape(shape), dark: dark))
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

    // Same site and username: update the password; otherwise add a new login.
    func upsert(_ l: Login) {
        let h = Sites.clean(l.site)
        if let i = logins.firstIndex(where: { Sites.clean($0.site) == h && $0.user == l.user }) {
            logins[i].pass = l.pass
        } else {
            logins.append(l)
        }
        save()
    }

    func update(_ l: Login) {
        if let i = logins.firstIndex(where: { $0.id == l.id }) { logins[i] = l } else { logins.append(l) }
        save()
    }

    func deleteLogin(_ id: UUID) { logins.removeAll { $0.id == id }; save() }
    func deleteCard(_ id: UUID) { cards.removeAll { $0.id == id }; save() }

    var reusedPasswords: Set<String> {
        var counts: [String: Int] = [:]
        for l in logins { counts[l.pass, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

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
        // YouTube serves ads from its own domain, so these are matched by path instead of by host.
        for path in ["youtube\\.com/api/stats/ads", "youtube\\.com/pagead/", "youtube\\.com/ptracking",
                     "youtube\\.com/get_midroll_", "youtube\\.com/api/stats/qoe\\?.*adformat",
                     "youtube\\.com/youtubei/v1/log_event"] {
            rules.append(["trigger": ["url-filter": path], "action": ["type": "block"]])
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

    // Runs before YouTube's own code: strips ad data from the player's settings, hides ad slots,
    // and as a last resort mutes and skips any ad that still starts.
    static let youtube = #"""
    (function () {
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname) || window.__sdYT) return;
      window.__sdYT = true;
      var KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams', 'adBreakParams'];
      function prune(o, depth) {
        if (!o || typeof o !== 'object' || depth > 4) return o;
        if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) prune(o[i], depth + 1); return o; }
        for (var k = 0; k < KEYS.length; k++) { if (KEYS[k] in o) { try { delete o[KEYS[k]]; } catch (e) {} } }
        if (o.playerResponse) prune(o.playerResponse, depth + 1);
        if (o.response) prune(o.response, depth + 1);
        if (o.data) prune(o.data, depth + 1);
        return o;
      }
      var parse = JSON.parse;
      JSON.parse = function () { var r = parse.apply(this, arguments); try { prune(r, 0); } catch (e) {} return r; };
      var json = Response.prototype.json;
      Response.prototype.json = function () {
        return json.apply(this, arguments).then(function (d) { try { prune(d, 0); } catch (e) {} return d; });
      };
      var initial;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true,
          get: function () { return initial; },
          set: function (v) { initial = prune(v, 0); }
        });
      } catch (e) {}
      var css = 'ytd-ad-slot-renderer,ytd-in-feed-ad-layout-renderer,ytd-promoted-sparkles-web-renderer,' +
        'ytd-promoted-video-renderer,ytd-display-ad-renderer,ytd-companion-slot-renderer,' +
        'ytd-action-companion-ad-renderer,ytd-banner-promo-renderer,ytd-statement-banner-renderer,' +
        'ytd-player-legacy-desktop-watch-ads-renderer,#masthead-ad,#player-ads,' +
        'ytm-promoted-sparkles-web-renderer,ytm-promoted-sparkles-text-search-renderer,ytm-companion-ad-renderer,' +
        'ytm-companion-slot,ad-slot-renderer,ytm-ad-slot-renderer,ytm-in-feed-ad-layout-renderer,' +
        'ytm-promoted-video-renderer,ytm-paid-content-overlay-renderer,.ytp-ad-overlay-container,' +
        '.ytp-ad-message-container,.ytp-featured-product,' +
        'ytm-rich-item-renderer:has(ad-slot-renderer),ytm-item-section-renderer:has(ytm-ad-slot-renderer),' +
        'ytd-rich-item-renderer:has(ytd-ad-slot-renderer){display:none!important}';
      var style = document.createElement('style');
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
      setInterval(function () {
        var v = document.querySelector('video');
        var ad = document.querySelector('.ad-showing, .ad-interrupting');
        if (v && ad) {
          if (!v.__sdAd) { v.__sdAd = true; v.__sdMuted = v.muted; }
          v.muted = true;
          v.playbackRate = 16;
          if (isFinite(v.duration) && v.duration > 0 && v.currentTime < v.duration - 0.2) {
            try { v.currentTime = v.duration - 0.1; } catch (e) {}
          }
        } else if (v && v.__sdAd) {
          v.__sdAd = false;
          v.muted = v.__sdMuted;
          v.playbackRate = 1;
        }
        var skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, ' +
          '.ytm-skip-ad-button, .ytp-ad-skip-button-container button, button[class*="skip-ad"]');
        if (skip) skip.click();
      }, 250);
    })();
    """#

    static let raf = "(function(){var raf=window.requestAnimationFrame.bind(window);var last=0;window.requestAnimationFrame=function(cb){return raf(function ts(t){var f=window.__sdFps||0;if(f&&t-last<1000/f-2){raf(ts);return}last=t;cb(t)})}})();"

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

final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

final class Pane: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id: UUID
    let isPrivate: Bool
    let webView: WKWebView
    @Published var address = ""
    @Published var collapsed = false
    @Published var hasLogin = false
    @Published var hasCard = false
    @Published var canBack = false
    @Published var canForward = false
    @Published var host = ""
    @Published var title = ""
    @Published var isHome = true
    @Published var pageDark: Bool? = nil
    @Published var topDark: Bool? = nil
    @Published var bottomColor: Color? = nil
    @Published var blockedCount = 0
    private var bottomRGB: [Int] = []
    private var appliedRules: [String]?
    @Published var hiding = false
    @Published var hiddenCount = 0
    @Published var canUndoHide = false
    private var lastHidden: String?
    private var hiddenSels: [String] = []
    @Published var offerFill = false
    var onLoginField: (() -> Void)?
    var onPageLoaded: ((URL, String) -> Void)?
    var onSearch: ((String) -> Void)?
    var editing = false
    var onCredential: ((Login) -> Void)?
    var onVisit: ((String) -> Void)?
    var onChange: (() -> Void)?
    static var fps = 0
    static var ruleProvider: ((String) -> [WKContentRuleList])?
    static var youtubeProvider: ((String) -> Bool)?
    @Published var loading = false
    private var loadObs: NSKeyValueObservation?

    static func installScripts(_ u: WKUserContentController, youtube: Bool) {
        u.removeAllUserScripts()
        u.addUserScript(WKUserScript(source: Rules.raf, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if youtube {
            u.addUserScript(WKUserScript(source: Rules.youtube, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        u.addUserScript(WKUserScript(source: Rules.decline, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        u.addUserScript(WKUserScript(source: Rules.capture, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }
    static var onBlocked: (() -> Void)?
    private var obs: NSKeyValueObservation?
    private var lastY: CGFloat = 0
    private var scrollRun: CGFloat = 0
    private var tintWork: DispatchWorkItem?
    static let setJS = "function S(e,v){Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}))}"
    // Safari-style "Hide Distracting Items": tap an element to fade it out and remember it for this site.
    static let hideStartJS = "(function(){if(window.__sdHiding)return;window.__sdHiding=true;var cur=null;function sel(e){var p=[];while(e&&e.nodeType===1&&e!==document.body&&e!==document.documentElement){if(e.id&&!/\\d{3,}/.test(e.id)){p.unshift('#'+CSS.escape(e.id));return p.join('>')}var i=1,x=e;while((x=x.previousElementSibling))if(x.tagName===e.tagName)i++;p.unshift(e.tagName.toLowerCase()+':nth-of-type('+i+')');e=e.parentElement}return 'body>'+p.join('>')}function pick(e){var r;while(e&&e!==document.body){r=e.getBoundingClientRect();if(r.width*r.height>2500)break;e=e.parentElement}if(!e||e===document.body||e===document.documentElement)return null;r=e.getBoundingClientRect();if(r.width>=innerWidth*0.98&&r.height>=innerHeight*0.9)return null;return e}function mark(e){if(cur){cur.style.outline=cur.__sdO||'';cur.style.outlineOffset=''}cur=e;if(e){e.__sdO=e.style.outline;e.style.outline='3px solid rgba(10,132,255,.9)';e.style.outlineOffset='-3px'}}window.__sdMark=mark;window.__sdDown=function(ev){mark(pick(ev.target))};window.__sdClick=function(ev){ev.preventDefault();ev.stopPropagation();ev.stopImmediatePropagation();var e=pick(ev.target);mark(null);if(!e)return;var s=sel(e);e.style.transition='opacity .25s ease,transform .25s ease';e.style.opacity='0';e.style.transform='scale(.94)';setTimeout(function(){e.style.setProperty('display','none','important')},260);window.webkit.messageHandlers.hide.postMessage(s)};document.addEventListener('pointerdown',window.__sdDown,true);document.addEventListener('click',window.__sdClick,true)})()"
    static let hideStopJS = "(function(){window.__sdHiding=false;if(window.__sdMark)window.__sdMark(null);document.removeEventListener('pointerdown',window.__sdDown,true);document.removeEventListener('click',window.__sdClick,true)})()"

    static let tintJS = "(function(){function C(c){var m=c&&c.match(/[\\d.]+/g);if(!m||m.length<3)return null;if(m.length>3&&+m[3]<0.5)return null;return [+m[0],+m[1],+m[2]]}function at(x,y){var e=document.elementFromPoint(x,y);while(e){var v=C(getComputedStyle(e).backgroundColor);if(v)return v;e=e.parentElement}return C(getComputedStyle(document.documentElement).backgroundColor)||(document.body&&C(getComputedStyle(document.body).backgroundColor))||[255,255,255]}var w=innerWidth/2;return at(w,3).concat(at(w,innerHeight-3))})()"

    init(id: UUID, start: String?, isPrivate: Bool = false) {
        self.id = id
        self.isPrivate = isPrivate
        let config = WKWebViewConfiguration()
        // Private tabs share one throwaway, memory-only store: no cookies, cache or site data reach the disk.
        config.websiteDataStore = isPrivate ? Tabs.privateStore : .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        Pane.installScripts(config.userContentController, youtube: false)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.keyboardDismissMode = .interactive
        wv.isOpaque = false
        webView = wv
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
        config.userContentController.add(WeakHandler(self), name: "cred")
        config.userContentController.add(WeakHandler(self), name: "hide")
        obs = wv.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            guard let self else { return }
            let y = sv.contentOffset.y
            let dy = y - self.lastY
            self.lastY = y
            // Only react to a deliberate scroll in one direction, so the bar doesn't flicker.
            if sv.isTracking || sv.isDecelerating {
                if (dy > 0) != (self.scrollRun > 0) { self.scrollRun = 0 }
                self.scrollRun += dy
                if self.scrollRun > 28 && y > 60 && !self.collapsed { self.collapsed = true }
                else if self.scrollRun < -28 && self.collapsed { self.collapsed = false }
            }
            if y <= 0 && self.collapsed { self.collapsed = false }
            self.scheduleTint()
        }
        loadObs = wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async { self?.loading = w.isLoading }
        }
        if let start, !start.isEmpty { load(start) }
    }

    var backEnabled: Bool { !isHome }
    var forwardEnabled: Bool { isHome ? webView.url != nil : canForward }

    func load(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let url: URL?
        if t.contains(" ") || !t.contains(".") {
            if !isPrivate { onSearch?(t) }
            let s = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
            let name = UserDefaults.standard.string(forKey: "engine") ?? "DuckDuckGo"
            url = URL(string: (Engines.urls[name] ?? Engines.urls["DuckDuckGo"]!) + s)
        } else {
            if !t.lowercased().hasPrefix("http") { t = "https://" + t }
            url = URL(string: t)
        }
        guard let url else { return }
        isHome = false
        collapsed = false
        webView.load(URLRequest(url: url))
    }

    func goHome() {
        if hiding { stopHiding() }
        offerFill = false
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){m.pause()})")
        isHome = true
        collapsed = false
        if !editing { address = "" }
        title = ""
        host = ""
        hasLogin = false
        hasCard = false
        onChange?()
    }

    func back() {
        guard !isHome else { return }
        if webView.canGoBack { webView.goBack() } else { goHome() }
    }

    func forward() {
        if isHome {
            guard webView.url != nil else { return }
            isHome = false
            refreshMeta()
            onChange?()
        } else {
            webView.goForward()
        }
    }

    func setDesktop(_ on: Bool) {
        webView.customUserAgent = on
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            : nil
        webView.reload()
    }

    func applyFPS() { webView.evaluateJavaScript("window.__sdFps=\(Pane.fps)") }

    func sleep() {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
    }

    func fill(login l: Login) {
        webView.evaluateJavaScript("(function(u,p){\(Pane.setJS)var w=document.querySelector('input[type=password]');if(!w)return;var f=w.form||document;var e=f.querySelector('input[type=email],input[type=text],input[autocomplete=username]');if(e)S(e,u);S(w,p)})(\(q(l.user)),\(q(l.pass)))")
    }

    func fill(card c: Card) {
        webView.evaluateJavaScript("(function(c){\(Pane.setJS)[['cc-number',c[0]],['cc-name',c[1]],['cc-exp',c[2]],['cc-csc',c[3]]].forEach(function(x){var e=document.querySelector('[autocomplete='+x[0]+']');if(e)S(e,x[1])})})([\(q(c.number)),\(q(c.name)),\(q(c.exp)),\(q(c.cvc))])")
    }

    func startHiding() {
        guard !isHome else { return }
        hiding = true
        canUndoHide = false
        lastHidden = nil
        webView.evaluateJavaScript(Pane.hideStartJS)
    }

    func stopHiding() {
        hiding = false
        canUndoHide = false
        lastHidden = nil
        webView.evaluateJavaScript(Pane.hideStopJS)
    }

    private func unhide(_ sel: String) {
        webView.evaluateJavaScript("document.querySelectorAll(\(q(sel))).forEach(function(e){e.style.removeProperty('display');e.style.opacity='';e.style.transform=''})")
    }

    func undoHide() {
        guard let last = lastHidden else { return }
        unhide(last)
        hiddenSels.removeAll { $0 == last }
        hiddenCount = hiddenSels.count
        lastHidden = nil
        canUndoHide = false
    }

    func showAllHidden() {
        hiddenSels.forEach { unhide($0) }
        hiddenSels = []
        hiddenCount = 0
    }

    private func refreshMeta() {
        if let u = webView.url {
            if !editing { address = u.absoluteString }
            host = u.host ?? ""
        }
        title = webView.title ?? ""
        canBack = webView.canGoBack
        canForward = webView.canGoForward
    }

    private func scheduleTint() {
        tintWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.detectTint() }
        tintWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func detectTint() {
        guard !isHome else { return }
        webView.evaluateJavaScript(Pane.tintJS) { [weak self] r, _ in
            guard let self, let a = r as? [NSNumber], a.count == 6 else { return }
            let v = a.map { Int($0.doubleValue.rounded()) }
            let lum = { (i: Int) in 0.299 * Double(v[i]) + 0.587 * Double(v[i + 1]) + 0.114 * Double(v[i + 2]) }
            let top = lum(0) < 128
            let bottom = lum(3) < 128
            if self.topDark != top { self.topDark = top }
            if self.pageDark != bottom { self.pageDark = bottom }
            let rgb = Array(v[3...5])
            if rgb != self.bottomRGB {
                self.bottomRGB = rgb
                self.bottomColor = Color(red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255)
            }
        }
    }

    // Puts the right block lists on this tab for a site. Returns true if they changed.
    @discardableResult
    func applyRules(host: String) -> Bool {
        let lists = Pane.ruleProvider?(host) ?? []
        let youtube = Pane.youtubeProvider?(host) ?? false
        let ids = lists.map { $0.identifier ?? "" } + (youtube ? ["youtube-script"] : [])
        guard ids != appliedRules else { return false }
        let u = webView.configuration.userContentController
        u.removeAllContentRuleLists()
        lists.forEach { u.add($0) }
        let hadYouTube = appliedRules?.contains("youtube-script") ?? false
        if appliedRules == nil || youtube != hadYouTube {
            Pane.installScripts(u, youtube: youtube)
        }
        appliedRules = ids
        return true
    }

    // WebKit reports each content-blocker action through this undocumented delegate callback.
    // It is only used to count blocked requests; if WebKit stops calling it, the count just stays at 0.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func contentRuleAction(_ webView: WKWebView, identifier: String?, action: AnyObject?, url: URL?) {
        guard let o = action as? NSObject, o.responds(to: NSSelectorFromString("blockedLoad")),
              (o.value(forKey: "blockedLoad") as? Bool) == true else { return }
        blockedCount += 1
        Pane.onBlocked?()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        blockedCount = 0
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "hide" {
            guard let sel = m.body as? String, !sel.isEmpty else { return }
            if !hiddenSels.contains(sel) { hiddenSels.append(sel) }
            hiddenCount = hiddenSels.count
            lastHidden = sel
            canUndoHide = true
            return
        }
        guard !isPrivate, let d = m.body as? [String: String], let p = d["pass"], !p.isEmpty else { return }
        onCredential?(Login(site: d["site"] ?? "", user: d["user"] ?? "", pass: p))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated,
           let u = navigationAction.request.url {
            webView.load(URLRequest(url: u))
        }
        return nil
    }

    // Keep web links in SplitDeck. Policy raw value 3 is WebKit's "allow without trying app link",
    // which stops universal links (YouTube, Amazon, etc.) jumping out to their apps.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if scheme == "http" || scheme == "https" {
            // Shields changed for this site: swap the block lists, then restart the load so they apply to it.
            if navigationAction.targetFrame?.isMainFrame ?? true, let host = url.host,
               ![WKNavigationType.backForward, .formSubmitted, .formResubmitted].contains(navigationAction.navigationType),
               applyRules(host: host) {
                decisionHandler(.cancel)
                let req = navigationAction.request
                DispatchQueue.main.async { webView.load(req) }
                return
            }
            decisionHandler(WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow)
            return
        }
        if ["about", "data", "blob", "javascript", "file"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        if ["tel", "mailto", "sms", "facetime"].contains(scheme), navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__sdFps=\(Pane.fps)")
        if hiding { hiding = false; canUndoHide = false }
        hiddenSels = []
        hiddenCount = 0
        lastHidden = nil
        offerFill = false
        refreshMeta()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshMeta()
        detectTint()
        if !host.isEmpty && !isPrivate {
            onVisit?(host)
            if let u = webView.url { onPageLoaded?(u, webView.title ?? "") }
        }
        onChange?()
        webView.evaluateJavaScript("((document.querySelector('input[type=password]')?1:0)+(document.querySelector('[autocomplete=cc-number]')?2:0))") { [weak self] r, _ in
            guard let self else { return }
            let v = (r as? Int) ?? 0
            self.hasLogin = (v & 1) != 0
            self.hasCard = (v & 2) != 0
            if self.hasLogin && !self.isHome { self.onLoginField?() }
        }
    }
}

// Hosts a web view. Only takes the web view if no other host owns it,
// so two hosts briefly on screen during an animation can't steal it back and forth.
final class HostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
    }
}

struct WebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .clear
        v.addSubview(webView)
        return v
    }
    func updateUIView(_ v: HostView, context: Context) {
        if webView.superview == nil {
            v.addSubview(webView)
            v.setNeedsLayout()
        }
    }
}

// MARK: Tabs

struct TabInfo: Identifiable, Codable {
    var id = UUID()
    var url = ""
    var title = ""
    var priv: Bool?
    var isPrivate: Bool { priv ?? false }
}

final class Tabs: ObservableObject {
    @Published var list: [TabInfo]
    @Published var left: UUID
    @Published var right: UUID
    @Published var split = false
    @Published var previous: UUID? = nil
    private var live: [UUID: Pane] = [:]
    private var used: [UUID: Date] = [:]
    var maxLive = 4
    var configure: ((Pane) -> Void)?

    // One shared private session; replaced with a fresh one when the last private tab closes.
    static var privateStore = WKWebsiteDataStore.nonPersistent()

    var privateCount: Int { list.filter(\.isPrivate).count }
    var normalCount: Int { list.count - privateCount }

    func closeAllPrivate() {
        for t in list where t.isPrivate { close(t.id) }
    }
    @Published var thumbs: [UUID: UIImage] = [:]

    static let thumbDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("thumbs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func thumbURL(_ id: UUID) -> URL { thumbDir.appendingPathComponent(id.uuidString + ".jpg") }

    // Small, downscaled page snapshot for the tab grid; also cached to disk for sleeping or restored tabs.
    func snapshot(_ p: Pane) {
        guard !p.isHome, p.webView.window != nil, p.webView.bounds.width > 0 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 220
        p.webView.takeSnapshot(with: cfg) { [weak self] img, _ in
            guard let self, let img else { return }
            let w: CGFloat = 220
            let h = min(img.size.height * w / img.size.width, w * 2)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 2
            let small = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
                img.draw(in: CGRect(x: 0, y: 0, width: w, height: img.size.height * w / img.size.width))
            }
            self.thumbs[p.id] = small
            guard !p.isPrivate else { return }   // private previews stay in memory only
            if let d = small.jpegData(compressionQuality: 0.7) { try? d.write(to: Tabs.thumbURL(p.id)) }
        }
    }

    func snapshotVisible() { visible.compactMap { live[$0] }.forEach { snapshot($0) } }

    func thumb(_ id: UUID) -> UIImage? {
        if let t = thumbs[id] { return t }
        guard let img = UIImage(contentsOfFile: Tabs.thumbURL(id).path) else { return nil }
        DispatchQueue.main.async { self.thumbs[id] = img }
        return img
    }

    private func dropThumb(_ id: UUID) {
        if thumbs[id] != nil { thumbs[id] = nil }
        try? FileManager.default.removeItem(at: Tabs.thumbURL(id))
    }

    init() {
        var saved: [TabInfo] = []
        if let d = UserDefaults.standard.data(forKey: "tabs"),
           let l = try? JSONDecoder().decode([TabInfo].self, from: d) { saved = l }
        if saved.isEmpty { saved = [TabInfo()] }
        var first = saved[0].id
        if let s = UserDefaults.standard.string(forKey: "leftTab"), let id = UUID(uuidString: s),
           saved.contains(where: { $0.id == id }) { first = id }
        list = saved
        left = first
        right = first
    }

    var visible: [UUID] { split ? [left, right] : [left] }
    var allLive: [Pane] { Array(live.values) }
    var canSwap: Bool { split || validPrevious != nil }
    func isLive(_ id: UUID) -> Bool { live[id] != nil }

    private var validPrevious: UUID? {
        guard let p = previous, p != left, list.contains(where: { $0.id == p }) else { return nil }
        return p
    }

    func pane(_ id: UUID) -> Pane {
        used[id] = Date()
        if let p = live[id] { return p }
        let info = list.first { $0.id == id }
        let p = Pane(id: id, start: info?.url, isPrivate: info?.isPrivate ?? false)
        p.title = info?.title ?? ""
        p.onChange = { [weak self, weak p] in
            if let self, let p { self.sync(p) }
        }
        configure?(p)
        live[id] = p
        DispatchQueue.main.async { self.trim() }
        return p
    }

    func info(_ id: UUID) -> TabInfo? { list.first { $0.id == id } }

    func sync(_ p: Pane) {
        guard let i = list.firstIndex(where: { $0.id == p.id }) else { return }
        let url = p.isHome ? "" : (p.webView.url?.absoluteString ?? list[i].url)
        let title = p.isHome ? "" : (p.title.isEmpty ? p.host : p.title)
        if p.isHome {
            dropThumb(p.id)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak p] in
                if let self, let p { self.snapshot(p) }
            }
        }
        if list[i].url != url || list[i].title != title {
            list[i].url = url
            list[i].title = title
            save()
        }
    }

    func trim() {
        let keep = Set(visible)
        let candidates = live.keys
            .filter { !keep.contains($0) }
            .sorted { (used[$0] ?? .distantPast) < (used[$1] ?? .distantPast) }
        var extra = live.count - maxLive
        for id in candidates where extra > 0 {
            sleep(id)
            extra -= 1
        }
    }

    func sleepHidden() {
        let keep = Set(visible)
        for id in live.keys where !keep.contains(id) { sleep(id) }
    }

    private func sleep(_ id: UUID) {
        guard let p = live[id] else { return }
        sync(p)
        p.sleep()
        live[id] = nil
        objectWillChange.send()
    }

    func show(_ id: UUID, slot: Int) {
        let cur = slot == 0 ? left : right
        guard cur != id else { return }
        if let p = live[cur] { snapshot(p) }
        if split {
            if slot == 0, right == id { right = left }
            if slot == 1, left == id { left = right }
        }
        previous = cur
        if slot == 0 { left = id } else { right = id }
        used[id] = Date()
        save()
        DispatchQueue.main.async { self.trim() }
    }

    func newTab(slot: Int, isPrivate: Bool = false) {
        let t = TabInfo(priv: isPrivate ? true : nil)
        list.append(t)
        show(t.id, slot: slot)
    }

    func close(_ id: UUID) {
        let wasPrivate = info(id)?.isPrivate ?? false
        sleep(id)
        dropThumb(id)
        list.removeAll { $0.id == id }
        if wasPrivate && privateCount == 0 { Tabs.privateStore = WKWebsiteDataStore.nonPersistent() }
        if previous == id { previous = nil }
        if list.isEmpty {
            let t = TabInfo()
            list = [t]
            left = t.id
            right = t.id
            split = false
        }
        if !list.contains(where: { $0.id == left }) { left = list.first { $0.id != right }?.id ?? list[0].id }
        if !list.contains(where: { $0.id == right }) { right = list.first { $0.id != left }?.id ?? list[0].id }
        if split && left == right {
            let t = TabInfo()
            list.append(t)
            right = t.id
        }
        save()
    }

    func toggleSplit() {
        if split {
            split = false
            DispatchQueue.main.async { self.trim() }
        } else {
            if let p = validPrevious {
                right = p
            } else if right == left || !list.contains(where: { $0.id == right }) {
                let t = TabInfo()
                list.append(t)
                right = t.id
            }
            split = true
        }
        save()
    }

    func closeSplit(keep slot: Int) {
        guard split else { return }
        snapshotVisible()
        if slot == 1 {
            previous = left
            left = right
        } else {
            previous = right
        }
        split = false
        save()
        DispatchQueue.main.async { self.trim() }
    }

    func swap() {
        snapshotVisible()
        if split {
            let l = left
            left = right
            right = l
        } else if let p = validPrevious {
            previous = left
            left = p
            used[p] = Date()
            DispatchQueue.main.async { self.trim() }
        }
        save()
    }

    func save() {
        let keep = list.filter { !$0.isPrivate }
        if let d = try? JSONEncoder().encode(keep) { UserDefaults.standard.set(d, forKey: "tabs") }
        let first = keep.contains { $0.id == left } ? left : keep.first?.id
        UserDefaults.standard.set(first?.uuidString, forKey: "leftTab")
    }
}

// MARK: History

struct HistoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var isSearch: Bool
    var text: String     // the address for a visit, the words for a search
    var title: String
    var date: Date

    var host: String {
        let h = URL(string: text)?.host ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []   // newest first
    private var saveWork: DispatchWorkItem?
    static let cap = 5000

    static let fileURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("history.json")
    }()

    init() {
        if let d = try? Data(contentsOf: HistoryStore.fileURL),
           let list = try? JSONDecoder().decode([HistoryItem].self, from: d) { items = list }
    }

    func addVisit(_ url: URL, title: String) {
        let text = url.absoluteString
        // Reloads and quick revisits update the existing entry instead of piling up.
        if let i = items.prefix(30).firstIndex(where: { !$0.isSearch && $0.text == text }),
           Date().timeIntervalSince(items[i].date) < 1800 {
            var it = items.remove(at: i)
            it.date = Date()
            if !title.isEmpty { it.title = title }
            items.insert(it, at: 0)
        } else {
            items.insert(HistoryItem(isSearch: false, text: text, title: title, date: Date()), at: 0)
        }
        trimAndSave()
    }

    func addSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        items.removeAll { $0.isSearch && $0.text.caseInsensitiveCompare(q) == .orderedSame && Date().timeIntervalSince($0.date) < 600 }
        items.insert(HistoryItem(isSearch: true, text: q, title: q, date: Date()), at: 0)
        trimAndSave()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        trimAndSave()
    }

    // since == nil clears everything.
    func clear(since: Date?) {
        if let since { items.removeAll { $0.date >= since } } else { items.removeAll() }
        trimAndSave()
    }

    var recentSearches: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for it in items where it.isSearch {
            let k = it.text.lowercased()
            if seen.insert(k).inserted { out.append(it.text) }
            if out.count == 30 { break }
        }
        return out
    }

    private func trimAndSave() {
        if items.count > HistoryStore.cap { items.removeLast(items.count - HistoryStore.cap) }
        saveWork?.cancel()
        let snapshot = items
        let w = DispatchWorkItem {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: HistoryStore.fileURL, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: w)
    }
}

struct Suggestion: Identifiable {
    enum Kind { case search, recent, site }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let value: String    // what gets loaded
}

enum Suggest {
    static func make(query raw: String, history: HistoryStore, sites: Sites, limit: Int) -> [Suggestion] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [Suggestion] = []
        var seen = Set<String>()
        func add(_ s: Suggestion) {
            guard out.count < limit, seen.insert(s.value.lowercased()).inserted else { return }
            out.append(s)
        }
        if q.isEmpty {
            for r in history.recentSearches.prefix(4) {
                add(Suggestion(kind: .recent, title: r, subtitle: "Recent search", value: r))
            }
            for h in sites.frequent.prefix(3) {
                add(Suggestion(kind: .site, title: h, subtitle: "Frequently visited", value: h))
            }
            return out
        }
        add(Suggestion(kind: .search, title: raw.trimmingCharacters(in: .whitespaces), subtitle: "Search", value: raw))
        for r in history.recentSearches where r.lowercased().contains(q) {
            add(Suggestion(kind: .recent, title: r, subtitle: "Recent search", value: r))
            if out.count >= 3 { break }
        }
        // Sites: address starting with what you typed first, then title or address containing it.
        let visits = history.items.lazy.filter { !$0.isSearch }
        var starts: [HistoryItem] = [], contains: [HistoryItem] = []
        for v in visits.prefix(1500) {
            let host = v.host.lowercased()
            if host.hasPrefix(q) { starts.append(v) }
            else if host.contains(q) || v.title.lowercased().contains(q) { contains.append(v) }
            if starts.count >= 6 && contains.count >= 6 { break }
        }
        for v in starts + contains {
            add(Suggestion(kind: .site, title: v.title.isEmpty ? v.host : v.title, subtitle: v.host, value: v.text))
        }
        return out
    }
}

// MARK: Themes

struct Theme: Equatable {
    let name: String
    let top: Color       // home page gradient, top
    let bottom: Color    // home page gradient, bottom
    let strip: Color     // bars around the page and the status bar area
    let accent: Color    // buttons, switches, highlights
    let dark: Bool?      // nil = follow the phone's light/dark mode

    var scheme: ColorScheme? { dark.map { $0 ? .dark : .light } }
    var isSystem: Bool { dark == nil }

    static func hex(_ h: String) -> Color {
        let n = Int(h.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
    }

    static let system = Theme(name: "Default", top: Color(.systemBackground), bottom: Color(.systemBackground),
                              strip: Color(.systemBackground), accent: .blue, dark: nil)

    static let presets: [Theme] = [
        system,
        Theme(name: "Matcha", top: hex("#EEF3E2"), bottom: hex("#CFE0B4"), strip: hex("#EEF3E2"), accent: hex("#4E7D32"), dark: false),
        Theme(name: "Sunrise", top: hex("#FFE7C7"), bottom: hex("#FFB4A2"), strip: hex("#FFEBD3"), accent: hex("#E8572A"), dark: false),
        Theme(name: "Ocean", top: hex("#DFF1FA"), bottom: hex("#9DCDEB"), strip: hex("#E4F3FB"), accent: hex("#1667B5"), dark: false),
        Theme(name: "Lavender", top: hex("#F1ECFC"), bottom: hex("#CFC0F2"), strip: hex("#F2EDFC"), accent: hex("#6B4BC2"), dark: false),
        Theme(name: "Sakura", top: hex("#FDECF1"), bottom: hex("#F6BCCD"), strip: hex("#FDEEF2"), accent: hex("#C23B6A"), dark: false),
        Theme(name: "Midnight", top: hex("#1A2340"), bottom: hex("#090D19"), strip: hex("#0E1426"), accent: hex("#7FA2FF"), dark: true),
        Theme(name: "Ember", top: hex("#3A1A14"), bottom: hex("#140807"), strip: hex("#1D0D0A"), accent: hex("#FF7A45"), dark: true),
        Theme(name: "Forest", top: hex("#1F3326"), bottom: hex("#0B140E"), strip: hex("#111D15"), accent: hex("#7FD39A"), dark: true),
    ]

    // Builds a theme from a photo: the average colour for the bars, the most vivid colour as the accent.
    static func fromImage(_ img: UIImage) -> Theme? {
        guard let cg = img.cgImage else { return nil }
        let w = 24, h = 24
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var sum = (0.0, 0.0, 0.0)
        var best = (score: -1.0, r: 0.0, g: 0.0, b: 0.0)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            sum.0 += r; sum.1 += g; sum.2 += b
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let score = sat * (1 - abs(mx - 0.75))
            if score > best.score { best = (score, r, g, b) }
        }
        let n = Double(w * h)
        let avg = (sum.0 / n, sum.1 / n, sum.2 / n)
        let lum = 0.299 * avg.0 + 0.587 * avg.1 + 0.114 * avg.2
        let dark = lum < 0.5
        func mix(_ c: (Double, Double, Double), _ t: Double, _ amt: Double) -> Color {
            Color(red: c.0 + (t - c.0) * amt, green: c.1 + (t - c.1) * amt, blue: c.2 + (t - c.2) * amt)
        }
        let accent = best.score > 0.12
            ? Color(red: best.r, green: best.g, blue: best.b)
            : (dark ? Color.white : Color.black)
        return Theme(name: "Photo",
                     top: mix(avg, dark ? 0 : 1, dark ? 0.2 : 0.4),
                     bottom: mix(avg, dark ? 0 : 1, dark ? 0.45 : 0.15),
                     strip: mix(avg, dark ? 0 : 1, dark ? 0.55 : 0.6),
                     accent: accent,
                     dark: dark)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.system
}

private struct HomeImageKey: EnvironmentKey {
    static let defaultValue: UIImage? = nil
}

extension EnvironmentValues {
    var sdTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    var sdHomeImage: UIImage? {
        get { self[HomeImageKey.self] }
        set { self[HomeImageKey.self] = newValue }
    }
}

final class ThemeStore: ObservableObject {
    @Published var name: String = UserDefaults.standard.string(forKey: "theme") ?? "Default" {
        didSet { UserDefaults.standard.set(name, forKey: "theme") }
    }
    @Published var matchPhoto: Bool = UserDefaults.standard.object(forKey: "matchPhoto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(matchPhoto, forKey: "matchPhoto") }
    }
    @Published private(set) var homeImage: UIImage?
    @Published private(set) var photoTheme: Theme?

    static let imageURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("home-background.jpg")
    }()

    init() {
        if let img = UIImage(contentsOfFile: ThemeStore.imageURL.path) {
            homeImage = img
            photoTheme = Theme.fromImage(img)
        }
    }

    var current: Theme {
        if matchPhoto, homeImage != nil, let p = photoTheme { return p }
        return Theme.presets.first { $0.name == name } ?? .system
    }

    // Saves a downscaled copy (max 1600 px) so it loads fast and doesn't use much storage.
    func setImage(_ data: Data) {
        guard let src = UIImage(data: data) else { return }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(src.size.width, src.size.height))
        let size = CGSize(width: (src.size.width * scale).rounded(), height: (src.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in src.draw(in: CGRect(origin: .zero, size: size)) }
        try? img.jpegData(compressionQuality: 0.85)?.write(to: ThemeStore.imageURL)
        homeImage = img
        photoTheme = Theme.fromImage(img)
    }

    func removeImage() {
        try? FileManager.default.removeItem(at: ThemeStore.imageURL)
        homeImage = nil
        photoTheme = nil
    }
}

struct ThemeChip: View {
    let theme: Theme
    let selected: Bool
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: theme.isSystem ? [Color(.systemGray5), Color(.systemGray3)] : [theme.top, theme.bottom],
                                         startPoint: .top, endPoint: .bottom))
                Circle().fill(theme.accent).frame(width: 16, height: 16).padding(8)
            }
            .frame(width: 64, height: 84)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 0.5))
            Text(theme.name).font(.caption2.weight(.medium)).foregroundStyle(.primary)
        }
    }
}

struct ThemeSettings: View {
    @ObservedObject var themes: ThemeStore
    @State private var pick: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Theme.presets, id: \.name) { t in
                            Button { withAnimation(.snappy) { themes.name = t.name } } label: {
                                ThemeChip(theme: t, selected: themes.current.name == t.name)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(t.name) theme")
                        }
                    }
                    .padding(.vertical, 8)
                }
            } header: {
                Text("Theme")
            } footer: {
                if themes.matchPhoto && themes.homeImage != nil {
                    Text("Your theme is currently matched to your home photo. Turn off Match Theme to Photo to use a preset.")
                }
            }
            Section {
                if let img = themes.homeImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(themes.homeImage == nil ? "Choose Photo" : "Change Photo", systemImage: "photo")
                }
                if themes.homeImage != nil {
                    Toggle("Match Theme to Photo", isOn: $themes.matchPhoto)
                    Button("Remove Photo", role: .destructive) { withAnimation { themes.removeImage() } }
                }
            } header: {
                Text("Home Background")
            } footer: {
                Text("Your photo stays on this iPhone. Matching picks the bar, accent and light or dark look from its colours.")
            }
        }
        .navigationTitle("Themes")
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run { withAnimation { themes.setImage(data) } }
                }
                await MainActor.run { pick = nil }
            }
        }
    }
}

// MARK: Start page sites

final class Sites: ObservableObject {
    @Published var visits: [String: Int] = (UserDefaults.standard.dictionary(forKey: "visits") as? [String: Int]) ?? [:]
    @Published var custom: [String] = UserDefaults.standard.stringArray(forKey: "mySites") ?? []

    var frequent: [String] {
        visits.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(12).map { $0.key }
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !t.contains("://") { t = "https://" + t }
        let h = URL(string: t)?.host ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    func record(_ host: String) {
        let h = Sites.clean(host)
        guard !h.isEmpty else { return }
        visits[h, default: 0] += 1
        UserDefaults.standard.set(visits, forKey: "visits")
    }

    func add(_ s: String) {
        let h = Sites.clean(s)
        guard !h.isEmpty, !custom.contains(h) else { return }
        custom.append(h)
        save()
    }

    func remove(_ h: String) { custom.removeAll { $0 == h }; save() }

    func forget(_ h: String) {
        visits[h] = nil
        UserDefaults.standard.set(visits, forKey: "visits")
    }

    func clearVisits() {
        visits = [:]
        UserDefaults.standard.set(visits, forKey: "visits")
    }

    func save() { UserDefaults.standard.set(custom, forKey: "mySites") }
}

struct SiteIcon: View {
    let host: String
    var size: CGFloat = 56
    var body: some View {
        AsyncImage(url: URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")) { phase in
            if let img = phase.image {
                img.resizable().scaledToFit().frame(width: size * 0.5, height: size * 0.5)
            } else {
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct StartPage: View {
    @ObservedObject var sites: Sites
    var topPad: CGFloat = 24
    var blocked: Int = 0
    var open: (String) -> Void
    @AppStorage("homeMode") private var mode = 0
    @State private var adding = false
    @State private var newSite = ""
    @Environment(\.sdTheme) private var theme
    @Environment(\.sdHomeImage) private var homeImage
    @Environment(\.colorScheme) private var sys

    private func name(_ h: String) -> String {
        let parts = h.split(separator: ".")
        let base = parts.count >= 2 ? parts[parts.count - 2] : Substring(h)
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    var body: some View {
        let hosts = mode == 1 ? sites.custom : sites.frequent
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if blocked > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
                        Text("\(blocked.formatted()) ads and trackers blocked")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Menu {
                    Picker("Show", selection: $mode) {
                        Text("Frequently Visited").tag(0)
                        Text("My Sites").tag(1)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(mode == 1 ? "My Sites" : "Frequently Visited").font(.title2.bold())
                        Image(systemName: "chevron.down").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                if hosts.isEmpty && mode == 0 {
                    Text("Sites you visit most will appear here.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 14)], spacing: 18) {
                    ForEach(hosts, id: \.self) { h in
                        Button { open(h) } label: {
                            VStack(spacing: 6) {
                                SiteIcon(host: h)
                                Text(name(h)).font(.caption).foregroundStyle(.primary).lineLimit(1)
                            }
                        }
                        .contextMenu {
                            if mode == 1 {
                                Button(role: .destructive) { sites.remove(h) } label: { Label("Remove from My Sites", systemImage: "minus.circle") }
                            } else {
                                if !sites.custom.contains(h) {
                                    Button { sites.add(h) } label: { Label("Add to My Sites", systemImage: "star") }
                                }
                                Button(role: .destructive) { sites.forget(h) } label: { Label("Hide", systemImage: "eye.slash") }
                            }
                        }
                    }
                    if mode == 1 {
                        Button { adding = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.title2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, height: 56)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                Text("Add").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, topPad)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.colorScheme, homeImage != nil ? .dark : sys)
        .background {
            if let img = homeImage {
                GeometryReader { g in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                }
                .overlay(LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.15), .black.opacity(0.35)],
                                        startPoint: .top, endPoint: .bottom))
            } else {
                LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
            }
        }
        .alert("Add a site", isPresented: $adding) {
            TextField("example.com", text: $newSite)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Add") { sites.add(newSite); newSite = "" }
            Button("Cancel", role: .cancel) { newSite = "" }
        }
    }
}

// MARK: Shields (Brave-style blocking)

final class Shields: ObservableObject {
    struct BlockList: Identifiable {
        let id: String
        let name: String
        let detail: String
        let defaultOn: Bool
    }

    static let lists = [
        BlockList(id: "ads", name: "Ads", detail: "EasyList", defaultOn: true),
        BlockList(id: "trackers", name: "Trackers", detail: "EasyPrivacy and Peter Lowe's list", defaultOn: true),
        BlockList(id: "cookies", name: "Cookie Notices", detail: "Hides consent pop-ups", defaultOn: true),
        BlockList(id: "youtube", name: "YouTube Ads", detail: "Removes, hides or skips ads on YouTube", defaultOn: true),
        BlockList(id: "annoyances", name: "Annoyances", detail: "Newsletter pop-ups, social widgets, chat bubbles", defaultOn: false),
    ]

    @Published private(set) var compiled: [String: WKContentRuleList] = [:]
    @Published private(set) var preparing = false
    @Published private(set) var totalBlocked = UserDefaults.standard.integer(forKey: "blockedTotal")
    @Published private(set) var siteOff: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "shieldsOff") ?? [])
    @Published private(set) var version = 0
    var pendingReload = false
    private var base: WKContentRuleList?
    private var unsaved = 0
    private var flushScheduled = false

    static func key(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    var available: Bool { Bundle.main.url(forResource: "sd-ads", withExtension: "json") != nil }

    func isEnabled(_ id: String) -> Bool {
        UserDefaults.standard.object(forKey: "list_" + id) as? Bool
            ?? (Shields.lists.first { $0.id == id }?.defaultOn ?? false)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "list_" + id)
        pendingReload = true
        version += 1
        if on && compiled[id] == nil { Task { await prepare() } }
    }

    func isUp(_ host: String) -> Bool { host.isEmpty || !siteOff.contains(Shields.key(host)) }

    func setUp(_ host: String, _ up: Bool) {
        let k = Shields.key(host)
        guard !k.isEmpty else { return }
        if up { siteOff.remove(k) } else { siteOff.insert(k) }
        UserDefaults.standard.set(siteOff.sorted(), forKey: "shieldsOff")
        pendingReload = true
        version += 1
    }

    func masterChanged() {
        pendingReload = true
        version += 1
    }

    func rules(for host: String) -> [WKContentRuleList] {
        let master = UserDefaults.standard.object(forKey: "block") as? Bool ?? true
        guard master, isUp(host) else { return [] }
        var out: [WKContentRuleList] = []
        if let base { out.append(base) }
        for l in Shields.lists where isEnabled(l.id) {
            if let c = compiled[l.id] { out.append(c) }
        }
        return out
    }

    func youtubeOn(for host: String) -> Bool {
        let master = UserDefaults.standard.object(forKey: "block") as? Bool ?? true
        return master && isUp(host) && isEnabled("youtube")
    }

    // Counts are batched so a page full of blocked ads doesn't redraw the UI dozens of times.
    func countBlocked() {
        unsaved += 1
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.totalBlocked += self.unsaved
            self.unsaved = 0
            self.flushScheduled = false
            UserDefaults.standard.set(self.totalBlocked, forKey: "blockedTotal")
        }
    }

    // Compiles the bundled lists once; afterwards WebKit loads them from its cache instantly.
    @MainActor
    func prepare() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        if base == nil {
            base = await Rules.compile()
            version += 1
        }
        guard let store = WKContentRuleListStore.default() else { return }
        let ver = Bundle.main.url(forResource: "blocklists-version", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        for l in Shields.lists where isEnabled(l.id) && compiled[l.id] == nil {
            guard let url = Bundle.main.url(forResource: "sd-" + l.id, withExtension: "json") else { continue }
            let ident = "sd-\(l.id)-\(ver)"
            if let found = await Shields.lookUp(store, ident) {
                compiled[l.id] = found
                version += 1
                continue
            }
            let json = await Task.detached(priority: .utility) { try? String(contentsOf: url, encoding: .utf8) }.value
            guard let json, json.count > 2 else { continue }
            if let list = try? await store.compileContentRuleList(forIdentifier: ident, encodedContentRuleList: json) {
                compiled[l.id] = list
                version += 1
            }
        }
        store.getAvailableContentRuleListIdentifiers { ids in
            for id in ids ?? [] where id.hasPrefix("sd-") && !id.hasSuffix("-" + ver) {
                store.removeContentRuleList(forIdentifier: id) { _ in }
            }
        }
    }

    private static func lookUp(_ store: WKContentRuleListStore, _ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { c in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in c.resume(returning: list) }
        }
    }
}

struct ShieldsView: View {
    @ObservedObject var shields: Shields
    @ObservedObject var pane: Pane
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let host = Shields.key(pane.host)
        let up = shields.isUp(host)
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        if !host.isEmpty { SiteIcon(host: host, size: 52) }
                        Text(host.isEmpty ? "This page" : host).font(.headline)
                        Button { shields.setUp(host, !up) } label: {
                            Label(up ? "Shields are UP" : "Shields are DOWN",
                                  systemImage: up ? "shield.lefthalf.filled" : "shield.slash")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(up ? Color.orange : Color.gray, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(host.isEmpty)
                        Text(up ? "\(pane.blockedCount) ads and trackers blocked on this page"
                                : "Ads and trackers are allowed on this site")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                Section {
                    ForEach(Shields.lists) { l in
                        Toggle(isOn: Binding(get: { shields.isEnabled(l.id) }, set: { shields.setEnabled(l.id, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.name)
                                Text(l.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Block Lists")
                } footer: {
                    Text("Lists apply to every site. If a site breaks, turn its Shields down above.")
                }
                Section {
                    LabeledContent("Blocked in total", value: shields.totalBlocked.formatted())
                }
            }
            .navigationTitle("Shields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct ShieldsSettings: View {
    @ObservedObject var shields: Shields
    @AppStorage("block") private var blockOn = true

    var body: some View {
        Form {
            Section {
                Toggle("Block Ads and Trackers", isOn: $blockOn)
            } footer: {
                Text("\(shields.totalBlocked.formatted()) ads and trackers blocked so far.")
            }
            Section {
                ForEach(Shields.lists) { l in
                    Toggle(isOn: Binding(get: { shields.isEnabled(l.id) }, set: { shields.setEnabled(l.id, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.name)
                            Text(l.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Filter Lists")
            } footer: {
                if !shields.available {
                    Text("The full lists aren't in this build, so only the basic built-in list is active.")
                } else if shields.preparing {
                    Text("Preparing lists. This takes a few seconds the first time after an update.")
                } else {
                    Text("Lists are built into the app and refresh every time it's rebuilt (automatically each Monday).")
                }
            }
            if !shields.siteOff.isEmpty {
                Section("Shields Down On") {
                    ForEach(shields.siteOff.sorted(), id: \.self) { h in
                        HStack(spacing: 12) {
                            SiteIcon(host: h, size: 28)
                            Text(h)
                        }
                    }
                    .onDelete { idx in
                        let sorted = shields.siteOff.sorted()
                        idx.map { sorted[$0] }.forEach { shields.setUp($0, true) }
                    }
                }
            }
        }
        .navigationTitle("Shields")
    }
}

// MARK: Pane view

struct PaneActions {
    var autofill: () -> Void
    var calendar: () -> Void
    var settings: () -> Void
    var vpn: () -> Void
    var vpnOn: Bool
    var newTab: () -> Void
    var shields: () -> Void
    var shieldsUp: Bool
    var totalBlocked: Int
    var newPrivateTab: () -> Void
    var history: () -> Void
    var privateLocked: Bool
    var unlockPrivate: () -> Void
}

struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var sites: Sites
    @ObservedObject var history: HistoryStore
    var actions: PaneActions
    var compact = false            // slim bar used in split view
    var atTop = false              // bar sits in a strip above the page (top pane in portrait split)
    var safeTop: CGFloat = 0       // status bar height, for a top strip
    var bottomInset: CGFloat = 0   // home indicator height, for a bottom strip
    var trailingRoom: CGFloat = 0  // space left for the tab pill beside a top bar
    @Environment(\.colorScheme) private var sys
    @AppStorage("saver") private var saver = false
    @AppStorage("adaptiveText") private var adaptiveText = true
    @AppStorage("textColor") private var textColor = "System"
    @Environment(\.sdTheme) private var theme
    @Environment(\.scenePhase) private var phase
    @State private var desktop = false
    @FocusState private var focused: Bool

    private var ink: AnyShapeStyle {
        if adaptiveText || TextColors.color(textColor) == nil { return AnyShapeStyle(dark ? Color.white : Color.black) }
        return TextColors.ink(adaptive: adaptiveText, name: textColor)
    }
    private var mini: Bool { pane.collapsed && !focused && !pane.isHome }
    // The bottom strip takes the page's own colour so it blends in; the top strip matches the status bar.
    private var stripColor: Color {
        if pane.isPrivate { return Color(red: 0.14, green: 0.10, blue: 0.23) }
        return pane.isHome || atTop ? theme.strip : (pane.bottomColor ?? theme.strip)
    }
    // Whether the bar surface is dark. Adaptive: follows the page so text stays readable.
    // Fixed colour: the surface contrasts with the colour you picked.
    private var dark: Bool {
        if pane.isPrivate { return true }
        if !adaptiveText { return TextColors.isLight(textColor) ?? (sys == .dark) }
        if pane.isHome || atTop { return sys == .dark }
        return pane.pageDark ?? (sys == .dark)
    }
    private var spring: Animation? { saver ? nil : .spring(response: 0.35, dampingFraction: 0.82) }
    private var smooth: Animation? { saver ? nil : .smooth(duration: 0.4) }
    @Namespace private var ns
    private var barH: CGFloat { compact ? 36 : 48 }
    private var iconW: CGFloat { compact ? 32 : 40 }

    // Shows just the site name until you tap in, then the full address.
    private var addressText: Binding<String> {
        Binding(
            get: { focused || pane.isHome ? pane.address : pane.host.replacingOccurrences(of: "www.", with: "") },
            set: { pane.address = $0 }
        )
    }

    private var suggestions: [Suggestion] {
        guard focused, !pane.isPrivate else { return [] }
        let typed = pane.address == pane.webView.url?.absoluteString ? "" : pane.address
        return Suggest.make(query: typed, history: history, sites: sites, limit: compact ? 4 : 6)
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider().padding(.leading, 48) }
                Button {
                    focused = false
                    pane.load(s.value)
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            switch s.kind {
                            case .search: Image(systemName: "magnifyingglass")
                            case .recent: Image(systemName: "clock.arrow.circlepath")
                            case .site: Image(systemName: "globe")
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.subheadline).foregroundStyle(ink).lineLimit(1)
                            Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: atTop ? "arrow.down.left" : "arrow.up.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: compact ? 42 : 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sdGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), dark: dark)
        .transition(.opacity.combined(with: .move(edge: atTop ? .top : .bottom)))
    }

    private var bottomPad: CGFloat {
        if focused { return 8 }
        if mini { return max(bottomInset - 14, 6) }
        return max(bottomInset - (compact ? 10 : 4), compact ? 8 : 10)
    }

    // The page never sits under the bars: it fills the space between them, and grows as they shrink.
    var body: some View {
        VStack(spacing: 0) {
            if atTop { topRow }
            ZStack {
                WebHost(webView: pane.webView)
                    .opacity(pane.isHome ? 0 : 1)
                if pane.isHome {
                    if pane.isPrivate {
                        PrivateStartPage()
                    } else {
                        StartPage(sites: sites, blocked: actions.totalBlocked) { pane.load($0) }
                    }
                }
                if focused {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { focused = false }
                        .gesture(DragGesture(minimumDistance: 8).onEnded { v in
                            if v.translation.height > 16 { focused = false }
                        })
                }
            }
            .clipped()
            if !atTop { bottomRow }
        }
        .overlay {
            // Private tabs are hidden when locked, and in the app switcher.
            if pane.isPrivate && (actions.privateLocked || phase != .active) {
                PrivateCover(locked: actions.privateLocked, unlock: actions.unlockPrivate)
            }
        }
        .animation(smooth, value: mini)
        .animation(spring, value: focused)
        .animation(spring, value: pane.hiding)
        .animation(spring, value: showBanner)
        .animation(spring, value: suggestions.count)
        .onChange(of: focused) { _, f in pane.editing = f }
    }

    private var topRow: some View {
        VStack(spacing: 6) {
            bar.frame(height: barH)
            if showBanner { fillBanner }
            if !suggestions.isEmpty { suggestionList }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.top, safeTop + 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(stripColor)
    }

    private var bottomRow: some View {
        VStack(spacing: 8) {
            if !suggestions.isEmpty { suggestionList }
            if showBanner { fillBanner }
            bar
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.horizontal, 12)
        .padding(.top, mini ? 4 : (compact ? 6 : 8))
        .padding(.bottom, bottomPad)
        .frame(maxWidth: .infinity)
        .background(stripColor)
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { v in
            if focused && v.translation.height > 20 { focused = false }
        })
        .animation(saver ? nil : .easeInOut(duration: 0.25), value: dark)
    }

    // Small refresh (or stop, while loading) button inside the address capsule.
    private var reloadButton: some View {
        Button {
            if pane.loading { pane.webView.stopLoading() } else { pane.webView.reload() }
        } label: {
            Image(systemName: pane.loading ? "xmark" : "arrow.clockwise")
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: compact ? 26 : 30, height: barH)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(pane.loading ? "Stop loading" : "Reload")
    }

    private func icon(_ name: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: iconW, height: barH)
                .contentShape(Rectangle())
        }
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }

    private var fillBanner: some View {
        HStack(spacing: 0) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.leading, 14)
            Text("Use saved password")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            Button {
                pane.offerFill = false
                actions.autofill()
            } label: {
                Text("Fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .background(theme.accent, in: Capsule())
            }
            icon("xmark") { pane.offerFill = false }
        }
        .frame(height: 36)
        .sdGlass(Capsule(), dark: dark)
        .transition(.move(edge: atTop ? .top : .bottom).combined(with: .opacity))
    }

    private var showBanner: Bool { pane.offerFill && !focused && !pane.hiding && !pane.isHome }

    private var field: some View {
        TextField(pane.isPrivate ? "Search privately" : "Search or enter site", text: addressText)
            .textFieldStyle(.plain)
            .font(compact ? .subheadline : .body)
            .foregroundStyle(ink)
            .multilineTextAlignment(focused ? .leading : .center)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .focused($focused)
            .onSubmit { pane.load(pane.address); focused = false }
    }

    @ViewBuilder private var bar: some View {
        if pane.hiding {
            HStack(spacing: 0) {
                Text("Tap items to hide")
                    .font(compact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
                    .foregroundStyle(ink)
                    .padding(.leading, compact ? 14 : 18)
                Spacer(minLength: 8)
                if pane.canUndoHide { icon("arrow.uturn.backward") { pane.undoHide() } }
                Button { pane.stopHiding() } label: {
                    Text("Done")
                        .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 12 : 16)
                        .frame(height: barH - 12)
                        .background(theme.accent, in: Capsule())
                }
                .padding(.trailing, 6)
            }
            .frame(height: barH)
            .sdGlass(Capsule(), dark: dark)
            .matchedGeometryEffect(id: "bar", in: ns)
            .transition(.opacity)
        } else if mini {
            Button { pane.collapsed = false } label: {
                Text(pane.host.isEmpty ? "Search" : pane.host.replacingOccurrences(of: "www.", with: ""))
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .padding(.horizontal, compact ? 12 : 16)
                    .padding(.vertical, compact ? 5 : 7)
            }
            .sdGlass(Capsule(), dark: dark)
            .matchedGeometryEffect(id: "bar", in: ns)
            .transition(.opacity)
        } else {
            // One capsule: back and forward built in, then the address, extras and menu.
            HStack(spacing: 0) {
                if !focused {
                    icon("chevron.left", enabled: pane.backEnabled) { pane.back() }
                    icon("chevron.right", enabled: pane.forwardEnabled) { pane.forward() }
                    if pane.isPrivate {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: compact ? 11 : 12, weight: .semibold))
                            .foregroundStyle(ink)
                            .opacity(0.8)
                            .accessibilityLabel("Private tab")
                    }
                }
                field.padding(.leading, focused ? (compact ? 14 : 18) : 4)
                if focused {
                    if !pane.address.isEmpty { icon("xmark.circle.fill") { pane.address = "" } }
                } else {
                    if !pane.isHome && pane.hasLogin { icon("key.fill") { actions.autofill() } }
                    if !pane.isHome && pane.hasCard { icon("creditcard.fill") { actions.autofill() } }
                    if !pane.isHome { reloadButton }
                    menu
                }
            }
            .padding(.horizontal, 2)
            .frame(height: barH)
            .sdGlass(Capsule(), dark: dark)
            .matchedGeometryEffect(id: "bar", in: ns)
            .transition(.opacity)
        }
    }

    private var menu: some View {
        Menu {
            Button { pane.goHome() } label: { Label("Home", systemImage: "house") }
            Button { actions.newTab() } label: { Label("New Tab", systemImage: "plus.square.on.square") }
            Button { actions.newPrivateTab() } label: { Label("New Private Tab", systemImage: "eye.slash") }
            Button { actions.history() } label: { Label("History", systemImage: "clock") }
            if !pane.isHome, let url = pane.webView.url {
                ShareLink(item: url, subject: Text(pane.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if !pane.isHome {
                Button { desktop.toggle(); pane.setDesktop(desktop) } label: {
                    Label(desktop ? "Mobile Site" : "Desktop Site", systemImage: desktop ? "iphone" : "desktopcomputer")
                }
                Button { pane.startHiding() } label: { Label("Hide Distracting Items", systemImage: "eye.slash") }
                if pane.hiddenCount > 0 {
                    Button { pane.showAllHidden() } label: { Label("Show Hidden Items (\(pane.hiddenCount))", systemImage: "eye") }
                }
                Button { actions.calendar() } label: { Label("Add to Calendar", systemImage: "calendar.badge.plus") }
            }
            Divider()
            if !pane.isHome {
                Button { actions.shields() } label: {
                    Label(actions.shieldsUp ? "Shields · \(pane.blockedCount) blocked" : "Shields Down",
                          systemImage: actions.shieldsUp ? "shield.lefthalf.filled" : "shield.slash")
                }
            }
            Button { actions.vpn() } label: { Label(actions.vpnOn ? "VPN (On)" : "VPN", systemImage: actions.vpnOn ? "lock.shield.fill" : "lock.shield") }
            Button { actions.settings() } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: iconW, height: barH)
                .contentShape(Rectangle())
        }
        .environment(\.colorScheme, sys)
    }
}

// MARK: Private mode screens

struct PrivateStartPage: View {
    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.white.opacity(0.75))
            Text(text).foregroundStyle(.white.opacity(0.85))
        }
        .font(.subheadline)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "eye.slash.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Private Tab")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 12) {
                    Text("SplitDeck won't save").font(.headline).foregroundStyle(.white)
                    row("clock", "Your browsing and search history")
                    row("externaldrive", "Cookies, site data and cache (all erased when you close your last private tab)")
                    row("key", "New passwords you type")
                    row("photo", "Tab previews to storage")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Still on").font(.headline).foregroundStyle(.white)
                    row("shield.lefthalf.filled", "Shields: ads and trackers are blocked")
                    row("lock", "Private tabs lock with Face ID when you leave the app (Settings › Privacy)")
                }
                Text("Your activity may still be visible to the websites you visit, your network or internet provider, and your employer or school.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LinearGradient(colors: [Color(red: 0.20, green: 0.13, blue: 0.34), Color(red: 0.07, green: 0.05, blue: 0.12)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

struct PrivateCover: View {
    var locked: Bool
    var unlock: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.07, blue: 0.17)
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.white)
                Text("Private tabs are locked").font(.headline).foregroundStyle(.white)
                if locked {
                    Button("Unlock", action: unlock)
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                }
            }
        }
    }
}

// MARK: Edge dock

// Tabs, last-tab switch and split view, docked on the right edge. Swipe it right (or tap the chevron)
// to tuck it away as a thin tab; tap or swipe that tab to bring it back. Drag up or down to move it.
struct EdgeDock: View {
    @ObservedObject var tabs: Tabs
    var saver: Bool
    var privateMode: Bool
    var openTabs: () -> Void
    @AppStorage("dockTucked") private var tucked = false
    @AppStorage("dockY") private var dockY = 0.45
    @AppStorage("adaptiveText") private var adaptiveText = true
    @AppStorage("textColor") private var textColor = "System"
    @State private var dragY: CGFloat = 0
    @State private var dragX: CGFloat = 0

    private var ink: AnyShapeStyle {
        privateMode ? AnyShapeStyle(Color.white) : TextColors.ink(adaptive: adaptiveText, name: textColor)
    }
    private var anim: Animation? { saver ? nil : .spring(response: 0.35, dampingFraction: 0.8) }

    private func button<L: View>(_ label: String, _ action: @escaping () -> Void, @ViewBuilder content: () -> L) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            button("Tabs", openTabs) {
                Text("\(privateMode ? tabs.privateCount : tabs.normalCount)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink, lineWidth: 1.6))
            }
            button("Switch to last tab", { withAnimation(anim) { tabs.swap() } }) {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(!tabs.canSwap)
            .opacity(tabs.canSwap ? 1 : 0.4)
            button(tabs.split ? "Close split view" : "Split view", { withAnimation(anim) { tabs.toggleSplit() } }) {
                Image(systemName: tabs.split ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
            }
            button("Tuck away", { withAnimation(anim) { tucked = true } }) {
                Image(systemName: "chevron.compact.right").font(.system(size: 14, weight: .bold))
            }
            .opacity(0.6)
        }
        .padding(.vertical, 4)
        .sdGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), dark: privateMode ? true : nil)
    }

    private var handle: some View {
        Capsule()
            .fill(privateMode ? Color.white.opacity(0.7) : Color.primary.opacity(0.35))
            .frame(width: 5, height: 56)
            .frame(width: 30, height: 90, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(anim) { tucked = false } }
            .accessibilityLabel("Show tab controls")
            .accessibilityAddTraits(.isButton)
    }

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let y = min(max(dockY * h + dragY, 110), max(h - 110, 110))
            Group {
                if tucked { handle } else { panel }
            }
            .offset(x: dragX)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { v in
                        if abs(v.translation.height) > abs(v.translation.width) {
                            dragY = v.translation.height
                        } else if !tucked {
                            dragX = max(0, v.translation.width)
                        } else {
                            dragX = min(0, v.translation.width) / 3
                        }
                    }
                    .onEnded { v in
                        if abs(v.translation.height) > abs(v.translation.width) {
                            dockY = Double(min(max(dockY * h + v.translation.height, 110), max(h - 110, 110)) / max(h, 1))
                        } else if !tucked && v.translation.width > 40 {
                            withAnimation(anim) { tucked = true }
                        } else if tucked && v.translation.width < -20 {
                            withAnimation(anim) { tucked = false }
                        }
                        dragY = 0
                        withAnimation(anim) { dragX = 0 }
                    }
            )
            .position(x: g.size.width - (tucked ? 15 : 30), y: y)
        }
    }
}

// The strip behind the status bar. Matches the theme, or the private colour in a private tab.
struct TopStrip: View {
    @ObservedObject var pane: Pane
    var safeTop: CGFloat
    @Environment(\.sdTheme) private var theme

    var body: some View {
        Color.clear
            .frame(height: safeTop)
            .frame(maxWidth: .infinity)
            .background(pane.isPrivate ? Color(red: 0.14, green: 0.10, blue: 0.23) : theme.strip)
    }
}

// MARK: History screen

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var sites: Sites
    var open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter = 0      // 0 all, 1 sites, 2 searches
    @State private var askClear = false

    private var shown: [HistoryItem] {
        let q = query.lowercased()
        return history.items.filter { it in
            (filter == 0 || (filter == 1) != it.isSearch)
                && (q.isEmpty || it.text.lowercased().contains(q) || it.title.lowercased().contains(q))
        }
    }

    struct DayGroup: Identifiable {
        let day: Date
        let items: [HistoryItem]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let cal = Calendar.current
        var order: [Date] = []
        var groups: [Date: [HistoryItem]] = [:]
        for it in shown {
            let d = cal.startOfDay(for: it.date)
            if groups[d] == nil { order.append(d) }
            groups[d, default: []].append(it)
        }
        return order.map { DayGroup(day: $0, items: groups[$0] ?? []) }
    }

    private func label(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $filter) {
                    Text("All").tag(0)
                    Text("Sites").tag(1)
                    Text("Searches").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                if shown.isEmpty {
                    Text(query.isEmpty ? "No history yet." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(days) { group in
                    Section {
                        ForEach(group.items) { it in
                            Button {
                                open(it.text)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    if it.isSearch {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28, height: 28)
                                    } else {
                                        SiteIcon(host: it.host, size: 28)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(it.title.isEmpty ? it.host : it.title).lineLimit(1)
                                        Text(it.isSearch ? "Search" : it.host)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(it.date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        .onDelete { idx in history.remove(Set(idx.map { group.items[$0].id })) }
                    } header: {
                        Text("\(label(group.day)) · \(group.items.count)")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search history")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { askClear = true }.disabled(history.items.isEmpty)
                }
            }
            .confirmationDialog("Clear history", isPresented: $askClear, titleVisibility: .visible) {
                Button("Last Hour", role: .destructive) { history.clear(since: Date().addingTimeInterval(-3600)) }
                Button("Today", role: .destructive) { history.clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("Today and Yesterday", role: .destructive) {
                    let start = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))
                    history.clear(since: start)
                }
                Button("All Time", role: .destructive) {
                    history.clear(since: nil)
                    sites.clearVisits()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clearing All Time also resets your Frequently Visited sites.")
            }
        }
    }
}

// MARK: Tab switcher

struct TabsView: View {
    @ObservedObject var tabs: Tabs
    var startPrivate: Bool
    var privateLocked: Bool
    var unlock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var slot = 0
    @State private var privateSection: Bool?

    private var showingPrivate: Bool { privateSection ?? startPrivate }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Tabs", selection: Binding(get: { showingPrivate }, set: { privateSection = $0 })) {
                        Text("Tabs (\(tabs.normalCount))").tag(false)
                        Text("Private (\(tabs.privateCount))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if tabs.split {
                        Picker("Open in", selection: $slot) {
                            Text("First Pane").tag(0)
                            Text("Second Pane").tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                    if showingPrivate && privateLocked && tabs.privateCount > 0 {
                        VStack(spacing: 12) {
                            Image(systemName: "lock.fill").font(.system(size: 30))
                            Text("Private tabs are locked").font(.headline)
                            Button("Unlock", action: unlock).buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else if showingPrivate && tabs.privateCount == 0 {
                        VStack(spacing: 10) {
                            Image(systemName: "eye.slash").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text("No private tabs").font(.headline)
                            Text("Private tabs don't save history, cookies or site data.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(tabs.list.filter { $0.isPrivate == showingPrivate && !(showingPrivate && privateLocked) }) { t in
                            TabCard(t: t, tabs: tabs) {
                                tabs.show(t.id, slot: tabs.split ? slot : 0)
                                dismiss()
                            }
                        }
                    }
                    Text("Swipe a tab left or right to close it. Tabs you haven't used recently sleep to save memory and battery, then reload when opened.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(showingPrivate ? "Private Tabs" : "Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if showingPrivate && tabs.privateCount > 0 && !privateLocked {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Close All Private Tabs", role: .destructive) {
                            withAnimation(.snappy) { tabs.closeAllPrivate() }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { tabs.newTab(slot: tabs.split ? slot : 0); dismiss() } label: {
                            Label("New Tab", systemImage: "plus.square.on.square")
                        }
                        Button { tabs.newTab(slot: tabs.split ? slot : 0, isPrivate: true); dismiss() } label: {
                            Label("New Private Tab", systemImage: "eye.slash")
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        tabs.newTab(slot: tabs.split ? slot : 0, isPrivate: showingPrivate)
                        dismiss()
                    }
                    .accessibilityLabel(showingPrivate ? "New private tab" : "New tab")
                }
            }
        }
    }

}

// One tab in the grid. Swipe it sideways to close it, or tap to open.
struct TabCard: View {
    let t: TabInfo
    @ObservedObject var tabs: Tabs
    var open: () -> Void
    @State private var dx: CGFloat = 0
    @State private var closing = false

    private func close(toward dir: CGFloat) {
        closing = true
        withAnimation(.easeIn(duration: 0.18)) { dx = dir * 520 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            withAnimation(.snappy) { tabs.close(t.id) }
        }
    }

    var body: some View {
        let host = (URL(string: t.url)?.host ?? "").replacingOccurrences(of: "www.", with: "")
        let isVisible = tabs.visible.contains(t.id)
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                preview(host: host)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isVisible ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isVisible ? 3 : 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                Button { close(toward: 1) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .padding(8)
                .accessibilityLabel("Close tab")
            }
            HStack(spacing: 6) {
                if host.isEmpty {
                    Image(systemName: "house.fill").font(.caption2).foregroundStyle(.secondary)
                } else {
                    SiteIcon(host: host, size: 16)
                }
                Text(t.title.isEmpty ? (host.isEmpty ? "Home" : host) : t.title)
                    .font(.caption)
                    .lineLimit(1)
                if !isVisible && !tabs.isLive(t.id) {
                    Image(systemName: "moon.zzz.fill").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .offset(x: dx)
        .rotationEffect(.degrees(Double(dx / 40)))
        .opacity(1 - min(abs(dx) / 300, 0.75))
        .onTapGesture { if !closing { open() } }
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { v in
                    guard !closing, abs(v.translation.width) > abs(v.translation.height) else { return }
                    dx = v.translation.width
                }
                .onEnded { v in
                    guard !closing else { return }
                    if abs(dx) > 90 || abs(v.predictedEndTranslation.width) > 280 {
                        close(toward: (dx == 0 ? v.predictedEndTranslation.width : dx) > 0 ? 1 : -1)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { dx = 0 }
                    }
                }
        )
        .contextMenu {
            Button(role: .destructive) { close(toward: 1) } label: {
                Label("Close Tab", systemImage: "xmark")
            }
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    @ViewBuilder private func preview(host: String) -> some View {
        if host.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "house").font(.title2)
                Text("Home").font(.footnote.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let img = tabs.thumb(t.id) {
            GeometryReader { g in
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    .clipped()
            }
        } else {
            SiteIcon(host: host, size: 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct MySitesEditor: View {
    @ObservedObject var sites: Sites
    @State private var new = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("example.com", text: $new)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(new.isEmpty)
                }
            }
            Section("My Sites") {
                ForEach(sites.custom, id: \.self) { h in
                    HStack(spacing: 12) {
                        SiteIcon(host: h, size: 30)
                        Text(h)
                    }
                }
                .onDelete { sites.custom.remove(atOffsets: $0); sites.save() }
                .onMove { sites.custom.move(fromOffsets: $0, toOffset: $1); sites.save() }
            }
            let suggestions = sites.frequent.filter { !sites.custom.contains($0) }
            if !suggestions.isEmpty {
                Section("Add from Frequently Visited") {
                    ForEach(suggestions, id: \.self) { h in
                        Button { sites.add(h) } label: { Label(h, systemImage: "plus.circle") }
                    }
                }
            }
        }
        .navigationTitle("My Sites")
        .toolbar { EditButton() }
    }

    private func add() {
        sites.add(new)
        new = ""
    }
}

struct SettingsView: View {
    @ObservedObject var sites: Sites
    @ObservedObject var shields: Shields
    @ObservedObject var themes: ThemeStore
    @AppStorage("engine") private var engine = "DuckDuckGo"
    @AppStorage("saver") private var saver = false
    @AppStorage("homeMode") private var homeMode = 0
    @AppStorage("autoFillPrompt") private var autoPrompt = true
    @AppStorage("barStyle") private var barStyle = 0
    @AppStorage("barColor") private var barColor = "System"
    @AppStorage("adaptiveText") private var adaptiveText = true
    @AppStorage("textColor") private var textColor = "System"
    @AppStorage("lockPrivate") private var lockPrivate = true
    @AppStorage("autoSavePasswords") private var autoSave = false
    var openVault: () -> Void
    var openVPN: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Search Engine") {
                    Picker("Search with", selection: $engine) {
                        ForEach(Engines.names, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    NavigationLink {
                        ThemeSettings(themes: themes)
                    } label: {
                        LabeledContent("Themes", value: themes.homeImage != nil && themes.matchPhoto ? "Photo" : themes.current.name)
                    }
                    Picker("Bar Style", selection: $barStyle) {
                        Text("Glass").tag(0)
                        Text("Solid").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if barStyle == 1 {
                        HStack(spacing: 10) {
                            ForEach(BarColors.names, id: \.self) { n in
                                Circle()
                                    .fill(BarColors.swatch(n))
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                    .overlay(Circle().stroke(Color.accentColor, lineWidth: barColor == n ? 2.5 : 0).padding(-4))
                                    .contentShape(Circle())
                                    .onTapGesture { barColor = n }
                                    .accessibilityLabel(n)
                            }
                        }
                        .padding(.vertical, 6)
                        Text(barColor == "System" ? "System follows the page's light or dark look." : barColor)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Adapt Text to Page", isOn: $adaptiveText)
                    if !adaptiveText {
                        HStack(spacing: 10) {
                            ForEach(TextColors.names, id: \.self) { n in
                                Circle()
                                    .fill(TextColors.color(n) ?? Color(.label))
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                                    .overlay(Circle().stroke(Color.accentColor, lineWidth: textColor == n ? 2.5 : 0).padding(-4))
                                    .contentShape(Circle())
                                    .onTapGesture { textColor = n }
                                    .accessibilityLabel(n)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(adaptiveText
                         ? "Icons and text switch between light and dark to stay readable on each page."
                         : "Icons and text use \(textColor == "System" ? "your phone's light or dark mode" : textColor.lowercased()), with the bar shaded to keep it readable.")
                }
                Section("Home Page") {
                    Picker("Show", selection: $homeMode) {
                        Text("Frequently Visited").tag(0)
                        Text("My Sites").tag(1)
                    }
                    .pickerStyle(.segmented)
                    NavigationLink("Edit My Sites") { MySitesEditor(sites: sites) }
                    Button("Clear Visit History", role: .destructive) { sites.clearVisits() }
                }
                Section {
                    NavigationLink("Shields") { ShieldsSettings(shields: shields) }
                    Button("VPN") { openVPN() }
                    Toggle("Lock Private Tabs", isOn: $lockPrivate)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Private tabs are hidden behind Face ID when you leave the app, and covered in the app switcher.")
                }
                Section {
                    Toggle("Extreme Battery Saver", isOn: $saver)
                } footer: {
                    Text("Switches the app to dark mode, turns off every animation, caps page animations at 30 fps and keeps only 2 tabs awake.")
                }
                Section {
                    Toggle("Save Passwords Automatically", isOn: $autoSave)
                    Toggle("Offer to Fill Saved Passwords", isOn: $autoPrompt)
                    Button("Passwords and Cards") { openVault() }
                } header: {
                    Text("Passwords")
                } footer: {
                    Text("Automatic saving stores new or changed passwords in your vault without asking (never in private tabs). Filling always needs Face ID.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

// MARK: Password tools

enum PasswordTools {
    enum Strength: Int { case weak, fair, strong }

    // Rough entropy: length × log2(size of the character sets used).
    static func strength(_ p: String) -> Strength {
        var pool = 0
        if p.contains(where: { $0.isLowercase }) { pool += 26 }
        if p.contains(where: { $0.isUppercase }) { pool += 26 }
        if p.contains(where: { $0.isNumber }) { pool += 10 }
        if p.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        let bits = Double(p.count) * log2(Double(max(pool, 1)))
        if bits >= 70 { return .strong }
        if bits >= 48 { return .fair }
        return .weak
    }

    static func color(_ s: Strength) -> Color {
        switch s {
        case .weak: return .red
        case .fair: return .orange
        case .strong: return .green
        }
    }

    static func label(_ s: Strength) -> String {
        switch s {
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .strong: return "Strong"
        }
    }

    // Unbiased random index from the system's secure random generator.
    private static func secureIndex(_ n: Int) -> Int {
        let limit = UInt32.max - UInt32.max % UInt32(n)
        while true {
            var r: UInt32 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &r)
            if r < limit { return Int(r % UInt32(n)) }
        }
    }

    // Apple-style: three groups of six (e.g. kwfhum-4teqdo-pazJiv), with one capital and one digit.
    static func generate() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyz23456789")
        var g = (0..<18).map { _ in chars[secureIndex(chars.count)] }
        let upperAt = secureIndex(18)
        var digitAt = secureIndex(18)
        while digitAt == upperAt { digitAt = secureIndex(18) }
        g[upperAt] = Character(String(g[upperAt]).uppercased() == String(g[upperAt]) ? "K" : String(g[upperAt]).uppercased())
        g[digitAt] = Array("23456789")[secureIndex(8)]
        let s = String(g)
        return [s.prefix(6), s.dropFirst(6).prefix(6), s.dropFirst(12)].map(String.init).joined(separator: "-")
    }

    // Local-only clipboard copy that expires after a minute.
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
    }
}

// MARK: Vault screen

struct VaultView: View {
    @ObservedObject var vault: Vault
    var fill: (Login?, Card?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
    @State private var revealed: Set<UUID> = []
    @State private var copied: UUID?
    @State private var editing: Login?
    @State private var addingCard = false
    @State private var importing = false
    @State private var msg = ""
    @State private var unlocking = false
    @State private var spin = false
    @State private var appeared = false

    private let bg = LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.16), Color(red: 0.01, green: 0.02, blue: 0.05)],
                                    startPoint: .top, endPoint: .bottom)

    private func unlock() async {
        unlocking = true
        await vault.unlock()
        unlocking = false
        if vault.unlocked { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()
                if vault.unlocked {
                    unlockedView.transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    lockView.transition(.opacity)
                }
                if phase != .active {
                    // Hidden in the app switcher.
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.white)
                    }
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: vault.unlocked)
            .navigationTitle(vault.unlocked ? "Vault" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if vault.unlocked {
                    ToolbarItem(placement: .primaryAction) {
                        Button { withAnimation { vault.lock() } } label: { Image(systemName: "lock") }
                            .accessibilityLabel("Lock vault")
                    }
                }
            }
            .sheet(item: $editing) { l in
                LoginEditor(login: l, isNew: !vault.logins.contains { $0.id == l.id }) { saved in
                    vault.update(saved)
                } delete: { id in
                    vault.deleteLogin(id)
                }
            }
            .sheet(isPresented: $addingCard) { CardEditor { vault.cards.append($0); vault.save() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { r in
                if case .success(let url) = r, url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let t = try? String(contentsOf: url, encoding: .utf8) {
                        msg = "Imported \(vault.importCSV(t)) logins. Delete the CSV file now."
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { if !vault.unlocked { await unlock() } }
    }

    // MARK: Locked

    private var lockView: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(AngularGradient(colors: [.cyan, .blue, .purple, .cyan], center: .center), lineWidth: 3)
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 5).repeatForever(autoreverses: false), value: spin)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 118, height: 118)
                Image(systemName: unlocking ? "faceid" : "lock.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: unlocking)
            }
            VStack(spacing: 6) {
                Text("Vault Locked").font(.title2.bold()).foregroundStyle(.white)
                Text("Protected by Face ID and the iPhone Keychain")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            Button { Task { await unlock() } } label: {
                Label("Unlock with Face ID", systemImage: "faceid")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .padding(.horizontal, 40)
        }
        .onAppear { spin = true }
    }

    // MARK: Unlocked

    private var filteredLogins: [Login] {
        let q = query.lowercased()
        let list = vault.logins.sorted { $0.site.lowercased() < $1.site.lowercased() }
        return q.isEmpty ? list : list.filter { $0.site.lowercased().contains(q) || $0.user.lowercased().contains(q) }
    }

    private var unlockedView: some View {
        let weak = vault.logins.filter { PasswordTools.strength($0.pass) == .weak }.count
        let reusedSet = vault.reusedPasswords
        let reused = vault.logins.filter { reusedSet.contains($0.pass) }.count
        return ScrollView {
            VStack(spacing: 18) {
                statusCard(weak: weak, reused: reused)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    TextField("Search vault", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                }
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 10) {
                    actionButton("Add Login", "plus") {
                        editing = Login(site: "", user: "", pass: PasswordTools.generate())
                    }
                    actionButton("Add Card", "creditcard") { addingCard = true }
                    actionButton("Import", "square.and.arrow.down") { importing = true }
                }
                if !msg.isEmpty {
                    Text(msg).font(.footnote).foregroundStyle(.white.opacity(0.7))
                }

                sectionTitle("Logins", count: vault.logins.count)
                if filteredLogins.isEmpty {
                    Text(vault.logins.isEmpty ? "No saved logins yet." : "No matches.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(filteredLogins.enumerated()), id: \.element.id) { i, l in
                    loginRow(l, reused: reusedSet.contains(l.pass))
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85).delay(Double(min(i, 12)) * 0.03), value: appeared)
                }

                sectionTitle("Cards", count: vault.cards.count)
                ForEach(vault.cards) { c in cardView(c) }
                if vault.cards.isEmpty {
                    Text("No saved cards.").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { appeared = true }
    }

    private func statusCard(weak: Int, reused: Int) -> some View {
        let healthy = weak == 0 && reused == 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(LinearGradient(colors: healthy ? [.green, .teal] : [.orange, .red],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Image(systemName: healthy ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: vault.unlocked)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(healthy ? "Vault secured" : "Some passwords need attention")
                        .font(.headline).foregroundStyle(.white)
                    Text("Encrypted in the iPhone Keychain · never leaves this device · locks when you leave the app")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(spacing: 8) {
                chip("\(vault.logins.count)", "Logins", .blue)
                chip("\(weak)", "Weak", weak > 0 ? .red : .green)
                chip("\(reused)", "Reused", reused > 0 ? .orange : .green)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(LinearGradient(colors: [.cyan.opacity(0.6), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        )
    }

    private func chip(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(color).contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func actionButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func sectionTitle(_ t: String, count: Int) -> some View {
        HStack {
            Text(t).font(.headline).foregroundStyle(.white)
            Text("\(count)").font(.subheadline).foregroundStyle(.white.opacity(0.5)).contentTransition(.numericText())
            Spacer()
        }
        .padding(.top, 6)
    }

    private func loginRow(_ l: Login, reused: Bool) -> some View {
        let shown = revealed.contains(l.id)
        let st = PasswordTools.strength(l.pass)
        let host = Sites.clean(l.site)
        return HStack(spacing: 12) {
            SiteIcon(host: host.isEmpty ? l.site : host, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(host.isEmpty ? l.site : host).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(l.user.isEmpty ? "No username" : l.user).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(shown ? l.pass : String(repeating: "•", count: min(max(l.pass.count, 8), 14)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    Capsule().fill(PasswordTools.color(st)).frame(width: 6, height: 6)
                    if reused {
                        Text("Reused").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 4)
            iconButton(shown ? "eye.slash" : "eye", shown ? "Hide password" : "Show password") {
                withAnimation(.snappy) {
                    if shown { revealed.remove(l.id) } else { revealed.insert(l.id) }
                }
            }
            iconButton(copied == l.id ? "checkmark" : "doc.on.doc", "Copy password") {
                PasswordTools.copy(l.pass)
                withAnimation(.snappy) { copied = l.id }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == l.id { withAnimation { copied = nil } } }
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { fill(l, nil); dismiss() }
        .contextMenu {
            Button { fill(l, nil); dismiss() } label: { Label("Fill on Page", systemImage: "arrow.up.forward.app") }
            Button { editing = l } label: { Label("Edit", systemImage: "pencil") }
            Button { PasswordTools.copy(l.user) } label: { Label("Copy Username", systemImage: "person") }
            Button(role: .destructive) { withAnimation { vault.deleteLogin(l.id) } } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func iconButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.08), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func cardView(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "creditcard.fill").font(.title3)
                Spacer()
                Text(c.exp).font(.caption.monospaced())
            }
            Text("••••  ••••  ••••  \(String(c.number.suffix(4)))")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
            Text(c.name.isEmpty ? "Card" : c.name.uppercased()).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.75), Color(red: 0.45, green: 0.2, blue: 0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .contentShape(Rectangle())
        .onTapGesture { fill(nil, c); dismiss() }
        .contextMenu {
            Button { fill(nil, c); dismiss() } label: { Label("Fill on Page", systemImage: "arrow.up.forward.app") }
            Button(role: .destructive) { withAnimation { vault.deleteCard(c.id) } } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct LoginEditor: View {
    @State var login: Login
    var isNew: Bool
    var save: (Login) -> Void
    var delete: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var show = false

    var body: some View {
        let st = PasswordTools.strength(login.pass)
        NavigationStack {
            Form {
                Section("Site") {
                    TextField("example.com", text: $login.site)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Username or email", text: $login.user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    HStack {
                        Group {
                            if show { TextField("Password", text: $login.pass) } else { SecureField("Password", text: $login.pass) }
                        }
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { show.toggle() } label: { Image(systemName: show ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(show ? "Hide password" : "Show password")
                    }
                    HStack(spacing: 10) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.2))
                                Capsule().fill(PasswordTools.color(st))
                                    .frame(width: g.size.width * CGFloat(st.rawValue + 1) / 3)
                            }
                        }
                        .frame(height: 6)
                        Text(PasswordTools.label(st)).font(.caption.weight(.semibold)).foregroundStyle(PasswordTools.color(st))
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: st)
                    Button {
                        withAnimation(.snappy) { login.pass = PasswordTools.generate(); show = true }
                    } label: {
                        Label("Generate Strong Password", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("Password")
                }
                if !isNew {
                    Section {
                        Button("Delete Login", role: .destructive) { delete(login.id); dismiss() }
                    }
                }
            }
            .navigationTitle(isNew ? "New Login" : "Edit Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(login); dismiss() }
                        .disabled(login.site.isEmpty || login.pass.isEmpty)
                }
            }
        }
    }
}

struct CardEditor: View {
    var save: (Card) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var number = ""
    @State private var exp = ""
    @State private var cvc = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name on card", text: $name)
                TextField("Card number", text: $number).keyboardType(.numberPad)
                TextField("MM/YY", text: $exp).keyboardType(.numbersAndPunctuation)
                SecureField("Security code", text: $cvc).keyboardType(.numberPad)
            }
            .navigationTitle("New Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(Card(name: name, number: number.filter(\.isNumber), exp: exp, cvc: cvc))
                        dismiss()
                    }
                    .disabled(number.filter(\.isNumber).count < 12)
                }
            }
        }
    }
}

// MARK: Main screen

enum Sheet: Identifiable {
    case vault, settings, calendar, vpn, tabs, shields, history
    var id: Int {
        switch self {
        case .history: return 6
        case .vault: return 0
        case .settings: return 1
        case .calendar: return 2
        case .vpn: return 3
        case .tabs: return 4
        case .shields: return 5
        }
    }
}

struct ContentView: View {
    @StateObject private var tabs = Tabs()
    @StateObject private var sites = Sites()
    @StateObject private var vault = Vault()
    @StateObject private var vpnService = VPNService()
    @StateObject private var shields = Shields()
    @StateObject private var themes = ThemeStore()
    @StateObject private var history = HistoryStore()
    @Environment(\.scenePhase) private var phase
    @AppStorage("lockPrivate") private var lockPrivate = true
    @State private var privateLocked = false
    @State private var historyPane: Pane?
    @AppStorage("block") private var blockOn = true
    @AppStorage("saver") private var saver = false
    @AppStorage("engine") private var engine = "DuckDuckGo"
    @State private var split: CGFloat = 0.5
    @State private var dragging = false
    @State private var lastTap = Date.distantPast
    @State private var shieldsPane: Pane?
    @State private var sheet: Sheet?
    @State private var pending: Login?
    @State private var calTitle = ""
    @State private var calURL = ""
    @State private var choosePane: Pane?
    @State private var chooseList: [Login] = []
    @AppStorage("autoFillPrompt") private var autoPrompt = true
    @AppStorage("autoSavePasswords") private var autoSave = false
    @State private var toast: String?

    // Battery saver: dark only. Private tab on top: dark. Otherwise the theme decides.
    private var appScheme: ColorScheme? {
        if saver || leftIsPrivate { return .dark }
        return themes.current.scheme
    }

    private func showToast(_ text: String) {
        withAnimation(anim(.spring(response: 0.35, dampingFraction: 0.8))) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(anim(.easeOut(duration: 0.3))) { if toast == text { toast = nil } }
        }
    }

    var body: some View {
        GeometryReader { root in
            let safe = ContentView.windowInsets()
            let portrait = root.size.height >= root.size.width
            let topOwnStrip = tabs.split && portrait   // the top pane draws its own strip under the status bar
            VStack(spacing: 0) {
                if !topOwnStrip {
                    TopStrip(pane: tabs.pane(tabs.left), safeTop: safe.top)
                }
                deck(portrait: portrait, safe: safe)
            }
            .ignoresSafeArea(.container, edges: .vertical)
            .background(themes.current.strip.ignoresSafeArea())
            .overlay {
                EdgeDock(tabs: tabs, saver: saver, privateMode: leftIsPrivate, openTabs: openTabs)
            }
            .overlay(alignment: .top) {
                if let toast {
                    Label(toast, systemImage: "key.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .sdGlass(Capsule())
                        .padding(.top, safe.top + 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .environment(\.sdTheme, themes.current)
        .environment(\.sdHomeImage, themes.homeImage)
        .tint(themes.current.accent)
        .preferredColorScheme(appScheme)
        .transaction { t in
            if saver { t.animation = nil; t.disablesAnimations = true }
        }
        .sheet(item: $sheet) { s in
            sheetView(s)
                .preferredColorScheme(appScheme)
                .tint(themes.current.accent)
                .transaction { t in if saver { t.animation = nil; t.disablesAnimations = true } }
        }
        .alert("Save password?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Save") { if let p = pending { vault.logins.append(p); vault.save() }; pending = nil }
            Button("Not now", role: .cancel) { pending = nil }
        } message: { Text(pending?.site ?? "") }
        .confirmationDialog("Choose a saved login",
                            isPresented: Binding(get: { choosePane != nil }, set: { if !$0 { choosePane = nil } }),
                            titleVisibility: .visible) {
            ForEach(chooseList) { l in
                Button(l.user.isEmpty ? l.site : l.user) {
                    choosePane?.fill(login: l)
                    choosePane = nil
                }
            }
            Button("Cancel", role: .cancel) { choosePane = nil }
        }
        .task {
            Pane.ruleProvider = { host in shields.rules(for: host) }
            Pane.youtubeProvider = { host in shields.youtubeOn(for: host) }
            Pane.onBlocked = { shields.countBlocked() }
            tabs.configure = { p in configure(p) }
            tabs.allLive.forEach { configure($0) }
            applySaver()
            await shields.prepare()
        }
        .onChange(of: shields.version) { _, _ in applyShields() }
        .onChange(of: blockOn) { _, _ in shields.masterChanged() }
        .onChange(of: saver) { _, _ in applySaver() }
        .onChange(of: themes.current) { _, _ in tabs.allLive.forEach { $0.objectWillChange.send() } }
        .onChange(of: engine) { _, _ in tabs.visible.forEach { tabs.pane($0).goHome() } }
        .onChange(of: phase) { _, p in
            if p != .active { vault.lock() }
            if p == .background && lockPrivate && tabs.privateCount > 0 { privateLocked = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            tabs.sleepHidden()
        }
    }

    // MARK: Layout

    // Status bar and home indicator sizes from the window (unaffected by the keyboard).
    static func windowInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.keyWindow?.safeAreaInsets ?? .zero
    }

    private var leftIsPrivate: Bool { tabs.info(tabs.left)?.isPrivate ?? false }

    private func openTabs() {
        tabs.snapshotVisible()
        sheet = .tabs
    }

    private func unlockPrivate() {
        Task {
            let ok = try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private tabs")
            if ok == true { await MainActor.run { privateLocked = false } }
        }
    }

    private func deck(portrait: Bool, safe: UIEdgeInsets) -> some View {
        GeometryReader { geo in
            let horizontal = !portrait
            let total = horizontal ? geo.size.width : geo.size.height
            let gap: CGFloat = 5
            let firstSize = (total - gap) * split
            ZStack(alignment: .topLeading) {
                if tabs.split {
                    let layout = horizontal ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
                    layout {
                        // Portrait: top pane's bar sits in a strip at the top beside the tab pill, bottom pane's at the bottom.
                        // Landscape: both slim bars sit at the bottom of their side.
                        paneView(tabs.left, slot: 0, compact: true, atTop: portrait, safeTop: safe.top,
                                 bottomInset: horizontal ? safe.bottom : 0)
                            .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                        paneView(tabs.right, slot: 1, compact: true, bottomInset: safe.bottom)
                    }
                    handle(horizontal: horizontal, total: total, pos: firstSize + gap / 2, size: geo.size)
                } else {
                    paneView(tabs.left, slot: 0, bottomInset: safe.bottom)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color(.separator).opacity(dragging ? 0.9 : 0.55))
            .coordinateSpace(.named("deck"))
        }
    }

    private func anim(_ a: Animation) -> Animation? { saver ? nil : a }

    // Invisible when idle: a 1pt hairline plus a wide, transparent touch strip.
    // The grip only appears while it's held or dragged.
    private func handle(horizontal: Bool, total: CGFloat, pos: CGFloat, size: CGSize) -> some View {
        let hit: CGFloat = 36
        return ZStack {
            Color.clear
            Capsule()
                .fill(Color.primary.opacity(0.55))
                .frame(width: horizontal ? 5 : (dragging ? 64 : 40), height: horizontal ? (dragging ? 64 : 40) : 5)
                .opacity(dragging ? 1 : 0)
                .scaleEffect(dragging ? 1 : 0.5)
                .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: 6)
        }
        .frame(width: horizontal ? hit : size.width, height: horizontal ? size.height : hit)
        .contentShape(Rectangle())
        .position(x: horizontal ? pos : size.width / 2, y: horizontal ? size.height / 2 : pos)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("deck"))
                .onChanged { v in
                    if !dragging {
                        withAnimation(anim(.spring(response: 0.25, dampingFraction: 0.7))) { dragging = true }
                    }
                    let moved = abs(horizontal ? v.translation.width : v.translation.height)
                    if moved > 2 {
                        let p = horizontal ? v.location.x : v.location.y
                        withAnimation(anim(.interactiveSpring(response: 0.2, dampingFraction: 0.86))) {
                            split = min(0.98, max(0.02, p / total))
                        }
                    }
                }
                .onEnded { v in
                    let moved = abs(horizontal ? v.translation.width : v.translation.height)
                    let predicted = (horizontal ? v.predictedEndLocation.x : v.predictedEndLocation.y) / total
                    if moved < 4 {
                        if Date().timeIntervalSince(lastTap) < 0.35 {
                            withAnimation(anim(.spring(response: 0.4, dampingFraction: 0.8))) { split = 0.5 }
                        }
                        lastTap = Date()
                    } else if split > 0.9 || predicted > 1.0 {
                        collapse(keep: 0)
                    } else if split < 0.1 || predicted < 0.0 {
                        collapse(keep: 1)
                    } else {
                        withAnimation(anim(.spring(response: 0.35, dampingFraction: 0.8))) {
                            split = min(0.85, max(0.15, split))
                        }
                    }
                    withAnimation(anim(.easeOut(duration: 0.35))) { dragging = false }
                }
        )
    }

    // Dragging the divider off an edge closes split view, keeping the pane that filled the screen.
    private func collapse(keep slot: Int) {
        withAnimation(anim(.spring(response: 0.3, dampingFraction: 0.9))) { split = slot == 0 ? 1 : 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (saver ? 0 : 0.28)) {
            tabs.closeSplit(keep: slot)
            split = 0.5
        }
    }

    private func paneView(_ id: UUID, slot: Int, compact: Bool = false, atTop: Bool = false,
                          safeTop: CGFloat = 0, bottomInset: CGFloat = 0) -> some View {
        let p = tabs.pane(id)
        return PaneView(
            pane: p,
            sites: sites,
            history: history,
            actions: PaneActions(
                autofill: { autofill(p) },
                calendar: { calTitle = p.title.isEmpty ? p.host : p.title; calURL = p.address; sheet = .calendar },
                settings: { sheet = .settings },
                vpn: { sheet = .vpn },
                vpnOn: vpnService.status == .connected,
                newTab: { withAnimation(anim(.snappy)) { tabs.newTab(slot: slot) } },
                shields: { shieldsPane = p; sheet = .shields },
                shieldsUp: blockOn && shields.isUp(p.host),
                totalBlocked: shields.totalBlocked,
                newPrivateTab: { withAnimation(anim(.snappy)) { tabs.newTab(slot: slot, isPrivate: true) } },
                history: { historyPane = p; sheet = .history },
                privateLocked: privateLocked,
                unlockPrivate: unlockPrivate
            ),
            compact: compact,
            atTop: atTop,
            safeTop: safeTop,
            bottomInset: bottomInset,
            trailingRoom: 0
        )
        .id(id)
    }

    @ViewBuilder private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .vault: VaultView(vault: vault, fill: fill)
        case .settings: SettingsView(sites: sites, shields: shields, themes: themes, openVault: { sheet = .vault }, openVPN: { sheet = .vpn })
        case .calendar: EventEditor(title: calTitle, url: calURL).ignoresSafeArea()
        case .vpn: VPNView(vpn: vpnService)
        case .tabs: TabsView(tabs: tabs, startPrivate: leftIsPrivate, privateLocked: privateLocked, unlock: unlockPrivate)
        case .history:
            HistoryView(history: history, sites: sites) { text in historyPane?.load(text) }
        case .shields:
            if let p = shieldsPane {
                ShieldsView(shields: shields, pane: p).presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Behaviour

    private func configure(_ p: Pane) {
        p.onCredential = { login in
            if autoSave {
                vault.upsert(login)
                showToast("Password saved for \(Sites.clean(login.site))")
            } else {
                pending = login
            }
        }
        p.onVisit = { sites.record($0) }
        p.onPageLoaded = { url, title in history.addVisit(url, title: title) }
        p.onSearch = { history.addSearch($0) }
        p.onLoginField = { [weak p] in
            guard let p, autoPrompt, !vault.match(host: p.host).isEmpty else { return }
            p.offerFill = true
        }
        p.applyRules(host: p.host)
        p.applyFPS()
    }

    private func autofill(_ p: Pane) {
        Task {
            if !vault.unlocked { await vault.unlock() }
            guard vault.unlocked else { return }
            if p.hasLogin {
                let found = vault.match(host: p.host)
                if found.count == 1 { p.fill(login: found[0]); return }
                if found.count > 1 { chooseList = found; choosePane = p; return }
            }
            if p.hasCard, let c = vault.cards.first { p.fill(card: c); return }
            sheet = .vault
        }
    }

    // Re-checks every open tab's block lists; reloads only when the change came from you.
    private func applyShields() {
        let reload = shields.pendingReload
        shields.pendingReload = false
        for p in tabs.allLive {
            let changed = p.applyRules(host: p.host)
            if changed && reload && !p.isHome { p.webView.reload() }
        }
    }

    private func applySaver() {
        UIView.setAnimationsEnabled(!saver)   // also stops UIKit animations: sheets, menus, scrolling bounces
        Pane.fps = saver ? 30 : 0
        tabs.maxLive = saver ? 2 : 4
        tabs.allLive.forEach { $0.applyFPS() }
        tabs.trim()
    }

    private func fill(_ l: Login?, _ c: Card?) {
        for id in tabs.visible {
            let p = tabs.pane(id)
            if let l { p.fill(login: l) }
            if let c { p.fill(card: c) }
        }
    }
}
