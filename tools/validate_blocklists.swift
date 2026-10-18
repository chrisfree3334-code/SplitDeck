// Compiles each content-blocker JSON with WebKit on the build Mac.
// If a list fails, it is split in halves until the rules WebKit rejects are found and removed,
// then the cleaned list is written back. Usage: ./validate file1.json file2.json ...
import Foundation
import WebKit

guard let store = WKContentRuleListStore.default() else {
    print("WARNING: no WebKit rule store; skipping validation")
    exit(0)
}

var counter = 0

func compiles(_ rules: [Any]) -> Bool {
    guard !rules.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: rules),
          let json = String(data: data, encoding: .utf8) else { return false }
    counter += 1
    let id = "validate-\(counter)"
    var result: Bool?
    store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, _ in
        result = (list != nil)
    }
    while result == nil { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    var removed = false
    store.removeContentRuleList(forIdentifier: id) { _ in removed = true }
    while !removed { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    return result!
}

var dropped = 0

func clean(_ rules: [Any]) -> [Any] {
    if rules.isEmpty { return [] }
    if compiles(rules) { return rules }
    if rules.count == 1 { dropped += 1; return [] }
    let mid = rules.count / 2
    return clean(Array(rules[..<mid])) + clean(Array(rules[mid...]))
}

// Sanity check: if WebKit can't compile even a trivial list here, don't touch anything.
let probe: [Any] = [["trigger": ["url-filter": "example-probe"], "action": ["type": "block"]]]
if !compiles(probe) {
    print("WARNING: WebKit compile unavailable on this machine; skipping validation")
    exit(0)
}

for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path),
          let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
        print("WARNING: could not read \(path)")
        continue
    }
    dropped = 0
    let start = Date()
    let good = clean(rules)
    if dropped > 0, let out = try? JSONSerialization.data(withJSONObject: good) {
        try? out.write(to: URL(fileURLWithPath: path))
    }
    print("\(path): \(good.count) rules OK, \(dropped) removed (\(Int(Date().timeIntervalSince(start)))s)")
}
