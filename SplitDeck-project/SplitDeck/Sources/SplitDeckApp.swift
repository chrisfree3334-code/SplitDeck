import SwiftUI
import WebKit
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif
import LocalAuthentication
import Security
import UniformTypeIdentifiers
import EventKit
import EventKitUI
import NetworkExtension
import PhotosUI

@main
struct SplitDeckApp: App {
    init() {
        // 1.2 ships with a solid address bar and the split view button in the bar (island off).
        // Applied once on upgrade; your own changes after that are kept.
        let d = UserDefaults.standard
        if !d.bool(forKey: "defaults-1.2") {
            d.set(false, forKey: "showIsland")
            d.set(1, forKey: "barStyle")
            d.set(true, forKey: "defaults-1.2")
        }
    }
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

extension Color {
    // A calmer version of a colour for large tinted areas: most of the saturation taken out.
    func muted(_ amount: CGFloat = 0.55) -> Color {
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &sat, brightness: &b, alpha: &a) else { return self }
        return Color(hue: Double(h), saturation: Double(sat * (1 - amount)), brightness: Double(min(b * 0.9 + 0.06, 1)))
    }
}

// Space the floating bars cover at the top and bottom of a page.
struct BarCover: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}
struct BarCoverKey: PreferenceKey {
    static let defaultValue = BarCover()
    static func reduce(value: inout BarCover, nextValue: () -> BarCover) {
        let n = nextValue()
        value.top = max(value.top, n.top)
        value.bottom = max(value.bottom, n.bottom)
    }
}

// Bar surface: a solid colour (default) or Liquid Glass. Split view bars are always solid.
// `rim` draws a thin outline in the theme's accent so the bar reads as one piece.
struct SDSurface: ViewModifier {
    let shape: AnyShape
    let dark: Bool?
    var clear = false
    var solid = false
    var rim = false
    @AppStorage("barStyle") private var style = 1
    @AppStorage("barColor") private var colorName = "System"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sdTheme) private var theme

    private var isDark: Bool { dark ?? (scheme == .dark) }
    private var rimColor: Color { theme.accent.muted().opacity(isDark ? 0.55 : 0.42) }

    @ViewBuilder func body(content: Content) -> some View {
        if style == 1 || solid {
            content
                .environment(\.colorScheme, BarColors.isDark(colorName, scheme: scheme) ? .dark : .light)
                .background {
                    shape.fill(BarColors.color(colorName, scheme: scheme))
                        .overlay(colorName == "System" ? shape.fill(theme.accent.muted().opacity(isDark ? 0.1 : 0.06)) : nil)
                }
                .overlay(shape.stroke(rim ? rimColor : Color.primary.opacity(0.08), lineWidth: rim ? 1.2 : 0.5))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        } else {
            let tint: Color = dark.map {
                $0 ? Color.black.opacity(clear ? 0.24 : 0.42) : Color.white.opacity(clear ? 0.34 : 0.62)
            } ?? Color(.systemBackground).opacity(clear ? 0.26 : 0.5)
            if #available(iOS 26.0, *) {
                content.glassEffect((clear ? Glass.clear : Glass.regular).tint(tint).interactive(), in: shape)
                    .overlay(rim ? shape.stroke(rimColor, lineWidth: 1.2) : nil)
            } else {
                content.background(shape.fill(tint)).background(.regularMaterial, in: shape)
                    .overlay(rim ? shape.stroke(rimColor, lineWidth: 1.2) : nil)
            }
        }
    }
}

extension View {
    func sdGlass<S: Shape>(_ shape: S, dark: Bool? = nil, clear: Bool = false, solid: Bool = false, rim: Bool = false) -> some View {
        modifier(SDSurface(shape: AnyShape(shape), dark: dark, clear: clear, solid: solid, rim: rim))
    }
}

func q(_ s: String) -> String {
    (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
}

// ProMotion for pages: WebKit holds page rendering near 60 fps unless told otherwise. This flips
// that internal switch so animations and scrolling effects on pages can run at up to 120 fps.
// Left alone in battery saver. If the switch ever goes away, nothing happens.
enum WebFrameRate {
    static func unlock(_ prefs: WKPreferences, on: Bool) {
        let listSel = NSSelectorFromString("_features")
        let setSel = NSSelectorFromString("_setEnabled:forFeature:")
        let keySel = NSSelectorFromString("key")
        guard let listM = class_getClassMethod(WKPreferences.self, listSel),
              let setM = class_getInstanceMethod(WKPreferences.self, setSel) else { return }
        typealias ListFn = @convention(c) (AnyObject, Selector) -> NSArray?
        typealias SetFn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let list = unsafeBitCast(method_getImplementation(listM), to: ListFn.self)(WKPreferences.self as AnyObject, listSel) ?? []
        let set = unsafeBitCast(method_getImplementation(setM), to: SetFn.self)
        for case let f as NSObject in list where f.responds(to: keySel) {
            if (f.value(forKey: "key") as? String) == "PreferPageRenderingUpdatesNear60FPSEnabled" {
                set(prefs, setSel, !on, f)
            }
        }
    }
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

// MARK: Page zoom

// Page zoom: one default for every site, plus the level you last chose on each site (if remembered).
enum Zoom {
    static let steps: [Double] = [0.5, 0.67, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5]
    private static var d: UserDefaults { .standard }
    static var defaultLevel: Double { d.object(forKey: "zoomDefault") as? Double ?? 1.0 }
    static var remember: Bool { d.object(forKey: "zoomRemember") as? Bool ?? true }
    static var sites: [String: Double] { d.dictionary(forKey: "zoomSites") as? [String: Double] ?? [:] }
    static func key(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    static func level(for host: String) -> Double {
        guard remember, !host.isEmpty else { return defaultLevel }
        return sites[key(host)] ?? defaultLevel
    }

    static func store(_ z: Double, for host: String) {
        guard remember, !host.isEmpty else { return }
        var s = sites
        s[key(host)] = abs(z - defaultLevel) < 0.001 ? nil : z
        d.set(s, forKey: "zoomSites")
    }

    static func step(from z: Double, up: Bool) -> Double {
        up ? (steps.first { $0 > z + 0.001 } ?? steps.last!) : (steps.last { $0 < z - 0.001 } ?? steps.first!)
    }

    static func label(_ z: Double) -> String { "\(Int((z * 100).rounded()))%" }
}

// MARK: Bookmarks

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var added = Date()
    var host: String {
        let h = URL(string: url)?.host ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

final class Bookmarks: ObservableObject {
    static let shared = Bookmarks()
    @Published private(set) var items: [Bookmark] = []

    static let fileURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("bookmarks.json")
    }()

    init() {
        if let d = try? Data(contentsOf: Bookmarks.fileURL),
           let l = try? JSONDecoder().decode([Bookmark].self, from: d) { items = l }
    }

    func find(_ url: String) -> Bookmark? { items.first { $0.url == url } }

    func toggle(url: String, title: String) {
        if let b = find(url) { remove(b.id) } else { add(url: url, title: title) }
    }

    func add(url: String, title: String) {
        guard !url.isEmpty, find(url) == nil else { return }
        items.insert(Bookmark(title: title.isEmpty ? url : title, url: url), at: 0)
        save()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        save()
    }

    // Adds any it doesn't already have. Returns how many were new.
    func merge(_ new: [Bookmark]) -> Int {
        var seen = Set(items.map(\.url))
        let fresh = new.filter { seen.insert($0.url).inserted }
        items.append(contentsOf: fresh)
        save()
        return fresh.count
    }

    private func save() {
        let snapshot = items
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: Bookmarks.fileURL, options: .atomic) }
        }
    }
}

// MARK: Translation settings

enum Translate {
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"), ("ru", "Russian"),
        ("uk", "Ukrainian"), ("ar", "Arabic"), ("hi", "Hindi"), ("id", "Indonesian"), ("th", "Thai"),
        ("vi", "Vietnamese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]
    static var target: String {
        UserDefaults.standard.string(forKey: "translateTo") ?? (Locale.current.language.languageCode?.identifier ?? "en")
    }
    static var offer: Bool { UserDefaults.standard.object(forKey: "offerTranslate") as? Bool ?? true }
    static func name(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }
}

// Links into the app: splitdeck://open?url=… or splitdeck://example.com/page (handy from Shortcuts).
enum DeepLink {
    static func target(_ url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.absoluteString
        case "splitdeck":
            if url.host == "open" {
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            }
            let rest = url.absoluteString.dropFirst("splitdeck://".count)
            return rest.isEmpty ? nil : String(rest)
        default:
            return nil
        }
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

    // A fresh Face ID scan (passcode as the fallback) before a change that can't be undone.
    // A new context every time, so an earlier unlock is never reused.
    static func confirm(_ reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.touchIDAuthenticationAllowableReuseDuration = 0
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        return ok
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
        for path in ["youtube\\.com/api/stats/ads", "youtube\\.com/pagead/",
                     "youtube\\.com/get_midroll_", "youtube\\.com/api/stats/qoe\\?.*adformat"] {
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

    static let decline = "(function(){if(/(^|\\.)(accounts|consent)\\.(google|youtube)\\.[a-z.]+$/.test(location.hostname))return;var s=['#onetrust-reject-all-handler','#CybotCookiebotDialogBodyButtonDecline','#didomi-notice-disagree-button','.fc-cta-do-not-consent','button.cc-deny','[data-testid=reject-all]','[aria-label=\"Reject all\"]','.js-reject-cookies'];var n=0;var t=setInterval(function(){s.forEach(function(x){var b=document.querySelector(x);if(b)b.click()});if(++n>20)clearInterval(t)},500)})();"


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
    @Published var status: NEVPNStatus = .disconnected
    @Published var errorMessage: String?
    @Published var selectedServer = VPNServer(provider: "", name: "", address: "", remoteID: "")
    @Published var isConfigured: Bool = false

    private let manager = NEVPNManager.shared()

    init() {
        if let addr = UserDefaults.standard.string(forKey: "vpn_server_address"), !addr.isEmpty {
            let provider = UserDefaults.standard.string(forKey: "vpn_provider") ?? ""
            selectedServer = VPNServer(provider: provider, name: provider.isEmpty ? addr : provider, address: addr,
                                       remoteID: UserDefaults.standard.string(forKey: "vpn_remote_id") ?? addr)
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
            manager.localizedDescription = server.provider.isEmpty ? "SplitDeck VPN" : "SplitDeck VPN (\(server.provider))"
            manager.isEnabled = true
            selectedServer = server

            UserDefaults.standard.set(server.address, forKey: "vpn_server_address")
            UserDefaults.standard.set(server.remoteID, forKey: "vpn_remote_id")
            UserDefaults.standard.set(server.provider, forKey: "vpn_provider")
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

    @State private var provider = UserDefaults.standard.string(forKey: "vpn_provider") ?? ""
    @State private var server = UserDefaults.standard.string(forKey: "vpn_server_address") ?? ""
    @State private var remoteID = UserDefaults.standard.string(forKey: "vpn_remote_id") ?? ""
    @State private var username = UserDefaults.standard.string(forKey: "vpn_saved_username") ?? ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
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

                Section {
                    TextField("Provider name (optional)", text: $provider)
                    TextField("Server address", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Remote ID (if your provider gives one)", text: $remoteID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField(vpn.isConfigured ? "Password (re-enter to change)" : "Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Your VPN Provider")
                } footer: {
                    Text("Use the manual IKEv2 settings from your VPN provider's website or account page. Your VPN password is stored in the iPhone Keychain.")
                }

                Section {
                    Button {
                        let addr = server.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rid = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = provider.trimmingCharacters(in: .whitespacesAndNewlines)
                        let target = VPNServer(provider: name, name: name.isEmpty ? addr : name, address: addr,
                                               remoteID: rid.isEmpty ? addr : rid)
                        Task {
                            await vpn.configure(server: target, username: username, password: password)
                            if vpn.errorMessage == nil { await vpn.connect() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label(vpn.status == .connected ? "Update and Reconnect" : "Save and Connect", systemImage: "lock.shield")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty || password.isEmpty)
                }

                if let err = vpn.errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("SplitDeck doesn't host VPN servers", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                        Text("Running a VPN that people can trust takes dedicated servers and constant security work, and we don't have the resources to do that well yet. We also chose not to build in free VPN services, because we can't vouch for how they protect or use your data.")
                        Text("So SplitDeck only connects to a VPN provider you choose and enter yourself. Your traffic goes straight from your iPhone to that provider; it never passes through us.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                } header: {
                    Text("Why bring your own VPN?")
                }
            }
            .navigationTitle("VPN")
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
    @Published var canBack = false
    @Published var canForward = false
    @Published var host = ""
    @Published var title = ""
    @Published var isHome = true
    @Published var pageDark: Bool? = nil
    @Published var topDark: Bool? = nil
    @Published var bottomColor: Color? = nil
    // Counted on every blocked request, but only published about once a second.
    private(set) var blockedCount = 0
    @Published private(set) var blockedShown = 0
    private var blockedFlush = false
    @Published var zoom: Double = 1
    @Published var foreignLanguage: String?
    @Published var translated = false
    @Published var translating = false
    @Published var translateRequest = 0
    @Published var notice: String?
    private var bottomRGB: [Int] = []
    private var appliedRules: [String]?
    @Published var hiding = false
    @Published var hiddenCount = 0
    @Published var canUndoHide = false
    private var lastHidden: String?
    private var hiddenSels: [String] = []
    var onPageLoaded: ((URL, String) -> Void)?
    var onSearch: ((String) -> Void)?
    var editing = false
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
    }
    static var onBlocked: (() -> Void)?
    private var obs: NSKeyValueObservation?
    private var lastY: CGFloat = 0
    private var scrollRun: CGFloat = 0
    private var barLockUntil: CFTimeInterval = 0
    private var lastScrollAt: CFTimeInterval = 0
    private var tintPending = false
    // Off in Battery Saver, or with the minimal bar switched off: the bar never shrinks.
    static var minimizeBars = true
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
        config.applicationNameForUserAgent = "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Mobile/15E148 Safari/604.1"
        Pane.installScripts(config.userContentController, youtube: false)
        WebFrameRate.unlock(config.preferences, on: !UserDefaults.standard.bool(forKey: "saver"))
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never   // the floating bars set the insets
        wv.scrollView.keyboardDismissMode = .interactive
        wv.isOpaque = false
        webView = wv
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
        config.userContentController.add(WeakHandler(self), name: "hide")
        obs = wv.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            guard let self else { return }
            self.scheduleTint()
            guard Pane.minimizeBars else { return }
            let now = CACurrentMediaTime()
            let y = sv.contentOffset.y + sv.adjustedContentInset.top   // 0 = top of the page
            let dy = y - self.lastY
            self.lastY = y
            // Only a deliberate scroll inside the page moves the bar. Ignored: pages too short to scroll,
            // the rubber-band bounce past the top or bottom, and the jolt from the bar's own resize
            // (a short cool-down after each change stops the shrink / grow / shrink loop).
            let maxY = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom + sv.adjustedContentInset.top
            let scrollable = maxY > 120
            let inBounds = y >= 0 && y <= maxY
            let unlocked = now > self.barLockUntil
            if (sv.isTracking || sv.isDecelerating) && scrollable && inBounds && unlocked {
                if (dy > 0) != (self.scrollRun > 0) { self.scrollRun = 0 }
                self.scrollRun += dy
                if self.scrollRun > 28 && y > 60 && !self.collapsed {
                    self.collapsed = true
                    self.barLockUntil = now + 0.5
                    self.scrollRun = 0
                } else if self.scrollRun < -28 && self.collapsed {
                    self.collapsed = false
                    self.barLockUntil = now + 0.5
                    self.scrollRun = 0
                }
            }
            if y <= 0 && self.collapsed && unlocked && !sv.isDecelerating { self.collapsed = false }
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
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){m.pause()})")
        isHome = true
        collapsed = false
        if !editing { address = "" }
        title = ""
        host = ""
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

    // Tapping the pill: stop any momentum scroll first, then hold the bar open for a moment,
    // so a still-moving page can't fold it straight back into the pill.
    func expandBar() {
        let sv = webView.scrollView
        if sv.isDecelerating { sv.setContentOffset(sv.contentOffset, animated: false) }
        scrollRun = 0
        barLockUntil = CACurrentMediaTime() + 1.2
        if collapsed { collapsed = false }
    }

    // Re-reads the page colours once scrolling settles. One timer at a time, no allocation per scroll event.
    private func scheduleTint() {
        lastScrollAt = CACurrentMediaTime()
        guard !tintPending else { return }
        tintPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.tintCheck() }
    }

    private func tintCheck() {
        let idle = CACurrentMediaTime() - lastScrollAt
        if idle < 0.3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.32 - idle)) { [weak self] in self?.tintCheck() }
            return
        }
        tintPending = false
        detectTint()
    }

    // The floating bars cover part of the page. The page scrolls clear of them, and WebKit lays out
    // fixed headers and footers (cookie bars, YouTube's tab bar) in the uncovered part.
    private var cover = UIEdgeInsets.zero
    func setCover(_ c: BarCover) {
        let e = UIEdgeInsets(top: c.top, left: 0, bottom: c.bottom, right: 0)
        guard e != cover else { return }
        cover = e
        let sv = webView.scrollView
        let atTop = sv.contentOffset.y <= -sv.adjustedContentInset.top + 1
        sv.contentInset = e
        sv.verticalScrollIndicatorInsets = e
        let v = NSValue(uiEdgeInsets: e)
        if webView.responds(to: NSSelectorFromString("setObscuredContentInsets:")) {
            webView.setValue(v, forKey: "obscuredContentInsets")       // iOS 26
        } else if webView.responds(to: NSSelectorFromString("_setObscuredInsets:")) {
            webView.setValue(v, forKey: "obscuredInsets")              // earlier iOS
        }
        if atTop { sv.contentOffset.y = -sv.adjustedContentInset.top }
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
        guard !blockedFlush else { return }
        blockedFlush = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.blockedFlush = false
            if self.blockedShown != self.blockedCount { self.blockedShown = self.blockedCount }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        blockedCount = 0
        if blockedShown != 0 { blockedShown = 0 }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "hide" {
            guard let sel = m.body as? String, !sel.isEmpty else { return }
            if !hiddenSels.contains(sel) { hiddenSels.append(sel) }
            hiddenCount = hiddenSels.count
            lastHidden = sel
            canUndoHide = true
        }
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
        if translated || foreignLanguage != nil || translating { translated = false; foreignLanguage = nil; translating = false }
        let z = Zoom.level(for: webView.url?.host ?? "")
        if abs(webView.pageZoom - z) > 0.001 { webView.pageZoom = z }
        if zoom != z { zoom = z }
        if hiding { hiding = false; canUndoHide = false }
        hiddenSels = []
        hiddenCount = 0
        lastHidden = nil
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
        if Translate.offer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.detectLanguage() }
        }
        // Logins and cards on pages are filled by iOS AutoFill (Passwords app), not by SplitDeck.
    }

    // MARK: Zoom

    func setZoom(_ z: Double) {
        let v = min(max(z, Zoom.steps.first!), Zoom.steps.last!)
        webView.pageZoom = v
        zoom = v
        if !isPrivate { Zoom.store(v, for: host) }
        flash(Zoom.label(v))
    }
    func zoomIn() { setZoom(Zoom.step(from: zoom, up: true)) }
    func zoomOut() { setZoom(Zoom.step(from: zoom, up: false)) }

    // A short message over the address bar.
    func flash(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    // MARK: Translation

    // Reads a sample of the page; if most of it is in another language, the address bar offers to translate.
    func detectLanguage() {
        guard !isHome else { return }
        webView.evaluateJavaScript("(document.body&&document.body.innerText||'').slice(0,4000)") { [weak self] r, _ in
            guard let self, let text = r as? String, text.count > 200 else { return }
            let mine = Translate.target
            DispatchQueue.global(qos: .utility).async {
                let rec = NLLanguageRecognizer()
                rec.processString(text)
                guard let top = rec.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }), top.value > 0.8 else { return }
                let code = String(top.key.rawValue.split(separator: "-").first ?? Substring(top.key.rawValue))
                DispatchQueue.main.async {
                    let foreign: String? = code == mine ? nil : code
                    if self.foreignLanguage != foreign { self.foreignLanguage = foreign }
                }
            }
        }
    }

    func requestTranslation() {
        if translated { showOriginal(); return }
        guard !translating else { return }
        translateRequest += 1
    }

    func showOriginal() {
        webView.evaluateJavaScript("if(window.__sdTr){window.__sdTr.nodes.forEach(function(n,i){n.nodeValue=window.__sdTr.orig[i]})}")
        translated = false
    }

    static let collectTextJS = """
    const skip = new Set(['SCRIPT','STYLE','NOSCRIPT','TEXTAREA','INPUT','CODE','PRE','SVG','svg','MATH']);
    const nodes = [], out = [];
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode(n) {
      const p = n.parentElement;
      if (!p || skip.has(p.tagName) || p.isContentEditable || p.closest('[translate=no],.notranslate')) return NodeFilter.FILTER_REJECT;
      const t = n.nodeValue;
      if (!t || t.trim().length < 2 || !/\\p{L}/u.test(t)) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }});
    let n;
    while ((n = w.nextNode()) && nodes.length < 4000) { nodes.push(n); out.push(n.nodeValue); }
    window.__sdTr = { nodes: nodes, orig: out.slice() };
    window.__sdApplyTr = function(start, arr) {
      for (let k = 0; k < arr.length; k++) {
        const i = start + k, node = window.__sdTr.nodes[i], o = window.__sdTr.orig[i];
        if (!node || arr[k] == null) continue;
        node.nodeValue = o.match(/^\\s*/)[0] + arr[k].trim() + o.match(/\\s*$/)[0];
      }
    };
    return out.map(function(s) { return s.trim(); });
    """

    #if canImport(Translation)
    // Translates the page's text on this iPhone, a batch at a time, so it changes as you watch.
    @available(iOS 18.0, *)
    @MainActor
    func runTranslation(_ session: TranslationSession) async {
        translating = true
        defer { translating = false }
        guard let raw = try? await webView.callAsyncJavaScript(Pane.collectTextJS, arguments: [:], contentWorld: .page) as? [String],
              !raw.isEmpty else { return }
        var done = false
        var i = 0
        while i < raw.count {
            let end = min(i + 60, raw.count)
            let reqs = (i..<end).map { TranslationSession.Request(sourceText: raw[$0], clientIdentifier: String($0)) }
            guard let res = try? await session.translations(from: reqs) else {
                if !done { flash("Can't translate this page") }
                return
            }
            var slice = Array(raw[i..<end])
            for r in res {
                if let k = r.clientIdentifier.flatMap({ Int($0) }), k >= i, k < end { slice[k - i] = r.targetText }
            }
            _ = try? await webView.callAsyncJavaScript("window.__sdApplyTr(start, arr)", arguments: ["start": i, "arr": slice], contentWorld: .page)
            if !done { done = true; translated = true }
            i = end
        }
    }
    #endif
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

    // Most recently used normal tab that isn't already showing in the other pane.
    private func recentNormal(excluding other: UUID?) -> UUID? {
        list.filter { !$0.isPrivate && $0.id != other }
            .max { (used[$0.id] ?? .distantPast) < (used[$1.id] ?? .distantPast) }?.id
    }

    // Switches one pane back to a normal tab (the private tab stays open in the Private section).
    func exitPrivate(slot: Int) {
        let cur = slot == 0 ? left : right
        guard info(cur)?.isPrivate == true else { return }
        let other: UUID? = split ? (slot == 0 ? right : left) : nil
        if let target = recentNormal(excluding: other) {
            show(target, slot: slot)
        } else {
            newTab(slot: slot)
        }
    }

    // Closes the private tab in a pane and puts a normal tab in its place.
    func closePrivate(slot: Int) {
        let cur = slot == 0 ? left : right
        guard info(cur)?.isPrivate == true else { return }
        exitPrivate(slot: slot)
        close(cur)
    }

    func slot(of id: UUID) -> Int { split && right == id && left != id ? 1 : 0 }
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
        let id = p.id, priv = p.isPrivate
        p.webView.takeSnapshot(with: cfg) { [weak self] img, _ in
            guard let img else { return }
            DispatchQueue.global(qos: .utility).async {
                let w: CGFloat = 220
                let h = min(img.size.height * w / img.size.width, w * 2)
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = 2
                fmt.opaque = true
                let small = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
                    img.draw(in: CGRect(x: 0, y: 0, width: w, height: img.size.height * w / img.size.width))
                }
                let data = priv ? nil : small.jpegData(compressionQuality: 0.7)   // private previews stay in memory only
                DispatchQueue.main.async { self?.thumbs[id] = small }
                if let data { try? data.write(to: Tabs.thumbURL(id)) }
            }
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
        // Remove previews of tabs that no longer exist.
        let keep = Set(saved.map { $0.id.uuidString + ".jpg" })
        DispatchQueue.global(qos: .background).async {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Tabs.thumbDir.path)) ?? []
            for f in files where !keep.contains(f) { try? FileManager.default.removeItem(at: Tabs.thumbDir.appendingPathComponent(f)) }
        }
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
        // Replace a closed pane with the most recent normal tab, so closing a private tab leaves private mode.
        if !list.contains(where: { $0.id == left }) {
            left = recentNormal(excluding: split ? right : nil) ?? list.first { $0.id != right }?.id ?? list[0].id
        }
        if !list.contains(where: { $0.id == right }) {
            right = recentNormal(excluding: left) ?? list.first { $0.id != left }?.id ?? list[0].id
        }
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
    private var indexCache: [(host: String, title: String, item: HistoryItem)]?

    // Lower-cased host and title of recent visits, built once per change for fast suggestions.
    var searchIndex: [(host: String, title: String, item: HistoryItem)] {
        if let i = indexCache { return i }
        let built = items.lazy.filter { !$0.isSearch }.prefix(1500).map { ($0.host.lowercased(), $0.title.lowercased(), $0) }
        indexCache = Array(built)
        return indexCache ?? []
    }
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

    func clearSearches() {
        items.removeAll { $0.isSearch }
        trimAndSave()
    }

    // Adds imported visits (skipping ones already here), newest first. Returns how many were new.
    func importVisits(_ v: [(url: String, title: String, date: Date)]) -> Int {
        var seen = Set(items.lazy.filter { !$0.isSearch }.map { "\($0.text)|\(Int($0.date.timeIntervalSince1970))" })
        var added = 0
        for e in v where seen.insert("\(e.url)|\(Int(e.date.timeIntervalSince1970))").inserted {
            items.append(HistoryItem(isSearch: false, text: e.url, title: e.title, date: e.date))
            added += 1
        }
        items.sort { $0.date > $1.date }
        trimAndSave()
        return added
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
        indexCache = nil
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
    enum Kind { case search, recent, site, bookmark }
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
        var marks = 0
        for b in Bookmarks.shared.items where b.title.lowercased().contains(q) || b.url.lowercased().contains(q) {
            add(Suggestion(kind: .bookmark, title: b.title, subtitle: b.host, value: b.url))
            marks += 1
            if marks >= 3 { break }
        }
        // Sites: address starting with what you typed first, then title or address containing it.
        var starts: [HistoryItem] = [], contains: [HistoryItem] = []
        for v in history.searchIndex {
            if v.host.hasPrefix(q) { starts.append(v.item) }
            else if v.host.contains(q) || v.title.contains(q) { contains.append(v.item) }
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
        Theme(name: "Mono", top: hex("#F5F5F7"), bottom: hex("#DCDCE0"), strip: hex("#F5F5F7"), accent: hex("#1C1C1E"), dark: false),
    ]

    // The same theme for light or dark mode: keeps its hues and accent, changes the shades.
    // Default uses the system colours, which already follow light and dark.
    func variant(dark wantDark: Bool) -> Theme {
        guard let native = dark, native != wantDark else { return self }
        func tone(_ c: Color, _ sat: (CGFloat) -> CGFloat, _ bright: (CGFloat) -> CGFloat) -> Color {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(c).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return c }
            let grey = s < 0.04   // Mono and other greys stay grey
            return Color(hue: Double(h), saturation: grey ? 0 : Double(min(max(sat(s), 0), 1)), brightness: Double(min(max(bright(b), 0), 1)))
        }
        if wantDark {
            return Theme(name: name,
                         top: tone(top, { min($0 * 1.5 + 0.22, 0.6) }, { _ in 0.22 }),
                         bottom: tone(bottom, { min($0 * 1.5 + 0.25, 0.65) }, { _ in 0.09 }),
                         strip: tone(strip, { min($0 * 1.5 + 0.22, 0.6) }, { _ in 0.14 }),
                         accent: tone(accent, { $0 * 0.8 }, { max($0, 0.85) }),
                         dark: true)
        }
        return Theme(name: name,
                     top: tone(top, { _ in 0.08 }, { _ in 0.97 }),
                     bottom: tone(bottom, { _ in 0.22 }, { _ in 0.9 }),
                     strip: tone(strip, { _ in 0.07 }, { _ in 0.975 }),
                     accent: tone(accent, { max($0, 0.6) }, { min($0, 0.62) }),
                     dark: false)
    }

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
    // Light, Dark or System, kept apart from the theme: the theme's colours come in both.
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "System" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    @Published private(set) var homeImage: UIImage?
    @Published private(set) var photoTheme: Theme?

    var forcedScheme: ColorScheme? {
        appearance == "Light" ? .light : (appearance == "Dark" ? .dark : nil)
    }

    // The theme as it should look right now.
    func active(systemDark: Bool, forceDark: Bool = false) -> Theme {
        let d = forceDark || (forcedScheme.map { $0 == .dark } ?? systemDark)
        return current.variant(dark: d)
    }

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

// Home screen icon colour options. `icon` is the alternate icon's name in the asset catalog (nil = the main icon).
struct AppIconOption: Identifiable {
    let name: String
    let icon: String?
    let bg: Color
    let left: Color
    let right: Color
    var id: String { name }

    static let all: [AppIconOption] = [
        AppIconOption(name: "Default", icon: nil, bg: Theme.hex("#0A1022"), left: Theme.hex("#2440FF"), right: Theme.hex("#C9DBFF")),
        AppIconOption(name: "Matcha", icon: "AppIcon-Matcha", bg: Theme.hex("#1C2A16"), left: Theme.hex("#7FB54C"), right: Theme.hex("#EEF3E2")),
        AppIconOption(name: "Sunrise", icon: "AppIcon-Sunrise", bg: Theme.hex("#2A1020"), left: Theme.hex("#FF6A3D"), right: Theme.hex("#FFD8A8")),
        AppIconOption(name: "Ocean", icon: "AppIcon-Ocean", bg: Theme.hex("#05263A"), left: Theme.hex("#1E8FE6"), right: Theme.hex("#C4ECFF")),
        AppIconOption(name: "Lavender", icon: "AppIcon-Lavender", bg: Theme.hex("#1C1433"), left: Theme.hex("#8A68EE"), right: Theme.hex("#ECE4FD")),
        AppIconOption(name: "Sakura", icon: "AppIcon-Sakura", bg: Theme.hex("#2A1120"), left: Theme.hex("#E5507E"), right: Theme.hex("#FDE3EB")),
        AppIconOption(name: "Ember", icon: "AppIcon-Ember", bg: Theme.hex("#160907"), left: Theme.hex("#FF5A2B"), right: Theme.hex("#FFC891")),
        AppIconOption(name: "Mono", icon: "AppIcon-Mono", bg: Theme.hex("#F2F2F5"), left: Theme.hex("#1C1C1E"), right: Theme.hex("#9A9AA2")),
    ]
}

extension AppIconOption {
    static func named(_ icon: String) -> AppIconOption { all.first { ($0.icon ?? "") == icon } ?? all[0] }
}

// The SplitDeck mark drawn natively, so the picker can preview every colour option.
struct LogoMark: View {
    let option: AppIconOption
    var size: CGFloat = 60
    var plate = true    // false: just the two halves, no tile

    private func half(_ rect: CGRect, cx: CGFloat, cy: CGFloat, r: CGFloat, left: Bool) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: left)
        p.closeSubpath()
        return p
    }

    var body: some View {
        let k = size / (plate ? 1024 : 728)
        let c = size / 2
        ZStack {
            if plate {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(RadialGradient(colors: [option.bg.opacity(0.85), option.bg], center: UnitPoint(x: 0.3, y: 0.22),
                                         startRadius: 0, endRadius: size))
            }
            half(.zero, cx: c - 15 * k, cy: c - 64 * k, r: 300 * k, left: true).fill(option.left)
            half(.zero, cx: c + 15 * k, cy: c + 64 * k, r: 300 * k, left: false).fill(option.right)
        }
        .frame(width: size, height: size)
    }
}

// The logo as it appears around the app, in the colours of the app icon you picked.
struct BrandMark: View {
    var size: CGFloat = 40
    var glow = true
    @AppStorage("appIconName") private var iconName = ""

    var body: some View {
        let o = AppIconOption.named(iconName)
        LogoMark(option: o, size: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                              lineWidth: max(size / 90, 0.5)))
            .shadow(color: glow ? o.left.opacity(0.35) : .clear, radius: size * 0.22, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

struct AppIconPicker: View {
    @State private var current = UIApplication.shared.alternateIconName
    @State private var error: String?
    @AppStorage("appIconName") private var iconName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 12)], spacing: 14) {
                ForEach(AppIconOption.all) { o in
                    Button {
                        guard UIApplication.shared.supportsAlternateIcons else { return }
                        UIApplication.shared.setAlternateIconName(o.icon) { err in
                            DispatchQueue.main.async {
                                if let err { error = err.localizedDescription } else { current = o.icon; iconName = o.icon ?? ""; error = nil }
                            }
                        }
                    } label: {
                        VStack(spacing: 6) {
                            LogoMark(option: o, size: 58)
                                .overlay(RoundedRectangle(cornerRadius: 58 * 0.225 + 4, style: .continuous)
                                    .stroke(current == o.icon ? Color.accentColor : .clear, lineWidth: 3)
                                    .padding(-4))
                            Text(o.name).font(.caption2.weight(.medium)).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(o.name) app icon")
                    .accessibilityAddTraits(current == o.icon ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Theme.presets, id: \.name) { t in
                            Button { withAnimation(.snappy) { themes.name = t.name } } label: {
                                ThemeChip(theme: t.variant(dark: scheme == .dark), selected: themes.current.name == t.name)
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
                AppIconPicker()
            } header: {
                Text("App Icon")
            } footer: {
                Text("Changes the SplitDeck icon on your Home Screen. iOS shows a short confirmation when it switches.")
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
                Text("Your photo stays on this iPhone. Matching picks the bar and accent colours from it.")
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

// Site icons: fetched once, kept small, cached in memory and on disk, shared by every view showing them.
final class FaviconCache {
    static let shared = FaviconCache()
    private let mem = NSCache<NSString, UIImage>()
    private var waiting: [String: [(UIImage?) -> Void]] = [:]
    private var failed = Set<String>()
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("favicons")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { mem.countLimit = 300 }

    func cached(_ host: String) -> UIImage? { mem.object(forKey: host as NSString) }

    func load(_ host: String, done: @escaping (UIImage?) -> Void) {
        if let i = cached(host) { done(i); return }
        guard !host.isEmpty, !failed.contains(host) else { done(nil); return }
        if waiting[host] != nil { waiting[host]?.append(done); return }
        waiting[host] = [done]
        let file = FaviconCache.dir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
        DispatchQueue.global(qos: .utility).async {
            // Disk copies are refreshed after two weeks.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 14 * 86400,
               let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
                self.finish(host, img)
                return
            }
            guard let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") else { self.finish(host, nil); return }
            URLSession.shared.dataTask(with: url) { d, r, _ in
                var img: UIImage?
                if let d, (r as? HTTPURLResponse)?.statusCode == 200, let i = UIImage(data: d) {
                    img = i.preparingThumbnail(of: CGSize(width: 64, height: 64)) ?? i
                    if let png = img?.pngData() { try? png.write(to: file, options: .atomic) }
                }
                self.finish(host, img)
            }.resume()
        }
    }

    private func finish(_ host: String, _ img: UIImage?) {
        DispatchQueue.main.async {
            if let img { self.mem.setObject(img, forKey: host as NSString) } else { self.failed.insert(host) }
            (self.waiting.removeValue(forKey: host) ?? []).forEach { $0(img) }
        }
    }

    func clear() {
        mem.removeAllObjects()
        failed.removeAll()
        try? FileManager.default.removeItem(at: FaviconCache.dir)
        try? FileManager.default.createDirectory(at: FaviconCache.dir, withIntermediateDirectories: true)
    }
}

struct SiteIcon: View {
    let host: String
    var size: CGFloat = 56
    @State private var img: UIImage?

    var body: some View {
        Group {
            if let i = img ?? FaviconCache.shared.cached(host) {
                Image(uiImage: i).resizable().interpolation(.high).scaledToFit().frame(width: size * 0.5, height: size * 0.5)
            } else {
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .task(id: host) {
            guard img == nil, FaviconCache.shared.cached(host) == nil else { return }
            FaviconCache.shared.load(host) { img = $0 }
        }
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
    @AppStorage("saver") private var saver = false
    @State private var shown = false

    private func name(_ h: String) -> String {
        let parts = h.split(separator: ".")
        let base = parts.count >= 2 ? parts[parts.count - 2] : Substring(h)
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    var body: some View {
        let hosts = mode == 1 ? sites.custom : sites.frequent
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    BrandMark(size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SplitDeck")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
                            Text(blocked > 0 ? "\(blocked.formatted()) ads and trackers blocked" : "Shields up · private by design")
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 6)
                .onAppear { withAnimation(saver ? nil : .spring(response: 0.5, dampingFraction: 0.85)) { shown = true } }
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
            guard Shields.hasList(l.id) else { continue }
            let ident = "sd-\(l.id)-\(ver)"
            if let found = await Shields.lookUp(store, ident) {
                compiled[l.id] = found
                version += 1
                continue
            }
            let id = l.id
            let json = await Task.detached(priority: .utility) { Shields.listJSON(id) }.value
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

    // Lists ship deflate-compressed (.zz, about a fifth of the size); plain .json still works.
    static func hasList(_ id: String) -> Bool {
        Bundle.main.url(forResource: "sd-" + id, withExtension: "zz") != nil
            || Bundle.main.url(forResource: "sd-" + id, withExtension: "json") != nil
    }

    static func listJSON(_ id: String) -> String? {
        if let url = Bundle.main.url(forResource: "sd-" + id, withExtension: "zz"),
           let d = try? Data(contentsOf: url),
           let raw = try? (d as NSData).decompressed(using: .zlib) {
            return String(data: raw as Data, encoding: .utf8)
        }
        if let url = Bundle.main.url(forResource: "sd-" + id, withExtension: "json") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
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
                        HStack(spacing: 8) {
                            BrandMark(size: 22, glow: false)
                            Text("SplitDeck Shields").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }
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
                        Text(up ? "\(pane.blockedShown) ads and trackers blocked on this page"
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
                HStack(spacing: 14) {
                    BrandMark(size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SplitDeck Shields").font(.headline)
                        Text("\(shields.totalBlocked.formatted()) ads and trackers blocked so far")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.vertical, 4)
                Toggle("Block Ads and Trackers", isOn: $blockOn)
            } footer: {
                Text("Blocking runs on this iPhone with Apple's built-in content blocker. Nothing about your browsing is sent anywhere.")
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
    var openTabs: () -> Void
    var tabCount: Int
    var toggleSplit: () -> Void
    var splitOn: Bool
    var swapTabs: () -> Void
    var canSwap: Bool
    var islandShown: Bool
    var exitPrivate: () -> Void
    var closePrivate: () -> Void
    var splitEnabled: Bool
    var bookmarks: () -> Void
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
    @AppStorage("minimalBar") private var minimalBar = true
    @AppStorage("barLayout") private var barLayout = "twoTone"
    @State private var collapseToken = UUID()
    @State private var touchedAt = Date.distantPast
    @AppStorage("adaptiveText") private var adaptiveText = true
    @AppStorage("textColor") private var textColor = "System"
    @Environment(\.sdTheme) private var theme
    @Environment(\.scenePhase) private var phase


    private func stripBackground(top: Bool) -> some View { stripColor }

    @State private var desktop = false
    @State private var cover = BarCover()
    @FocusState private var focused: Bool

    private var ink: AnyShapeStyle {
        if adaptiveText || TextColors.color(textColor) == nil { return AnyShapeStyle(dark ? Color.white : Color.black) }
        return TextColors.ink(adaptive: adaptiveText, name: textColor)
    }
    // Never in Battery Saver, and only with the minimal bar switched on.
    private var mini: Bool { minimalBar && !saver && pane.collapsed && !focused && !pane.isHome }
    private var showEnds: Bool { !mini && !focused }
    private var pillH: CGFloat { compact ? 26 : 38 }
    // Full screen: the bar floats over the page instead of sitting in a strip beside it.
    private var floating: Bool { !compact }
    // Full-screen layout choice; split view always uses the slim two-tone bar.
    private var layoutStyle: String { compact ? "twoTone" : barLayout }
    private var tinted: Bool { layoutStyle == "twoTone" }
    private var toolbarLayout: Bool { layoutStyle == "toolbar" }
    private var showToolbar: Bool { toolbarLayout && !mini && !focused && !pane.hiding }
    // The bottom strip takes the page's own colour so it blends in; the top strip matches the status bar.
    private var stripColor: Color {
        if pane.isPrivate { return Color(red: 0.14, green: 0.10, blue: 0.23) }
        if searching { return atTop ? theme.top : theme.bottom }   // blends into the search screen's gradient
        return pane.isHome || atTop ? theme.strip : (pane.bottomColor ?? theme.strip)
    }
    // The full-screen search screen is up: the bar follows the theme, not the page behind it.
    private var searching: Bool { focused && !compact }
    // Whether the bar surface is dark. Adaptive: follows the page so text stays readable.
    // Fixed colour: the surface contrasts with the colour you picked.
    private var dark: Bool {
        if pane.isPrivate { return true }
        if !adaptiveText { return TextColors.isLight(textColor) ?? (sys == .dark) }
        if pane.isHome || searching || (atTop && compact) { return sys == .dark }
        if atTop { return pane.topDark ?? pane.pageDark ?? (sys == .dark) }
        return pane.pageDark ?? (sys == .dark)
    }
    // Tuned for 120 Hz: critically damped enough not to wobble, quick enough to feel direct.
    private var spring: Animation? { saver ? nil : .spring(response: 0.34, dampingFraction: 0.86) }
    // The bar folding into its pill: no bounce, a soft finish, like Safari.
    private var shrink: Animation? { saver ? nil : .spring(response: 0.42, dampingFraction: 0.9) }
    @Namespace private var ns
    private var barH: CGFloat { compact ? 36 : 54 }

    // Tinted ends of the two-tone bar: the buttons sit on tinted glass, the address on clear glass.
    private var endTint: Color {
        if pane.isPrivate { return Color.white.opacity(0.12) }
        return theme.accent.muted().opacity(dark ? 0.26 : 0.17)
    }

    // Minimal bottom bar: settle into a small pill after the page loads or you stop using the bar.
    // It waits until the bar has been left alone for a while, and never folds away under an open
    // ⋯ menu or share sheet (it checks again a little later instead).
    private static let idle: Double = 8
    private func scheduleCollapse(after delay: Double) {
        guard minimalBar, !saver, !(atTop && compact), !pane.isHome else { return }
        let token = UUID()
        collapseToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard collapseToken == token, !focused, !pane.hiding, !pane.isHome else { return }
            let quiet = Date().timeIntervalSince(touchedAt)
            if quiet < Self.idle { scheduleCollapse(after: Self.idle - quiet); return }
            if OverlayProbe.somethingOpen() { scheduleCollapse(after: 2); return }
            pane.collapsed = true
        }
    }
    private func touched() {
        touchedAt = Date()
        scheduleCollapse(after: Self.idle)
    }
    private func expand() {
        pane.expandBar()
        touched()
    }
    private var iconW: CGFloat { compact ? 32 : 44 }

    // Shows just the site name until you tap in, then the full address.
    private var addressText: Binding<String> {
        Binding(
            get: { focused || pane.isHome ? pane.address : pane.host.replacingOccurrences(of: "www.", with: "") },
            set: { pane.address = $0 }
        )
    }

    private var suggestions: [Suggestion] {
        guard focused, compact, !pane.isPrivate else { return [] }
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
                            case .bookmark: Image(systemName: "book")
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

    // Full screen: the page runs underneath the floating bar, scrolling clear of it.
    // Split view: each page sits between slim strips.
    private var stack: some View {
        VStack(spacing: 0) {
            if atTop && !floating { topRow }
            ZStack {
                WebHost(webView: pane.webView)
                    .opacity(pane.isHome ? 0 : 1)
                if pane.isHome {
                    Group {
                        if pane.isPrivate {
                            PrivateStartPage(leave: actions.exitPrivate)
                        } else {
                            StartPage(sites: sites, blocked: actions.totalBlocked) { pane.load($0) }
                        }
                    }
                    .safeAreaPadding(.top, cover.top)
                    .safeAreaPadding(.bottom, cover.bottom)
                }
                if focused && !compact {
                    FocusSplash(sites: sites, history: history,
                                query: pane.address == pane.webView.url?.absoluteString ? "" : pane.address,
                                isPrivate: pane.isPrivate) { value in
                        focused = false
                        pane.load(value)
                    }
                    .safeAreaPadding(.top, cover.top)
                    .safeAreaPadding(.bottom, cover.bottom)
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: atTop ? .top : .bottom)))
                } else if focused {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { focused = false }
                        .gesture(DragGesture(minimumDistance: 8).onEnded { v in
                            if v.translation.height > 16 { focused = false }
                        })
                }
            }
            .clipped()
            .overlay(alignment: atTop ? .top : .bottom) {
                if floating { AnyView(floatingBar) }
            }
            .overlay(alignment: .bottom) {
                if floating && atTop && showToolbar { floatingToolbar }
            }
            if !atTop && !floating { bottomRow }
        }
    }

    // Type-erased layers keep SwiftUI's view types shallow (see ContentView.body).
    var body: some View {
        AnyView(stack)
        .onPreferenceChange(BarCoverKey.self) { c in
            cover = c
            pane.setCover(c)
        }
        .modifier(TranslateHook(pane: pane))
        .overlay {
            // Private tabs are hidden when locked, and in the app switcher.
            if pane.isPrivate && (actions.privateLocked || phase != .active) {
                PrivateCover(locked: actions.privateLocked, unlock: actions.unlockPrivate, leave: actions.exitPrivate)
            }
        }
        .animation(shrink, value: mini)
        .animation(spring, value: focused)
        .animation(spring, value: pane.hiding)
        .animation(spring, value: suggestions.count)
        .animation(spring, value: barLayout)
        .animation(spring, value: atTop)
        .onChange(of: pane.loading) { _, l in if !l { scheduleCollapse(after: 1.5) } }
        .onChange(of: focused) { _, f in
            pane.editing = f
            if !f { touched() }
            if f && !pane.address.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                }
            }
        }
    }

    private var topRow: some View {
        VStack(spacing: 6) {
            bar.frame(height: barH)
            if compact && !suggestions.isEmpty { suggestionList }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.top, safeTop + 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(stripBackground(top: true))
    }

    private var bottomRow: some View {
        VStack(spacing: 8) {
            if compact && !suggestions.isEmpty { suggestionList }
            bar
            if showToolbar {
                toolbar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.horizontal, 12)
        .padding(.top, mini ? 4 : (compact ? 6 : 8))
        .padding(.bottom, bottomPad)
        .frame(maxWidth: .infinity)
        .background(stripBackground(top: false))
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { v in
            if focused && v.translation.height > 20 { focused = false }
        })
        .animation(saver ? nil : .easeInOut(duration: 0.25), value: dark)
    }

    // Split view toggle, shown in the bar when the edge island is switched off.
    private var splitButton: some View {
        Button { actions.toggleSplit() } label: {
            Image(systemName: actions.splitOn ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: compact ? 28 : 34, height: barH)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(actions.splitOn ? "Close split view" : "Split view")
    }

    // Tab count in the full-screen bar (split view keeps it in the edge dock to save room).
    private var tabsButton: some View {
        Button { actions.openTabs() } label: {
            Text("\(actions.tabCount)")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(ink)
                .frame(minWidth: 19, minHeight: 19)
                .padding(.horizontal, 1)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(ink, lineWidth: 1.5))
                .frame(width: 34, height: barH)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(actions.tabCount) tabs")
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
                .font(.system(size: compact ? 14 : 18, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: iconW, height: barH)
                .contentShape(Rectangle())
        }
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }

    // Toolbar layout: the buttons get their own row, spread out like Safari's classic bar.
    private var toolbar: some View {
        HStack(spacing: 0) {
            icon("chevron.left", enabled: pane.backEnabled) { pane.back() }.frame(maxWidth: .infinity)
            icon("chevron.right", enabled: pane.forwardEnabled) { pane.forward() }.frame(maxWidth: .infinity)
            shareButton.frame(maxWidth: .infinity)
            if !actions.islandShown && actions.splitEnabled { splitButton.frame(maxWidth: .infinity) }
            tabsButton.frame(maxWidth: .infinity)
            AnyView(menu).frame(maxWidth: .infinity)
        }
        .frame(height: 46)
        .simultaneousGesture(TapGesture().onEnded { touched() })
    }

    private var shareButton: some View {
        Group {
            if let url = pane.webView.url, !pane.isHome {
                ShareLink(item: url, subject: Text(pane.title)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: iconW, height: 46)
                        .contentShape(Rectangle())
                }
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ink)
                    .opacity(0.35)
                    .frame(width: iconW, height: 46)
            }
        }
        .accessibilityLabel("Share")
    }

    private var toolbarCapsule: some View {
        toolbar
            .padding(.horizontal, 4)
            .sdGlass(Capsule(), dark: dark, clear: true, rim: true)
    }

    private var floatPad: CGFloat {
        if focused { return 8 }
        if mini { return max(bottomInset - 12, 6) }
        return max(bottomInset - 8, 10)
    }

    // Full screen: the bar (and toolbar) float over the page with the page showing around them.
    private var floatingBar: some View {
        VStack(spacing: 8) {
            bar
            if !atTop && showToolbar {
                toolbarCapsule.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.horizontal, 12)
        .padding(.top, atTop ? 6 : 0)
        .padding(.bottom, atTop ? 0 : floatPad)
        .background(GeometryReader { g in
            Color.clear.preference(key: BarCoverKey.self,
                                   value: atTop ? BarCover(top: g.size.height + 4) : BarCover(bottom: g.size.height + 4))
        })
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { v in
            if focused && v.translation.height > 20 { focused = false }
        })
        .animation(saver ? nil : .easeInOut(duration: 0.25), value: dark)
    }

    // Address bar at the top: the toolbar floats at the bottom.
    private var floatingToolbar: some View {
        toolbarCapsule
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(.horizontal, 12)
            .padding(.bottom, floatPad)
            .background(GeometryReader { g in
                Color.clear.preference(key: BarCoverKey.self, value: BarCover(bottom: g.size.height + 4))
            })
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var field: some View {
        TextField(pane.isPrivate ? "Search privately" : "Search or enter site", text: addressText)
            .textFieldStyle(.plain)
            .font(compact ? .subheadline : .system(size: 17, weight: .medium))
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
        if pane.hiding { hidingBar } else { mainBar }
    }

    private var hidingBar: some View {
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
        .sdGlass(Capsule(), dark: dark, solid: compact, rim: true)
        .matchedGeometryEffect(id: "bar", in: ns)
        .transition(.opacity)
    }

    // Back and forward (tinted end of the two-tone bar).
    private var leadingEnd: some View {
        HStack(spacing: 0) {
            icon("chevron.left", enabled: pane.backEnabled) { pane.back() }
            icon("chevron.right", enabled: pane.forwardEnabled) { pane.forward() }
            if pane.isPrivate {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .opacity(0.8)
                    .padding(.trailing, 6)
                    .accessibilityLabel("Private tab")
            }
        }
        .frame(height: barH - 6)
        .background(tinted ? endTint : Color.clear, in: Capsule())
        .simultaneousGesture(TapGesture().onEnded { touched() })
        .padding(.leading, 3)
    }

    // Shown when most of the page is in another language (or while it's translated).
    private var translateButton: some View {
        Button { pane.requestTranslation() } label: {
            Group {
                if pane.translating {
                    ProgressView().controlSize(.mini).tint(dark ? .white : .black)
                } else {
                    Image(systemName: "translate")
                        .font(.system(size: compact ? 12 : 15, weight: .semibold))
                        .foregroundStyle(pane.translated ? AnyShapeStyle(theme.accent) : ink)
                }
            }
            .frame(width: compact ? 28 : 34, height: barH)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(pane.translated ? "Show original" : "Translate page")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    // Page and app controls (the other tinted end).
    private var trailingEnd: some View {
        HStack(spacing: 0) {
            if !pane.isHome && Translate.offer && (pane.foreignLanguage != nil || pane.translated || pane.translating) {
                translateButton
            }
            if !pane.isHome { reloadButton }
            if !toolbarLayout {
                if compact && actions.splitOn && actions.canSwap {
                    icon("arrow.left.arrow.right") { actions.swapTabs() }
                        .accessibilityLabel("Switch to last tab")
                }
                if !actions.islandShown && actions.splitEnabled { splitButton }
                if !compact || !actions.islandShown { tabsButton }
                AnyView(menu)
            }
        }
        .frame(height: barH - 6)
        .background(tinted ? endTint : Color.clear, in: Capsule())
        .simultaneousGesture(TapGesture().onEnded { touched() })
        .padding(.trailing, 3)
    }

    // What the pill shows: a lock (or private eye, or a spinner) and the site.
    private var pillLabel: some View {
        HStack(spacing: 6) {
            if pane.isPrivate {
                Image(systemName: "eye.slash.fill").font(.system(size: compact ? 9 : 11, weight: .semibold))
            } else if pane.loading {
                ProgressView().controlSize(.mini).tint(dark ? .white : .black)
            } else {
                Image(systemName: "lock.fill").font(.system(size: compact ? 8 : 10, weight: .semibold)).opacity(0.6)
            }
            Text(pane.host.isEmpty ? "Search" : pane.host.replacingOccurrences(of: "www.", with: ""))
                .font(compact ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .fixedSize()
    }

    // One capsule that changes shape between the full bar and the small pill. The capsule itself
    // never cross-fades: it shrinks around the address while the buttons fold away into it (like Safari),
    // and grows back out when you tap it, even while the page is still moving.
    private var mainBar: some View {
        AnyView(HStack(spacing: 0) {
            if showEnds && toolbarLayout && pane.isPrivate {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .opacity(0.8)
                    .padding(.leading, 16)
                    .accessibilityLabel("Private tab")
                    .transition(.opacity)
            }
            if showEnds && !toolbarLayout {
                leadingEnd.transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .leading)))
            }
            if mini {
                pillLabel
                    .matchedGeometryEffect(id: "addr", in: ns)
                    .transition(.opacity)
            } else {
                field
                    .padding(.leading, focused || toolbarLayout ? (compact ? 14 : 18) : 8)
                    .matchedGeometryEffect(id: "addr", in: ns)
                    .transition(.opacity)
            }
            if focused {
                if !pane.address.isEmpty { icon("xmark.circle.fill") { pane.address = "" } }
            } else if showEnds {
                trailingEnd.transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .trailing)))
            }
        })
        .padding(.horizontal, mini ? (compact ? 12 : 18) : 0)
        .frame(height: mini ? pillH : barH)
        .frame(maxWidth: mini ? nil : .infinity)
        .sdGlass(Capsule(), dark: dark, clear: tinted || floating, solid: compact, rim: true)
        .contentShape(Capsule())
        .gesture(TapGesture().onEnded { expand() }, including: mini ? .all : .subviews)
        .accessibilityAddTraits(mini ? .isButton : [])
        .geometryGroup()
        .padding(.trailing, focused && !compact ? 78 : 0)
        .overlay(alignment: .trailing) {
            if focused && !compact {
                Button("Cancel") { focused = false }
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(width: 70, height: barH)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: atTop ? .bottom : .top) {
            if let n = pane.notice {
                Text(n)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .sdGlass(Capsule(), dark: dark, rim: true)
                    .offset(y: atTop ? 42 : -42)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
            }
        }
        .animation(spring, value: pane.notice)
        .matchedGeometryEffect(id: "bar", in: ns)
        .transition(.opacity)
    }

    private var menu: some View {
        Menu {
            ControlGroup {
                Button { actions.settings() } label: { Label("Settings", systemImage: "gearshape") }
                Button { actions.bookmarks() } label: { Label("Bookmarks", systemImage: "book") }
                Button { actions.history() } label: { Label("History", systemImage: "clock") }
            }
            .controlGroupStyle(.compactMenu)
            Section {
                Button { actions.newTab() } label: { Label("New Tab", systemImage: "plus.square.on.square") }
                Button { pane.goHome() } label: { Label("Home", systemImage: "house") }
                if pane.isPrivate {
                    Button { actions.exitPrivate() } label: { Label("Leave Private Mode", systemImage: "eye") }
                    Button(role: .destructive) { actions.closePrivate() } label: { Label("Close Private Tab", systemImage: "xmark") }
                } else {
                    Button { actions.newPrivateTab() } label: { Label("New Private Tab", systemImage: "eye.slash") }
                }
            }
            if !pane.isHome {
                Section {
                    if let url = pane.webView.url {
                        let marked = Bookmarks.shared.find(url.absoluteString) != nil
                        Button {
                            Bookmarks.shared.toggle(url: url.absoluteString, title: pane.title)
                            pane.flash(marked ? "Bookmark removed" : "Bookmarked")
                        } label: {
                            Label(marked ? "Remove Bookmark" : "Add Bookmark", systemImage: marked ? "star.fill" : "star")
                        }
                        ShareLink(item: url, subject: Text(pane.title)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button { pane.requestTranslation() } label: {
                        Label(pane.translated ? "Show Original" : "Translate to \(Translate.name(Translate.target))", systemImage: "translate")
                    }
                    ControlGroup {
                        Button { pane.zoomOut() } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                        Button { pane.setZoom(Zoom.defaultLevel) } label: { Text(Zoom.label(pane.zoom)) }
                        Button { pane.zoomIn() } label: { Label("Larger", systemImage: "textformat.size.larger") }
                    }
                    Button { actions.shields() } label: {
                        Label(actions.shieldsUp ? "Shields · \(pane.blockedShown) blocked" : "Shields Down",
                              systemImage: actions.shieldsUp ? "shield.lefthalf.filled" : "shield.slash")
                    }
                    Menu {
                        Button { desktop.toggle(); pane.setDesktop(desktop) } label: {
                            Label(desktop ? "Mobile Site" : "Desktop Site", systemImage: desktop ? "iphone" : "desktopcomputer")
                        }
                        Button { pane.startHiding() } label: { Label("Hide Distracting Items", systemImage: "eye.slash") }
                        if pane.hiddenCount > 0 {
                            Button { pane.showAllHidden() } label: { Label("Show Hidden Items (\(pane.hiddenCount))", systemImage: "eye") }
                        }
                        Button { actions.calendar() } label: { Label("Add to Calendar", systemImage: "calendar.badge.plus") }
                    } label: {
                        Label("Page Tools", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
            Section {
                if actions.splitEnabled {
                    Button { actions.toggleSplit() } label: {
                        Label(actions.splitOn ? "Close Split View" : "Split View",
                              systemImage: actions.splitOn ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                    }
                }
                if actions.canSwap {
                    Button { actions.swapTabs() } label: { Label("Switch to Last Tab", systemImage: "arrow.left.arrow.right") }
                }
                Button { actions.vpn() } label: {
                    Label(actions.vpnOn ? "VPN (On)" : "VPN", systemImage: actions.vpnOn ? "lock.shield.fill" : "lock.shield")
                }
            }
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

// Runs page translation with Apple's on-device Translation framework (iOS 18 and later).
struct TranslateHook: ViewModifier {
    @ObservedObject var pane: Pane
    @ViewBuilder func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.modifier(PageTranslator(pane: pane))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
struct PageTranslator: ViewModifier {
    @ObservedObject var pane: Pane
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                await pane.runTranslation(session)
            }
            .onChange(of: pane.translateRequest) { _, _ in
                let target = Locale.Language(identifier: Translate.target)
                let source = pane.foreignLanguage.map { Locale.Language(identifier: $0) }
                if config == nil || config?.target != target || config?.source != source {
                    config = TranslationSession.Configuration(source: source, target: target)
                } else {
                    config?.invalidate()
                }
            }
    }
}
#endif

// Whether a menu, share sheet or other sheet is on screen, so the address bar doesn't fold away under it.
enum OverlayProbe {
    static func somethingOpen() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows where !w.isHidden {
                if w.rootViewController?.presentedViewController != nil { return true }
                if hasMenu(w, depth: 0) { return true }
            }
        }
        return false
    }
    private static func hasMenu(_ v: UIView, depth: Int) -> Bool {
        if NSStringFromClass(type(of: v)).contains("ContextMenu") { return true }
        guard depth < 3 else { return false }
        return v.subviews.contains { hasMenu($0, depth: depth + 1) }
    }
}

// MARK: Address bar focus screen

func siteShortName(_ h: String) -> String {
    let parts = h.split(separator: ".")
    let base = parts.count >= 2 ? parts[parts.count - 2] : Substring(h)
    return base.prefix(1).uppercased() + base.dropFirst()
}

// Safari-style: tapping the address in full screen shows favourites and recent searches,
// then live suggestions as you type.
struct FocusSplash: View {
    @ObservedObject var sites: Sites
    @ObservedObject var history: HistoryStore
    @ObservedObject private var bookmarks = Bookmarks.shared
    var query: String
    var isPrivate: Bool
    var open: (String) -> Void
    @Environment(\.sdTheme) private var theme

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var results: [Suggestion] {
        if isPrivate {
            var out = [Suggestion(kind: .search, title: typed, subtitle: "Search", value: typed)]
            let q = typed.lowercased()
            for h in (sites.custom + sites.frequent) where h.contains(q) && !out.contains(where: { $0.value == h }) {
                out.append(Suggestion(kind: .site, title: h, subtitle: "Favourite", value: h))
                if out.count >= 6 { break }
            }
            return out
        }
        return Suggest.make(query: typed, history: history, sites: sites, limit: 9)
    }

    private func row(_ s: Suggestion) -> some View {
        Button { open(s.value) } label: {
            HStack(spacing: 14) {
                Group {
                    switch s.kind {
                    case .search: Image(systemName: "magnifyingglass")
                    case .recent: Image(systemName: "clock.arrow.circlepath")
                    case .site: Image(systemName: "globe")
                    case .bookmark: Image(systemName: "book")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                    Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if typed.isEmpty {
                    let favs = sites.custom.isEmpty ? sites.frequent : sites.custom
                    if !favs.isEmpty {
                        Text(sites.custom.isEmpty ? "Frequently Visited" : "Favourites").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 14)], spacing: 18) {
                            ForEach(Array(favs.prefix(12)), id: \.self) { h in
                                Button { open(h) } label: {
                                    VStack(spacing: 6) {
                                        SiteIcon(host: h)
                                        Text(siteShortName(h)).font(.caption).foregroundStyle(.primary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    let marks = Array(bookmarks.items.prefix(5))
                    if !marks.isEmpty {
                        Text("Bookmarks").font(.title3.bold())
                        VStack(spacing: 0) {
                            ForEach(Array(marks.enumerated()), id: \.element.id) { i, b in
                                if i > 0 { Divider().padding(.leading, 58) }
                                row(Suggestion(kind: .bookmark, title: b.title, subtitle: b.host, value: b.url))
                            }
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    let recents = isPrivate ? [] : Array(history.recentSearches.prefix(6))
                    if !recents.isEmpty {
                        HStack {
                            Text("Recent Searches").font(.title3.bold())
                            Spacer()
                            Button("Clear") { withAnimation { history.clearSearches() } }.font(.subheadline)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(recents.enumerated()), id: \.offset) { i, r in
                                if i > 0 { Divider().padding(.leading, 58) }
                                row(Suggestion(kind: .recent, title: r, subtitle: "Recent search", value: r))
                            }
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if favs.isEmpty && recents.isEmpty {
                        Text("Type a search or an address.").foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Divider().padding(.leading, 58) }
                            row(s)
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(isPrivate
                    ? AnyShapeStyle(Color(red: 0.10, green: 0.07, blue: 0.17))
                    : AnyShapeStyle(LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)))
    }
}

// MARK: Private mode screens

struct PrivateStartPage: View {
    var leave: () -> Void

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
                Button(action: leave) {
                    Label("Leave Private Mode", systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(.white.opacity(0.15), in: Capsule())
                }
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
    var leave: () -> Void

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
                    // Leaving doesn't reveal anything, so it doesn't need Face ID.
                    Button("Leave Private Mode", action: leave)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }
}

// MARK: Edge dock

enum DockEdge: String { case left, right, top }

enum Haptics {
    static func lift() { UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.7) }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func land() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
}

// Island buttons sink a little under your finger.
struct IslandPress: ButtonStyle {
    var saver: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0)).padding(3))
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(saver ? nil : .spring(response: 0.24, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// The floating island: tabs, last-tab switch and split view. Drag it anywhere and let go: it springs
// to the nearest side or the top, turning sideways to lie along the top. Fling it at the edge (or tap
// the chevron) to tuck it into a slim handle; tap the handle, or pull it out, to bring it back.
struct EdgeDock: View {
    @ObservedObject var tabs: Tabs
    var saver: Bool
    var privateMode: Bool
    var safe: UIEdgeInsets
    var openTabs: () -> Void
    @AppStorage("splitEnabled") private var splitEnabled = true
    @AppStorage("adaptiveText") private var adaptiveText = true
    @AppStorage("textColor") private var textColor = "System"
    @Environment(\.sdTheme) private var theme

    // Where it rests. Kept in State so every change animates, and saved for next launch.
    @State private var edge = DockEdge(rawValue: UserDefaults.standard.string(forKey: "dockEdge") ?? "") ?? .right
    @State private var along = UserDefaults.standard.object(forKey: "dockPos") as? Double
        ?? UserDefaults.standard.object(forKey: "dockY") as? Double ?? 0.45
    // Only a side can hold the island tucked away; at the top it always stays open.
    @State private var tucked = UserDefaults.standard.bool(forKey: "dockTucked")
        && (UserDefaults.standard.string(forKey: "dockEdge") ?? "right") != "top"

    // While dragging
    @State private var start: CGPoint?          // resting centre when the drag began
    @State private var drag: CGSize = .zero
    @State private var target: DockEdge?        // the edge it will land on
    @State private var willTuck = false
    @State private var swapTick = 0

    private var ink: AnyShapeStyle {
        privateMode ? AnyShapeStyle(Color.white) : TextColors.ink(adaptive: adaptiveText, name: textColor)
    }
    // Critically damped springs: they settle without wobbling and pick up straight from your finger.
    private var lift: Animation? { saver ? nil : .spring(response: 0.26, dampingFraction: 0.84) }
    private var morph: Animation? { saver ? nil : .spring(response: 0.34, dampingFraction: 0.88) }
    private var settle: Animation? { saver ? nil : .spring(response: 0.42, dampingFraction: 0.86) }
    private func release(_ v: Double) -> Animation? {
        saver ? nil : .interpolatingSpring(mass: 1, stiffness: 200, damping: 26, initialVelocity: v)
    }

    private var shownEdge: DockEdge { target ?? edge }
    private var vertical: Bool { shownEdge != .top }
    private var length: CGFloat { CGFloat(splitEnabled ? 4 : 3) * 44 + 8 }
    private let girth: CGFloat = 52

    // MARK: Geometry

    private func rest(_ e: DockEdge, _ a: Double, tucked t: Bool, in s: CGSize) -> CGPoint {
        let half = (t ? 96 : length) / 2
        switch e {
        case .left, .right:
            let lo = safe.top + half + 12
            let hi = max(s.height - safe.bottom - half - 40, lo)
            let y = min(max(a * s.height, lo), hi)
            let inset = t ? 10 : girth / 2 + 6
            return CGPoint(x: e == .right ? s.width - safe.right - inset : safe.left + inset, y: y)
        case .top:
            let lo = safe.left + half + 12
            let hi = max(s.width - safe.right - half - 12, lo)
            let x = min(max(a * s.width, lo), hi)
            return CGPoint(x: x, y: safe.top + girth / 2 + 6)
        }
    }

    private func nearest(_ p: CGPoint, in s: CGSize) -> DockEdge {
        let l = p.x - safe.left
        let r = s.width - safe.right - p.x
        let t = (p.y - safe.top) * 1.15      // the top needs a slightly firmer pull than the sides
        if t < l && t < r { return .top }
        return l < r ? .left : .right
    }

    // How far past an edge's resting line a point is (positive = toward the screen edge).
    private func overshoot(_ p: CGPoint, _ e: DockEdge, in s: CGSize) -> CGFloat {
        let r = rest(e, 0.5, tucked: false, in: s)
        switch e {
        case .right: return p.x - r.x
        case .left: return r.x - p.x
        case .top: return r.y - p.y
        }
    }

    // Follows the finger, with a rubbery give at the screen edges.
    private func live(in s: CGSize) -> CGPoint? {
        guard let start else { return nil }
        func band(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            v < lo ? lo - (lo - v) * 0.25 : (v > hi ? hi + (v - hi) * 0.25 : v)
        }
        return CGPoint(x: band(start.x + drag.width, 30, s.width - 30),
                       y: band(start.y + drag.height, safe.top + 26, s.height - safe.bottom - 30))
    }

    // MARK: Actions

    private func save() {
        let d = UserDefaults.standard
        d.set(edge.rawValue, forKey: "dockEdge")
        d.set(along, forKey: "dockPos")
        d.set(tucked, forKey: "dockTucked")
    }

    private func setTucked(_ t: Bool) {
        guard !t || edge != .top else { return }
        Haptics.tap()
        withAnimation(settle) { tucked = t }
        save()
    }

    private func move(to e: DockEdge) {
        withAnimation(settle) { edge = e; along = e == .top ? 0.5 : 0.45; tucked = false }
        save()
    }

    private func dragGesture(in s: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("dock"))
            .onChanged { v in
                if start == nil {
                    withAnimation(lift) {
                        start = rest(edge, along, tucked: tucked, in: s)
                        target = edge
                    }
                    Haptics.lift()
                }
                drag = v.translation
                guard let p = live(in: s) else { return }
                // Pull the handle away from the edge and the island comes out with your finger.
                if tucked && overshoot(p, edge, in: s) < -12 {
                    withAnimation(morph) { tucked = false }
                    Haptics.tick()
                }
                let t = nearest(p, in: s)
                if t != target {
                    withAnimation(morph) { target = t }
                    Haptics.tick()
                }
                let wt = !tucked && t != .top && overshoot(p, t, in: s) > 26
                if wt != willTuck {
                    withAnimation(lift) { willTuck = wt }
                    Haptics.tick()
                }
            }
            .onEnded { v in
                guard let st = start else { return }
                let p = CGPoint(x: st.x + v.translation.width, y: st.y + v.translation.height)
                let flung = CGPoint(x: st.x + v.predictedEndTranslation.width, y: st.y + v.predictedEndTranslation.height)
                // Lean toward where a flick was heading.
                var aim = CGPoint(x: p.x + (flung.x - p.x) * 0.3, y: p.y + (flung.y - p.y) * 0.3)
                aim.x = min(max(aim.x, 0), s.width)
                aim.y = min(max(aim.y, 0), s.height)
                let e = nearest(aim, in: s)
                let a = Double(e == .top ? aim.x / max(s.width, 1) : aim.y / max(s.height, 1))
                let side = e != .top
                let tuck = side && (tucked || willTuck || (overshoot(p, e, in: s) > -50 && overshoot(flung, e, in: s) > 140))
                // Hand the finger's speed to the spring, so the island carries on smoothly instead of jolting.
                let end = rest(e, min(max(a, 0), 1), tucked: tuck, in: s)
                let from = live(in: s) ?? p
                let dx = end.x - from.x, dy = end.y - from.y
                let dist = max(sqrt(dx * dx + dy * dy), 1)
                let toward = (v.velocity.width * dx + v.velocity.height * dy) / dist
                let rel = Double(min(max(toward / dist, 0), 6))
                withAnimation(release(rel)) {
                    edge = e
                    along = min(max(a, 0), 1)
                    tucked = tuck
                    start = nil
                    drag = .zero
                    target = nil
                    willTuck = false
                }
                Haptics.land()
                save()
            }
    }

    // MARK: Views

    private func button<L: View>(_ label: String, _ action: @escaping () -> Void, @ViewBuilder content: () -> L) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            content()
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandPress(saver: saver))
        .accessibilityLabel(label)
    }

    private var tabCount: Int { privateMode ? tabs.privateCount : tabs.normalCount }

    private var panel: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            button("\(tabCount) tabs", openTabs) {
                Text("\(tabCount)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink, lineWidth: 1.6))
                    .animation(settle, value: tabCount)
            }
            .contextMenu {
                Button { withAnimation(settle) { tabs.newTab(slot: 0) } } label: {
                    Label("New Tab", systemImage: "plus.square.on.square")
                }
                Button { withAnimation(settle) { tabs.newTab(slot: 0, isPrivate: true) } } label: {
                    Label("New Private Tab", systemImage: "eye.slash")
                }
                Button(action: openTabs) { Label("Show All Tabs", systemImage: "square.grid.2x2") }
            }
            button("Switch to last tab", { swapTick += 1; withAnimation(settle) { tabs.swap() } }) {
                Image(systemName: "arrow.left.arrow.right")
                    .rotationEffect(.degrees(vertical ? 0 : 90))
                    .symbolEffect(.bounce, value: swapTick)
            }
            .disabled(!tabs.canSwap)
            .opacity(tabs.canSwap ? 1 : 0.4)
            if splitEnabled {
                button(tabs.split ? "Close split view" : "Split view", { withAnimation(settle) { tabs.toggleSplit() } }) {
                    Image(systemName: tabs.split ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .symbolEffect(.bounce, value: tabs.split)
                }
            }
            if shownEdge != .top {
                button("Tuck away", { setTucked(true) }) {
                    Image(systemName: shownEdge == .left ? "chevron.compact.left" : "chevron.compact.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .opacity(0.6)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .symbolEffectsRemoved(saver)
        .padding(4)
        .sdGlass(Capsule(style: .continuous), dark: privateMode ? true : nil)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move to left edge") { move(to: .left) }
        .accessibilityAction(named: "Move to right edge") { move(to: .right) }
        .accessibilityAction(named: "Move to top") { move(to: .top) }
    }

    private var handle: some View {
        Capsule()
            .fill(privateMode ? Color.white.opacity(0.75) : Color.primary.opacity(0.45))
            .background(Capsule().stroke(Color(uiColor: .systemBackground).opacity(0.6), lineWidth: 1.5))
            .frame(width: 5, height: 52)
            .frame(width: 28, height: 96)
            .contentShape(Rectangle())
            .onTapGesture { setTucked(false) }
            .accessibilityLabel("Show tab controls")
            .accessibilityAddTraits(.isButton)
    }

    private var anchor: UnitPoint {
        switch shownEdge {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        }
    }

    // A glow on the edge it will land on, while you drag.
    private func glow(_ p: CGPoint, in s: CGSize) -> some View {
        let e = shownEdge
        let side = e != .top
        var at = CGPoint(x: p.x, y: safe.top + 3)
        if e == .left { at = CGPoint(x: safe.left + 3, y: p.y) }
        if e == .right { at = CGPoint(x: s.width - safe.right - 3, y: p.y) }
        return Capsule()
            .fill(theme.accent.opacity(willTuck ? 0.95 : 0.55))
            .frame(width: side ? 4 : 110, height: side ? (willTuck ? 150 : 110) : 4)
            .shadow(color: theme.accent.opacity(0.6), radius: 6)
            .position(at)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    var body: some View {
        GeometryReader { g in
            let s = g.size
            let lifted = start != nil
            let base = start ?? rest(edge, along, tucked: tucked, in: s)
            let p = live(in: s) ?? base
            ZStack {
                if lifted && !saver { glow(p, in: s) }
                Group {
                    if tucked { handle } else { panel }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.6, anchor: anchor)),
                                        removal: .opacity.combined(with: .scale(scale: 0.4, anchor: anchor))))
                .animation(morph, value: vertical)
                .scaleEffect(lifted ? (willTuck ? 0.86 : 1.05) : 1)
                .opacity(willTuck ? 0.8 : 1)
                .shadow(color: .black.opacity(lifted && !saver ? 0.25 : 0), radius: 16, y: 8)
                .gesture(dragGesture(in: s))
                // Positioned at its resting point; the drag only offsets it, so moving it never re-runs layout.
                .position(base)
                .offset(x: p.x - base.x, y: p.y - base.y)
            }
        }
        .coordinateSpace(.named("dock"))
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

// Where each tile sits on screen, written while laying out (no view updates), read when a page flies in or out.
final class TileFrames {
    var rects: [UUID: CGRect] = [:]
    func set(_ id: UUID, _ r: CGRect) { rects[id] = r }
}

// A picture of the page you were on, and where it was, so it can shrink into its tile.
struct HeroSnap {
    let id: UUID
    let image: UIImage
    let rect: CGRect
}

enum TabHero {
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    // Web pages come from WebKit's own snapshot; the home page (drawn by the app) from the window.
    static func capture(_ p: Pane, done: @escaping (HeroSnap?) -> Void) {
        let wv = p.webView
        if p.isHome || wv.window == nil || wv.bounds.width < 1 {
            guard let w = keyWindow else { done(nil); return }
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 2
            fmt.opaque = true
            let img = UIGraphicsImageRenderer(bounds: w.bounds, format: fmt).image { _ in
                w.drawHierarchy(in: w.bounds, afterScreenUpdates: false)
            }
            done(HeroSnap(id: p.id, image: img, rect: w.bounds))
            return
        }
        let rect = wv.convert(wv.bounds, to: nil)
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = false
        wv.takeSnapshot(with: cfg) { img, _ in
            done(img.map { HeroSnap(id: p.id, image: $0, rect: rect) })
        }
    }
}

// Safari-style: the page shrinks smoothly into its tile when the grid opens, and the tile you pick
// grows back out to fill the screen.
struct TabSwitcher: View {
    @ObservedObject var tabs: Tabs
    var startPrivate: Bool
    var startSlot: Int
    var privateLocked: Bool
    var unlock: () -> Void
    var snap: HeroSnap?
    var saver: Bool
    var close: () -> Void

    @State private var frames = TileFrames()
    @State private var heroID: UUID?
    @State private var heroImage: UIImage?
    @State private var heroFull: CGRect = .zero
    @State private var atTile = false
    @State private var shown = false
    @State private var busy = false

    private var spring: Animation? { saver ? nil : .spring(response: 0.46, dampingFraction: 0.88) }

    private func fullRect(_ size: CGSize) -> CGRect {
        snap?.rect ?? CGRect(origin: .zero, size: size)
    }

    private func open() {
        guard let snap, !saver else {
            withAnimation(saver ? nil : .easeOut(duration: 0.22)) { shown = true }
            return
        }
        heroID = snap.id
        heroImage = snap.image
        heroFull = snap.rect
        atTile = false
        // Let the grid lay out (and scroll to this tab) before the page shrinks into its tile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            withAnimation(spring) {
                atTile = true
                shown = true
            } completion: {
                heroID = nil
                heroImage = nil
            }
        }
    }

    // Grows the chosen tile back out to full screen, switching to that tab underneath.
    private func pick(_ id: UUID, slot: Int, size: CGSize) {
        guard !busy else { return }
        busy = true
        let image = (snap?.id == id ? snap?.image : nil) ?? tabs.thumb(id)
        tabs.show(id, slot: slot)
        guard !saver, !tabs.split, let image, frames.rects[id] != nil else {
            withAnimation(saver ? nil : .easeOut(duration: 0.2)) { shown = false } completion: { close() }
            return
        }
        heroID = id
        heroImage = image
        heroFull = fullRect(size)
        atTile = true
        DispatchQueue.main.async {
            withAnimation(spring) {
                atTile = false
                shown = false
            } completion: { close() }
        }
    }

    private func newTab(_ isPrivate: Bool, slot: Int) {
        guard !busy else { return }
        busy = true
        tabs.newTab(slot: slot, isPrivate: isPrivate)
        withAnimation(saver ? nil : .easeOut(duration: 0.2)) { shown = false } completion: { close() }
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                TabsView(tabs: tabs,
                         startPrivate: startPrivate,
                         startSlot: startSlot,
                         privateLocked: privateLocked,
                         unlock: unlock,
                         frames: frames,
                         hiddenTile: heroID,
                         fresh: snap.map { [$0.id: $0.image] } ?? [:],
                         scrollTo: snap?.id,
                         pick: { id, slot in pick(id, slot: slot, size: g.size) },
                         newTab: { priv, slot in newTab(priv, slot: slot) },
                         done: { pick(tabs.split ? tabs.visible[min(startSlot, tabs.visible.count - 1)] : tabs.left,
                                      slot: startSlot, size: g.size) })
                    .opacity(shown ? 1 : 0)
                if let heroID, let heroImage {
                    let tile = frames.rects[heroID]
                    let r = atTile ? (tile ?? CGRect(x: g.size.width / 2 - 40, y: g.size.height / 2 - 60, width: 80, height: 120)) : heroFull
                    Image(uiImage: heroImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: r.width, height: r.height, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: atTile ? 16 : 0, style: .continuous))
                        .shadow(color: .black.opacity(atTile ? 0.12 : 0), radius: 8, y: 3)
                        .opacity(atTile && tile == nil ? 0 : 1)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: open)
    }
}

struct TabsView: View {
    @ObservedObject var tabs: Tabs
    var startPrivate: Bool
    var startSlot: Int
    var privateLocked: Bool
    var unlock: () -> Void
    var frames: TileFrames
    var hiddenTile: UUID?
    var fresh: [UUID: UIImage]
    var scrollTo: UUID?
    var pick: (UUID, Int) -> Void
    var newTab: (Bool, Int) -> Void
    var done: () -> Void
    @State private var slotChoice: Int?
    @State private var privateSection: Bool?

    private var slot: Int { slotChoice ?? startSlot }

    private var showingPrivate: Bool { privateSection ?? startPrivate }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        Picker("Tabs", selection: Binding(get: { showingPrivate }, set: { privateSection = $0 })) {
                            Text("Tabs (\(tabs.normalCount))").tag(false)
                            Text("Private (\(tabs.privateCount))").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if tabs.split {
                            Picker("Open in", selection: Binding(get: { slot }, set: { slotChoice = $0 })) {
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
                                TabCard(t: t, tabs: tabs, frames: frames, hidden: hiddenTile == t.id, fresh: fresh[t.id]) {
                                    pick(t.id, tabs.split ? slot : 0)
                                }
                                .id(t.id)
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
                .onAppear { if let scrollTo { proxy.scrollTo(scrollTo, anchor: .center) } }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(showingPrivate ? "Private Tabs" : "Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: done) }
                if showingPrivate && tabs.privateCount > 0 && !privateLocked {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Close All Private Tabs", role: .destructive) {
                            withAnimation(.snappy) { tabs.closeAllPrivate() }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { newTab(false, tabs.split ? slot : 0) } label: {
                            Label("New Tab", systemImage: "plus.square.on.square")
                        }
                        Button { newTab(true, tabs.split ? slot : 0) } label: {
                            Label("New Private Tab", systemImage: "eye.slash")
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        newTab(showingPrivate, tabs.split ? slot : 0)
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
    var frames: TileFrames? = nil
    var hidden = false
    var fresh: UIImage? = nil
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
                    .background(GeometryReader { g in
                        let _ = frames?.set(t.id, g.frame(in: .global))
                        Color.clear
                    })
                    .opacity(hidden ? 0 : 1)
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
        } else if let img = fresh ?? tabs.thumb(t.id) {
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

// MARK: Address bar layout picker

// A tiny phone showing where the bar sits and how it's laid out.
struct BarLayoutPreview: View {
    var layout: String
    var top: Bool
    var selected: Bool
    var accent: Color

    private var capsule: some View {
        HStack(spacing: 0) {
            if layout == "twoTone" {
                Capsule().fill(accent.muted().opacity(0.55)).frame(width: 12)
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(accent.muted().opacity(0.55)).frame(width: 15)
            } else if layout == "toolbar" {
                Capsule().fill(Color.primary.opacity(0.22)).padding(.horizontal, 6)
            } else {
                HStack(spacing: 3) {
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 4)
                    Capsule().fill(Color.primary.opacity(0.22))
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 4)
                }
                .padding(.horizontal, 3)
            }
        }
        .frame(height: 8)
        .padding(1.5)
        .background(Capsule().fill(Color.primary.opacity(0.12)))
    }

    private var tools: some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                Circle().fill(Color.primary.opacity(0.4)).frame(width: 4, height: 4).frame(maxWidth: .infinity)
            }
        }
        .frame(height: 6)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: i % 2 == 0 ? 38 : 26, height: 4)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var body: some View {
        let phone = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 5) {
            if top { capsule }
            page
            if !top { capsule }
            if layout == "toolbar" { tools }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
        .frame(width: 64, height: 112)
        .background(Color(.tertiarySystemFill), in: phone)
        .overlay(phone.strokeBorder(selected ? accent : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1))
        .scaleEffect(selected ? 1 : 0.94)
    }
}

struct BarLayoutPicker: View {
    @Binding var layout: String
    @Binding var position: String
    var accent: Color
    @AppStorage("saver") private var saver = false
    private let layouts: [(id: String, name: String)] = [("twoTone", "Two-Tone"), ("single", "Single"), ("toolbar", "Toolbar")]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(layouts, id: \.id) { l in
                    Button {
                        withAnimation(saver ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { layout = l.id }
                    } label: {
                        VStack(spacing: 7) {
                            BarLayoutPreview(layout: l.id, top: position == "top", selected: layout == l.id, accent: accent)
                            Text(l.name)
                                .font(.caption.weight(layout == l.id ? .semibold : .regular))
                                .foregroundStyle(layout == l.id ? Color.primary : Color.secondary)
                            Image(systemName: layout == l.id ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(layout == l.id ? accent : Color.secondary.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(l.name) layout")
                    .accessibilityAddTraits(layout == l.id ? .isSelected : [])
                }
            }
            Picker("Position", selection: Binding(
                get: { position },
                set: { v in withAnimation(saver ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { position = v } })) {
                Text("Bottom").tag("bottom")
                Text("Top").tag("top")
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 8)
    }
}

struct SettingsView: View {
    @ObservedObject var sites: Sites
    @ObservedObject var shields: Shields
    @ObservedObject var themes: ThemeStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var vault: Vault
    @AppStorage("zoomDefault") private var zoomDefault = 1.0
    @AppStorage("zoomRemember") private var zoomRemember = true
    @AppStorage("appLock") private var appLock = false
    @AppStorage("appLockDelay") private var appLockDelay = 0
    @AppStorage("translateTo") private var translateTo = Translate.target
    @AppStorage("offerTranslate") private var offerTranslate = true
    @State private var siteZooms = Zoom.sites.count
    @AppStorage("engine") private var engine = "DuckDuckGo"
    @AppStorage("saver") private var saver = false
    @AppStorage("homeMode") private var homeMode = 0
    @AppStorage("barStyle") private var barStyle = 1
    @AppStorage("barColor") private var barColor = "System"
    @AppStorage("adaptiveText") private var adaptiveText = true
    @AppStorage("textColor") private var textColor = "System"
    @AppStorage("lockPrivate") private var lockPrivate = true
    @AppStorage("showIsland") private var showIsland = false
    @AppStorage("splitEnabled") private var splitEnabled = true
    @AppStorage("minimalBar") private var minimalBar = true
    @AppStorage("barLayout") private var barLayout = "twoTone"
    @AppStorage("barPosition") private var barPosition = "bottom"
    var openVault: () -> Void
    var openVPN: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var envScheme

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        BrandMark(size: 72)
                        Text("SplitDeck")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        Text(version).font(.footnote).foregroundStyle(.secondary)
                        Label("Shields, a Face ID vault and private tabs, all on this iPhone", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                Section("Search Engine") {
                    Picker("Search with", selection: $engine) {
                        ForEach(Engines.names, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    Picker("Appearance", selection: $themes.appearance) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .pickerStyle(.segmented)
                    .disabled(saver)
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
                    Text((saver ? "Battery Saver keeps SplitDeck dark. " : "Light and Dark keep your theme's colours, in lighter or darker shades. ")
                         + (adaptiveText
                            ? "Icons and text switch between light and dark to stay readable on each page."
                            : "Icons and text use \(textColor == "System" ? "your phone's light or dark mode" : textColor.lowercased()), with the bar shaded to keep it readable."))
                }
                Section {
                    BarLayoutPicker(layout: $barLayout, position: $barPosition, accent: themes.active(systemDark: envScheme == .dark).accent)
                    Toggle("Minimal Address Bar", isOn: $minimalBar)
                } header: {
                    Text("Address Bar")
                } footer: {
                    Text("Layout and position apply in full screen; split view keeps its slim bars."
                         + (minimalBar ? " The bar settles into a small pill showing the site, giving the page more room. Tap the pill, or scroll up, to bring the full bar back." : ""))
                }
                Section {
                    Toggle("Split View", isOn: $splitEnabled)
                    Toggle("Show Floating Island", isOn: $showIsland)
                } header: {
                    Text("Split View")
                } footer: {
                    Text((splitEnabled ? "Split View lets you show two pages at once. " : "Split View is off: SplitDeck always shows one page. ")
                         + (showIsland
                            ? "The floating island holds tabs, last-tab switching" + (splitEnabled ? " and split view" : "") + ". Drag it to either side or the top. Fling it at the edge, or tap its chevron, to tuck it away. Press and hold the tab count for new tabs."
                            : "With the island hidden, its buttons sit in the address bar and the ⋯ menu."))
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
                    Text("Private tabs are hidden behind Face ID when you leave the app, and covered in the app switcher. VPN connects only to a provider you set up yourself: SplitDeck doesn't host VPN servers, as we don't yet have the resources to run them securely.")
                }
                Section {
                    Toggle("Lock SplitDeck", isOn: Binding(get: { appLock }, set: { on in
                        // Turning it on (or off) needs the same check it will ask for later.
                        Task {
                            if await Vault.confirm(on ? "Turn on app lock" : "Turn off app lock") { appLock = on }
                        }
                    }))
                    if appLock {
                        Picker("Require", selection: $appLockDelay) {
                            Text("Immediately").tag(0)
                            Text("After 1 Minute").tag(60)
                            Text("After 5 Minutes").tag(300)
                            Text("After 15 Minutes").tag(900)
                        }
                    }
                } header: {
                    Text("App Lock")
                } footer: {
                    Text("Asks for \(Biometry.kind.name) (or your passcode) when SplitDeck opens, and hides it in the app switcher.")
                }
                Section {
                    Picker("Default Zoom", selection: $zoomDefault) {
                        ForEach(Zoom.steps, id: \.self) { Text(Zoom.label($0)).tag($0) }
                    }
                    Toggle("Remember Zoom for Each Site", isOn: $zoomRemember)
                    if siteZooms > 0 {
                        Button("Reset \(siteZooms) Site Zoom Level\(siteZooms == 1 ? "" : "s")", role: .destructive) {
                            UserDefaults.standard.removeObject(forKey: "zoomSites")
                            siteZooms = 0
                        }
                    }
                } header: {
                    Text("Page Zoom")
                } footer: {
                    Text("Change a page's zoom from ⋯ in the address bar. The default applies to every site you haven't zoomed yourself.")
                }
                Section {
                    Picker("Translate To", selection: $translateTo) {
                        ForEach(Translate.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    Toggle("Offer to Translate", isOn: $offerTranslate)
                } header: {
                    Text("Translation")
                } footer: {
                    Text("When most of a page is in another language, a translate button appears in the address bar. You can always translate from ⋯. Runs on this iPhone with Apple Translate; iOS may ask to download a language the first time.")
                }
                Section {
                    NavigationLink("Import from Safari or Chrome") {
                        ImportContent(history: history, vault: vault).navigationTitle("Import Browsing Data")
                    }
                    Button("Clear Cached Files") {
                        WKWebsiteDataStore.default().removeData(
                            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
                            modifiedSince: .distantPast) {}
                        FaviconCache.shared.clear()
                        URLCache.shared.removeAllCachedResponses()
                    }
                    Button("Default Browser") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                } header: {
                    Text("Browsing Data")
                } footer: {
                    Text("iOS only offers apps with Apple's browser entitlement as the default browser. That needs a paid developer account and App Store review, which this test build doesn't have yet, so SplitDeck can't be chosen there for now. Meanwhile, other apps and Shortcuts can open any link here with splitdeck://open?url= followed by the address.")
                }
                Section {
                    Toggle("Battery Saver", isOn: $saver)
                } footer: {
                    Text("Switches the app to dark mode, turns off every animation, keeps the address bar full size, caps page animations at 30 fps and keeps only 2 tabs awake.")
                }
                Section {
                    Button("Passwords and Cards") { openVault() }
                } header: {
                    Text("Passwords")
                } footer: {
                    Text("Logins on websites are filled by your iPhone's own AutoFill: tap a login field and pick a password above the keyboard (turn it on in Settings › General › AutoFill & Passwords). The vault keeps the passwords you add or import here, behind Face ID. Changing a username or password, or deleting a login, needs a fresh Face ID scan.")
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

// Something about to be deleted from the vault, waiting for "are you sure" and then Face ID.
enum VaultDeletion: Identifiable {
    case login(Login), card(Card)
    var id: UUID {
        switch self {
        case .login(let l): return l.id
        case .card(let c): return c.id
        }
    }
    var title: String {
        switch self {
        case .login(let l): return "the login for \(Sites.clean(l.site).isEmpty ? l.site : Sites.clean(l.site))"
        case .card(let c): return "the card ending \(String(c.number.suffix(4)))"
        }
    }
}

struct VaultView: View {
    @ObservedObject var vault: Vault
    @AppStorage("appIconName") private var iconName = ""
    @State private var deleting: VaultDeletion?

    private func confirmDelete(_ d: VaultDeletion) {
        Task {
            guard await Vault.confirm("Delete \(d.title)") else { return }
            withAnimation {
                switch d {
                case .login(let l): vault.deleteLogin(l.id)
                case .card(let c): vault.deleteCard(c.id)
                }
            }
        }
    }
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
            .alert("Delete permanently?",
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { d in
                Button("Delete", role: .destructive) { confirmDelete(d) }
                Button("Cancel", role: .cancel) {}
            } message: { d in
                Text("This removes \(d.title) from this iPhone. It can't be undone. You'll confirm with Face ID next.")
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
        .preferredColorScheme(.dark)
        .task { if !vault.unlocked { await unlock() } }
    }

    // MARK: Locked

    private var lockView: some View {
        VStack(spacing: 22) {
            ZStack {
                let o = AppIconOption.named(iconName)
                Circle()
                    .stroke(AngularGradient(colors: [o.left, .cyan, o.right, o.left], center: .center), lineWidth: 3)
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 5).repeatForever(autoreverses: false), value: spin)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 118, height: 118)
                BrandMark(size: 74)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: unlocking ? "faceid" : "lock.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom)))
                            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 2))
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.pulse, isActive: unlocking)
                            .offset(x: 9, y: 9)
                    }
            }
            VStack(spacing: 6) {
                Text("Vault Locked").font(.title2.bold()).foregroundStyle(.white)
                Text("SplitDeck Vault · protected by Face ID and the iPhone Keychain")
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
                HStack(spacing: 10) {
                    BrandMark(size: 26, glow: false)
                    Text("SplitDeck Vault").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Label("Face ID", systemImage: "faceid")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
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
        .onTapGesture { editing = l }
        .contextMenu {
            Button { editing = l } label: { Label("Edit", systemImage: "pencil") }
            Button { PasswordTools.copy(l.user) } label: { Label("Copy Username", systemImage: "person") }
            Button { PasswordTools.copy(l.pass) } label: { Label("Copy Password", systemImage: "key") }
            Button(role: .destructive) { deleting = .login(l) } label: { Label("Delete…", systemImage: "trash") }
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
        .contextMenu {
            Button { PasswordTools.copy(c.number) } label: { Label("Copy Card Number", systemImage: "creditcard") }
            Button(role: .destructive) { deleting = .card(c) } label: { Label("Delete…", systemImage: "trash") }
        }
    }
}

struct LoginEditor: View {
    @State var login: Login
    var isNew: Bool
    var save: (Login) -> Void
    var delete: (UUID) -> Void
    private let original: Login
    @Environment(\.dismiss) private var dismiss
    @State private var show = false
    @State private var checking = false
    @State private var askDelete = false

    init(login: Login, isNew: Bool, save: @escaping (Login) -> Void, delete: @escaping (UUID) -> Void) {
        _login = State(initialValue: login)
        original = login
        self.isNew = isNew
        self.save = save
        self.delete = delete
    }

    // Username or password edited on a saved login: needs Face ID before it's stored.
    private var sensitiveChange: Bool { !isNew && (login.user != original.user || login.pass != original.pass) }

    private func commit() {
        guard sensitiveChange else { save(login); dismiss(); return }
        checking = true
        Task {
            let ok = await Vault.confirm("Confirm the new username or password for \(Sites.clean(login.site))")
            checking = false
            if ok { save(login); dismiss() }
        }
    }

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
                        Button(role: .destructive) { askDelete = true } label: {
                            Label("Delete Login", systemImage: "trash")
                        }
                    } footer: {
                        Label("Changing the username or password, or deleting, needs Face ID.", systemImage: "faceid")
                            .font(.footnote)
                    }
                }
            }
            .alert("Delete permanently?", isPresented: $askDelete) {
                Button("Delete", role: .destructive) {
                    Task {
                        guard await Vault.confirm("Delete the login for \(Sites.clean(original.site))") else { return }
                        delete(login.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This login will be removed from this iPhone. It can't be undone. You'll confirm with Face ID next.")
            }
            .navigationTitle(isNew ? "New Login" : "Edit Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        commit()
                    } label: {
                        if sensitiveChange { Label("Save", systemImage: "faceid").labelStyle(.titleAndIcon) } else { Text("Save") }
                    }
                    .disabled(login.site.isEmpty || login.pass.isEmpty || checking)
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

// MARK: Bookmarks screen

struct BookmarksView: View {
    @ObservedObject var bookmarks = Bookmarks.shared
    var open: (String) -> Void
    var importData: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var renaming: Bookmark?
    @State private var newTitle = ""

    private var filtered: [Bookmark] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return bookmarks.items }
        return bookmarks.items.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { b in
                    Button {
                        open(b.url)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            SiteIcon(host: b.host, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.title).foregroundStyle(.primary).lineLimit(1)
                                Text(b.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .contextMenu {
                        Button { newTitle = b.title; renaming = b } label: { Label("Rename", systemImage: "pencil") }
                        Button { UIPasteboard.general.string = b.url } label: { Label("Copy Link", systemImage: "link") }
                        Button(role: .destructive) { withAnimation { bookmarks.remove(b.id) } } label: { Label("Delete", systemImage: "trash") }
                    }
                    .swipeActions {
                        Button(role: .destructive) { withAnimation { bookmarks.remove(b.id) } } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .overlay {
                if bookmarks.items.isEmpty {
                    ContentUnavailableView("No Bookmarks", systemImage: "book",
                                           description: Text("Tap ⋯ › Add Bookmark on any page, or import them from Safari or Chrome."))
                }
            }
            .searchable(text: $query, prompt: "Search bookmarks")
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: importData) { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("Import bookmarks")
                }
            }
            .alert("Rename Bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { b in
                TextField("Title", text: $newTitle)
                Button("Save") { bookmarks.rename(b.id, to: newTitle) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: Import browsing data

enum BrowserImport {
    // Bookmarks exported by Safari, Chrome, Firefox or Edge (the standard bookmarks .html file).
    static func bookmarks(fromHTML s: String) -> [Bookmark] {
        guard let re = try? NSRegularExpression(pattern: #"<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let url = decode(ns.substring(with: m.range(at: 1)))
            guard url.lowercased().hasPrefix("http") else { return nil }
            let raw = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            let title = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return Bookmark(title: title.isEmpty ? url : title, url: url)
        }
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // History exported by Safari (History.json). Reads any list of entries that have a web address.
    static func history(fromJSON d: Data) -> [(url: String, title: String, date: Date)] {
        guard let obj = try? JSONSerialization.jsonObject(with: d) else { return [] }
        var out: [(url: String, title: String, date: Date)] = []
        func time(_ v: Any?) -> Date? {
            guard let n = (v as? NSNumber)?.doubleValue, n > 0 else { return nil }
            if n > 1e14 { return Date(timeIntervalSince1970: n / 1_000_000) }   // microseconds
            if n > 1e11 { return Date(timeIntervalSince1970: n / 1000) }        // milliseconds
            return Date(timeIntervalSince1970: n)
        }
        func walk(_ o: Any, depth: Int) {
            guard depth < 6, out.count < 20000 else { return }
            if let a = o as? [Any] {
                a.forEach { walk($0, depth: depth + 1) }
            } else if let d = o as? [String: Any] {
                if let u = d["url"] as? String, u.lowercased().hasPrefix("http") {
                    let date = time(d["time_usec"]) ?? time(d["visit_time"]) ?? time(d["last_visit_time"]) ?? Date()
                    out.append((u, d["title"] as? String ?? "", date))
                } else {
                    d.values.forEach { walk($0, depth: depth + 1) }
                }
            }
        }
        walk(obj, depth: 0)
        return out
    }
}

struct ImportContent: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var vault: Vault
    @State private var picking = false
    @State private var working = false
    @State private var results: [String] = []

    var body: some View {
        List {
            Section {
                Label("Bookmarks: the .html bookmarks file", systemImage: "book")
                Label("History: Safari's History.json", systemImage: "clock")
                Label("Passwords: a .csv file (goes into the vault after Face ID)", systemImage: "key")
            } header: {
                Text("What you can bring in")
            }
            Section {
                Text("On iPhone: Settings › Apps › Safari › Export Browsing Data. Save it to Files, tap the .zip to unzip it, then choose the files below.")
            } header: {
                Text("From Safari")
            }
            Section {
                Text("On a computer: Bookmarks › Bookmark Manager › ⋮ › Export Bookmarks. Passwords: Settings › Autofill and passwords › Google Password Manager › Export. Then move the files to your iPhone.")
            } header: {
                Text("From Chrome")
            }
            Section {
                Button {
                    picking = true
                } label: {
                    HStack {
                        Label("Choose Files…", systemImage: "folder")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working)
            } footer: {
                Text("Everything stays on this iPhone. Delete exported files once they're imported, especially passwords.")
            }
            if !results.isEmpty {
                Section("Imported") {
                    ForEach(results, id: \.self) { Label($0, systemImage: "checkmark.circle.fill") }
                }
            }
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.html, .json, .commaSeparatedText, .plainText],
                      allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task { await handle(urls) }
        }
    }

    @MainActor
    private func handle(_ urls: [URL]) async {
        working = true
        defer { working = false }
        var out: [String] = []
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if ok { url.stopAccessingSecurityScopedResource() }
            guard let data else { continue }
            let name = url.lastPathComponent
            switch url.pathExtension.lowercased() {
            case "html", "htm":
                let n = Bookmarks.shared.merge(BrowserImport.bookmarks(fromHTML: String(decoding: data, as: UTF8.self)))
                out.append("\(n) bookmarks from \(name)")
            case "json":
                let entries = await Task.detached(priority: .userInitiated) { BrowserImport.history(fromJSON: data) }.value
                out.append("\(history.importVisits(entries)) history entries from \(name)")
            case "csv", "txt":
                if !vault.unlocked { await vault.unlock() }
                guard vault.unlocked else { out.append("Passwords in \(name) skipped: vault stayed locked"); continue }
                out.append("\(vault.importCSV(String(decoding: data, as: UTF8.self))) passwords from \(name)")
            default:
                out.append("\(name): not a file SplitDeck can read")
            }
        }
        withAnimation { results = out.isEmpty ? ["Nothing to import in those files."] : out }
    }
}

struct ImportView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ImportContent(history: history, vault: vault)
                .navigationTitle("Import Browsing Data")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: App lock

enum Biometry {
    static var kind: (name: String, icon: String) {
        let c = LAContext()
        var e: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) else { return ("Passcode", "lock.fill") }
        switch c.biometryType {
        case .faceID: return ("Face ID", "faceid")
        case .touchID: return ("Touch ID", "touchid")
        case .opticID: return ("Optic ID", "opticid")
        default: return ("Passcode", "lock.fill")
        }
    }
}

// Covers the whole app while it's locked, and in the app switcher.
struct AppLockCover: View {
    var active: Bool
    var unlock: () -> Void
    @Environment(\.sdTheme) private var theme
    private let kind = Biometry.kind

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 18) {
                BrandMark(size: 84)
                Text("SplitDeck is locked").font(.title2.bold())
                if active {
                    Button(action: unlock) {
                        Label("Unlock with \(kind.name)", systemImage: kind.icon)
                            .font(.headline)
                            .frame(maxWidth: 260, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: Main screen

enum Sheet: Identifiable {
    case vault, settings, calendar, vpn, tabs, shields, history, bookmarks, importData
    var id: Int {
        switch self {
        case .bookmarks: return 7
        case .importData: return 8
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
    @State private var calTitle = ""
    @State private var calURL = ""
    @AppStorage("showIsland") private var showIsland = false
    @AppStorage("splitEnabled") private var splitEnabled = true
    @AppStorage("barPosition") private var barPosition = "bottom"
    @AppStorage("minimalBar") private var minimalBar = true
    @AppStorage("appIconName") private var appIconName = ""
    @Environment(\.colorScheme) private var envScheme
    @State private var toast: String?
    @State private var tabsSlot = 0
    @State private var tabsOpen = false
    @State private var switcherSnap: HeroSnap?
    @State private var bookmarksPane: Pane?
    @AppStorage("appLock") private var appLock = false
    @AppStorage("appLockDelay") private var appLockDelay = 0
    @State private var appLocked = UserDefaults.standard.bool(forKey: "appLock")
    @State private var leftAt: Date?
    @State private var unlocking = false
    // Status bar and home indicator sizes. Read from the window after layout, never while SwiftUI is
    // building the screen: asking UIKit then re-enters SwiftUI's update and doubles the stack it uses.
    @State private var insets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)   // typical iPhone, replaced right after launch

    // Battery saver: dark only. Private tab on top: dark. Otherwise your Light / Dark / System choice.
    private var appScheme: ColorScheme? {
        if saver || leftIsPrivate { return .dark }
        return themes.forcedScheme
    }
    // The theme's colours in the shade that matches.
    private var activeTheme: Theme {
        themes.active(systemDark: envScheme == .dark, forceDark: saver || leftIsPrivate)
    }

    private func showToast(_ text: String) {
        withAnimation(anim(.spring(response: 0.35, dampingFraction: 0.8))) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(anim(.easeOut(duration: 0.3))) { if toast == text { toast = nil } }
        }
    }

    // The screen is built in type-erased layers. As one long chain, the view's type is nested so deeply
    // that working it out overflows the iPhone's 1 MB main-thread stack at launch (the simulator's
    // larger stack hides this), which is what crashed 1.2 on device.
    var body: some View {
        AnyView(presented)
        .onChange(of: shields.version) { _, _ in applyShields() }
        .onChange(of: blockOn) { _, _ in shields.masterChanged() }
        .onChange(of: saver) { _, _ in applySaver() }
        .onChange(of: minimalBar) { _, _ in applySaver() }
        .onChange(of: splitEnabled) { _, on in
            if !on && tabs.split { withAnimation(anim(.snappy)) { tabs.closeSplit(keep: 0) } }
        }
        .onChange(of: activeTheme) { _, _ in tabs.allLive.forEach { $0.objectWillChange.send() } }
        .onAppear { appIconName = UIApplication.shared.alternateIconName ?? "" }
        .onChange(of: engine) { _, _ in tabs.visible.forEach { tabs.pane($0).goHome() } }
        .onChange(of: phase) { _, p in phaseChanged(p) }
        .onChange(of: appLock) { _, on in if !on { appLocked = false } }
        .onOpenURL { openLink($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            tabs.sleepHidden()
        }
    }

    private func phaseChanged(_ p: ScenePhase) {
        if p != .active { vault.lock() }
        if p == .background && lockPrivate && tabs.privateCount > 0 { privateLocked = true }
        if p == .background { leftAt = Date() }
        if p == .active { refreshInsets() }
        if p == .active && appLock, let left = leftAt {
            leftAt = nil
            if Date().timeIntervalSince(left) >= Double(appLockDelay) {
                sheet = nil
                shieldsPane = nil
                tabsOpen = false
                appLocked = true
            }
            if appLocked { unlockApp() }
        }
    }

    private func refreshInsets() {
        DispatchQueue.main.async {
            let i = ContentView.windowInsets()
            if i != insets { insets = i }
        }
    }

    private var presented: some View {
        AnyView(screen)
        .sheet(item: $sheet) { s in
            sheetView(s)
                .preferredColorScheme(appScheme)
                .tint(activeTheme.accent)
                .transaction { t in if saver { t.animation = nil; t.disablesAnimations = true } }
        }
        // Its own sheet, carrying the page with it, so it never opens blank.
        .sheet(item: $shieldsPane) { p in
            ShieldsView(shields: shields, pane: p)
                .presentationDetents([.medium, .large])
                .preferredColorScheme(appScheme)
                .tint(activeTheme.accent)
        }
        .task {
            Pane.ruleProvider = { host in shields.rules(for: host) }
            Pane.youtubeProvider = { host in shields.youtubeOn(for: host) }
            Pane.onBlocked = { shields.countBlocked() }
            if appLock && appLocked { unlockApp() }
            tabs.configure = { p in configure(p) }
            tabs.allLive.forEach { configure($0) }
            applySaver()
            refreshInsets()
            await shields.prepare()
        }
    }

    private var screen: some View {
        GeometryReader { root in
            let safe = insets
            let portrait = root.size.height >= root.size.width
            let topOwnStrip = tabs.split && portrait   // the top pane draws its own strip under the status bar
            VStack(spacing: 0) {
                if !topOwnStrip {
                    TopStrip(pane: tabs.pane(tabs.left), safeTop: safe.top)
                }
                deck(portrait: portrait, safe: safe)
            }
            .onChange(of: root.size) { _, _ in refreshInsets() }
            .ignoresSafeArea(.container, edges: .vertical)
            .background(activeTheme.strip.ignoresSafeArea())
            .overlay {
                if showIsland {
                    EdgeDock(tabs: tabs, saver: saver, privateMode: leftIsPrivate, safe: safe, openTabs: { openTabs() })
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .sdGlass(Capsule())
                        .padding(.top, safe.top + 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if tabsOpen {
                    TabSwitcher(tabs: tabs,
                                startPrivate: tabs.info(tabsSlot == 1 ? tabs.right : tabs.left)?.isPrivate ?? false,
                                startSlot: tabsSlot,
                                privateLocked: privateLocked,
                                unlock: unlockPrivate,
                                snap: switcherSnap,
                                saver: saver) {
                        tabsOpen = false
                        switcherSnap = nil
                    }
                }
            }
            .overlay {
                // App lock: over everything, including the app switcher snapshot.
                if appLock && (appLocked || phase != .active) {
                    AppLockCover(active: appLocked && phase == .active, unlock: unlockApp)
                        .transition(.opacity)
                }
            }
        }
        .environment(\.sdTheme, activeTheme)
        .environment(\.sdHomeImage, themes.homeImage)
        .tint(activeTheme.accent)
        .preferredColorScheme(appScheme)
        .transaction { t in
            if saver { t.animation = nil; t.disablesAnimations = true }
        }
    }

    // MARK: Layout

    // Status bar and home indicator sizes from the window (unaffected by the keyboard).
    static func windowInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.keyWindow?.safeAreaInsets ?? .zero
    }

    private var leftIsPrivate: Bool { tabs.info(tabs.left)?.isPrivate ?? false }

    // From the island: aim at the private pane if one is showing, else the first pane.
    private func openTabs() {
        let rightPrivate = tabs.split && (tabs.info(tabs.right)?.isPrivate ?? false)
        openTabs(slot: !leftIsPrivate && rightPrivate ? 1 : 0)
    }

    private func openTabs(slot: Int) {
        guard !tabsOpen else { return }
        tabsSlot = tabs.split ? slot : 0
        tabs.snapshotVisible()
        // Full screen: capture the page so it can shrink into its tile. Split view simply fades the grid in.
        guard !saver, !tabs.split else {
            switcherSnap = nil
            tabsOpen = true
            return
        }
        TabHero.capture(tabs.pane(tabs.left)) { s in
            switcherSnap = s
            tabsOpen = true
        }
    }

    private func unlockApp() {
        guard !unlocking else { return }
        unlocking = true
        Task {
            let ok = try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock SplitDeck")
            await MainActor.run {
                unlocking = false
                if ok == true { withAnimation(anim(.easeOut(duration: 0.25))) { appLocked = false } }
            }
        }
    }

    // Opens a link from another app or Shortcuts in a new tab.
    private func openLink(_ url: URL) {
        guard let target = DeepLink.target(url) else { return }
        tabs.newTab(slot: 0)
        tabs.pane(tabs.left).load(target)
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
                    paneView(tabs.left, slot: 0, atTop: barPosition == "top", safeTop: safe.top, bottomInset: safe.bottom)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // The divider colour only exists between two panes; full screen has nothing behind the page.
            .background(tabs.split ? Color(.separator).opacity(dragging ? 0.9 : 0.55) : Color.clear)
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
                calendar: { calTitle = p.title.isEmpty ? p.host : p.title; calURL = p.address; sheet = .calendar },
                settings: { sheet = .settings },
                vpn: { sheet = .vpn },
                vpnOn: vpnService.status == .connected,
                newTab: { withAnimation(anim(.snappy)) { tabs.newTab(slot: slot) } },
                shields: { shieldsPane = p },
                shieldsUp: blockOn && shields.isUp(p.host),
                totalBlocked: shields.totalBlocked,
                newPrivateTab: { withAnimation(anim(.snappy)) { tabs.newTab(slot: slot, isPrivate: true) } },
                history: { historyPane = p; sheet = .history },
                privateLocked: privateLocked,
                unlockPrivate: unlockPrivate,
                openTabs: { openTabs(slot: slot) },
                tabCount: p.isPrivate ? tabs.privateCount : tabs.normalCount,
                toggleSplit: { withAnimation(anim(.snappy)) { tabs.toggleSplit() } },
                splitOn: tabs.split,
                swapTabs: { withAnimation(anim(.snappy)) { tabs.swap() } },
                canSwap: tabs.canSwap,
                islandShown: showIsland,
                exitPrivate: { withAnimation(anim(.snappy)) { tabs.exitPrivate(slot: slot) } },
                closePrivate: { withAnimation(anim(.snappy)) { tabs.closePrivate(slot: slot) } },
                splitEnabled: splitEnabled,
                bookmarks: { bookmarksPane = p; sheet = .bookmarks }
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
        case .vault: VaultView(vault: vault)
        case .settings: SettingsView(sites: sites, shields: shields, themes: themes, history: history, vault: vault,
                                     openVault: { sheet = .vault }, openVPN: { sheet = .vpn })
        case .calendar: EventEditor(title: calTitle, url: calURL).ignoresSafeArea()
        case .vpn: VPNView(vpn: vpnService)
        case .tabs:
            EmptyView()
        case .history:
            HistoryView(history: history, sites: sites) { text in historyPane?.load(text) }
        case .shields:
            EmptyView()
        case .bookmarks:
            BookmarksView(open: { url in (bookmarksPane ?? tabs.pane(tabs.left)).load(url) },
                          importData: { sheet = .importData })
        case .importData:
            ImportView(history: history, vault: vault)
        }
    }

    // MARK: Behaviour

    private func configure(_ p: Pane) {
        p.onVisit = { sites.record($0) }
        p.onPageLoaded = { url, title in history.addVisit(url, title: title) }
        p.onSearch = { history.addSearch($0) }
        p.applyRules(host: p.host)
        p.applyFPS()
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
        Pane.minimizeBars = !saver && UserDefaults.standard.object(forKey: "minimalBar") as? Bool ?? true
        if !Pane.minimizeBars { tabs.allLive.forEach { if $0.collapsed { $0.collapsed = false } } }
        Pane.fps = saver ? 30 : 0
        tabs.maxLive = saver ? 2 : 4
        tabs.allLive.forEach { $0.applyFPS() }
        tabs.trim()
    }

}
