import SwiftUI
import WebKit
import LocalAuthentication
import Security
import UniformTypeIdentifiers
import EventKit
import EventKitUI

@main
struct SplitDeckApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

func q(_ s: String) -> String {
    (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
}

enum Engines {
    static let names = ["DuckDuckGo", "Google", "Bing", "Brave", "Ecosia"]
    static let urls = ["DuckDuckGo": "https://duckduckgo.com/?q=", "Google": "https://www.google.com/search?q=",
                       "Bing": "https://www.bing.com/search?q=", "Brave": "https://search.brave.com/search?q=",
                       "Ecosia": "https://www.ecosia.org/search?q="]
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

// MARK: One browser pane

final class Pane: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    let webView: WKWebView
    @Published var address: String
    @Published var collapsed = false
    @Published var hasLogin = false
    @Published var hasCard = false
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
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url { address = u.absoluteString; host = u.host ?? "" }
        title = webView.title ?? ""
        webView.evaluateJavaScript("((document.querySelector('input[type=password]')?1:0)+(document.querySelector('[autocomplete=cc-number]')?2:0))") { [weak self] r, _ in
            let v = (r as? Int) ?? 0
            self?.hasLogin = (v & 1) != 0
            self?.hasCard = (v & 2) != 0
        }
    }
}

struct WebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct PaneView: View {
    @ObservedObject var pane: Pane
    var autofill: () -> Void
    var calendar: () -> Void
    var removePopups: () -> Void
    @State private var desktop = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            WebHost(webView: pane.webView)
            bar.padding(.horizontal, 8).padding(.bottom, 20)
        }
        .clipped()
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var bar: some View {
        if pane.collapsed && !focused {
            Button { pane.collapsed = false } label: {
                Text(pane.host.isEmpty ? "Search" : pane.host)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .background(.ultraThinMaterial, in: Capsule())
        } else {
            HStack(spacing: 0) {
                navButton("chevron.left") { pane.webView.goBack() }
                navButton("chevron.right") { pane.webView.goForward() }
                TextField("Search or enter site", text: $pane.address)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .focused($focused)
                    .onSubmit { pane.load(pane.address); focused = false }
                    .padding(.horizontal, 6)
                    .frame(height: 44)
                if pane.hasLogin { navButton("key.fill") { autofill() } }
                if pane.hasCard { navButton("creditcard.fill") { autofill() } }
                Menu {
                    Button { pane.webView.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button { desktop.toggle(); pane.setDesktop(desktop) } label: {
                        Label(desktop ? "Mobile site" : "Desktop site", systemImage: desktop ? "iphone" : "desktopcomputer")
                    }
                    Button { removePopups() } label: { Label("Remove popups", systemImage: "xmark.rectangle") }
                    Button { calendar() } label: { Label("Add to Calendar", systemImage: "calendar.badge.plus") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 4)
            .background(.ultraThinMaterial, in: Capsule())
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
    case vault, settings, calendar
    var id: Int {
        switch self {
        case .vault: return 0
        case .settings: return 1
        case .calendar: return 2
        }
    }
}

struct ContentView: View {
    @StateObject private var first = Pane(start: "https://duckduckgo.com")
    @StateObject private var second = Pane(start: "https://en.wikipedia.org")
    @StateObject private var vault = Vault()
    @Environment(\.scenePhase) private var phase
    @AppStorage("block") private var blockOn = true
    @AppStorage("battery") private var battery = 0
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
            deck.ignoresSafeArea()
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
        .onChange(of: phase) { _, p in if p != .active { vault.lock() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in applyFPS() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer()
            if !splitOn {
                Button { showSecond.toggle() } label: {
                    Label(showSecond ? "Page 2" : "Page 1", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
                .background(.ultraThinMaterial, in: Capsule())
            }
            Button { splitOn.toggle() } label: {
                Label(splitOn ? "Split" : "Single", systemImage: splitOn ? "rectangle.split.2x1.fill" : "rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .background(.ultraThinMaterial, in: Capsule())
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 38)
            }
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var deck: some View {
        GeometryReader { geo in
            let horizontal = geo.size.width > geo.size.height
            let total = horizontal ? geo.size.width : geo.size.height
            let firstSize = (total - handle) * split
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            if splitOn {
                layout {
                    pane(first)
                        .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                    divider(horizontal: horizontal, total: total)
                    pane(second)
                }
                .coordinateSpace(.named("deck"))
            } else {
                pane(showSecond ? second : first)
            }
        }
    }

    private func pane(_ p: Pane) -> PaneView {
        PaneView(pane: p,
                 autofill: { autofill(p) },
                 calendar: { calTitle = p.title.isEmpty ? p.host : p.title; calURL = p.address; sheet = .calendar },
                 removePopups: { p.webView.evaluateJavaScript(Rules.popupKill) })
    }

    @ViewBuilder private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .vault: VaultView(vault: vault, fill: fill)
        case .settings: SettingsView(openVault: { sheet = .vault })
        case .calendar: EventEditor(title: calTitle, url: calURL).ignoresSafeArea()
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
