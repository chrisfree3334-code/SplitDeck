import SwiftUI
import WebKit
import LocalAuthentication
import Security
import UniformTypeIdentifiers

@main
struct SplitDeckApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

func q(_ s: String) -> String {
    (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
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

// MARK: Ad, tracker and cookie-banner rules

enum Rules {
    static let hosts = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "adservice.google.com", "connect.facebook.net", "scorecardresearch.com", "taboola.com", "outbrain.com",
        "criteo.com", "adnxs.com", "amazon-adsystem.com", "hotjar.com", "quantserve.com", "pubmatic.com",
        "rubiconproject.com", "openx.net", "moatads.com", "ads-twitter.com", "analytics.tiktok.com"]

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
        return try? await store.compileContentRuleList(forIdentifier: "sd1", encodedContentRuleList: s)
    }

    static let decline = "(function(){var s=['#onetrust-reject-all-handler','#CybotCookiebotDialogBodyButtonDecline','#didomi-notice-disagree-button','.fc-cta-do-not-consent','button.cc-deny','[data-testid=reject-all]','[aria-label=\"Reject all\"]','.js-reject-cookies'];var n=0;var t=setInterval(function(){s.forEach(function(x){var b=document.querySelector(x);if(b)b.click()});if(++n>20)clearInterval(t)},500)})();"

    static let capture = "document.addEventListener('submit',function(e){var f=e.target;var p=f.querySelector('input[type=password]');if(!p||!p.value)return;var u=f.querySelector('input[type=email],input[type=text],input[autocomplete=username]');window.webkit.messageHandlers.cred.postMessage({site:location.origin,user:u?u.value:'',pass:p.value})},true);"
}

// MARK: One browser pane

final class Pane: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKScriptMessageHandler {
    let id = UUID()
    let webView: WKWebView
    @Published var address: String
    var onCredential: ((Login) -> Void)?
    static let setJS = "function S(e,v){Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}))}"

    init(start: String) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.upgradeKnownHostsToHTTPS = true
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        config.userContentController.addUserScript(WKUserScript(source: Rules.decline, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: Rules.capture, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        webView = wv
        address = start
        super.init()
        wv.navigationDelegate = self
        config.userContentController.add(self, name: "cred")
        load(start)
    }

    func load(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let url: URL?
        if t.contains(" ") || !t.contains(".") {
            let s = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
            url = URL(string: "https://duckduckgo.com/?q=\(s)")
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url?.absoluteString { address = u }
    }
}

struct WebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct PaneView: View {
    @ObservedObject var pane: Pane
    @State private var desktop = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { pane.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { pane.webView.goForward() } label: { Image(systemName: "chevron.right") }
                TextField("Search or enter site", text: $pane.address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .focused($focused)
                    .onSubmit { pane.load(pane.address); focused = false }
                Button { pane.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { desktop.toggle(); pane.setDesktop(desktop) } label: { Image(systemName: desktop ? "desktopcomputer" : "iphone") }
            }
            .padding(6)
            .background(.bar)
            WebHost(webView: pane.webView)
        }
        .clipped()
    }
}

// MARK: Vault screen

struct VaultView: View {
    @ObservedObject var vault: Vault
    var fill: (Login?, Card?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var msg = ""
    @State private var cn = "", cnum = "", cexp = "", ccvc = ""

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

struct ContentView: View {
    @StateObject private var first = Pane(start: "https://duckduckgo.com")
    @StateObject private var second = Pane(start: "https://en.wikipedia.org")
    @StateObject private var vault = Vault()
    @Environment(\.scenePhase) private var phase
    @State private var split: CGFloat = 0.5
    @State private var splitOn = true
    @State private var showSecond = false
    @State private var blockOn = true
    @State private var rules: WKContentRuleList?
    @State private var showVault = false
    @State private var pending: Login?
    private let handle: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let horizontal = geo.size.width > geo.size.height
            let total = horizontal ? geo.size.width : geo.size.height
            let firstSize = (total - handle) * split
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            Group {
                if splitOn {
                    layout {
                        PaneView(pane: first)
                            .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                        divider(horizontal: horizontal, total: total)
                        PaneView(pane: second)
                    }
                    .coordinateSpace(.named("deck"))
                } else {
                    PaneView(pane: showSecond ? second : first)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                Toggle("Split view", isOn: $splitOn)
                if !splitOn { Button("Switch page") { showSecond.toggle() } }
                Toggle("Block ads and trackers", isOn: $blockOn)
                Button("Passwords and cards") { showVault = true }
            } label: {
                Image(systemName: "ellipsis.circle.fill").font(.title2).padding(10)
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showVault) { VaultView(vault: vault, fill: fill) }
        .alert("Save password?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Save") { if let p = pending { vault.logins.append(p); vault.save() }; pending = nil }
            Button("Not now", role: .cancel) { pending = nil }
        } message: { Text(pending?.site ?? "") }
        .task {
            first.onCredential = { pending = $0 }
            second.onCredential = { pending = $0 }
            rules = await Rules.compile()
            apply()
        }
        .onChange(of: blockOn) { _, _ in apply() }
        .onChange(of: phase) { _, p in if p != .active { vault.lock() } }
    }

    private func apply() {
        for p in [first, second] {
            let u = p.webView.configuration.userContentController
            u.removeAllContentRuleLists()
            if blockOn, let r = rules { u.add(r) }
            p.webView.reload()
        }
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
            Color(.systemGray5)
            Capsule().fill(Color.secondary)
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
