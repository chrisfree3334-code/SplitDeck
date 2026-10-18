
#!/usr/bin/env python3
"""Download Brave-style filter lists and convert them to WebKit content-blocker JSON.

Usage: python3 tools/build_blocklists.py <output-folder>

Each list becomes sd-<name>.json in the output folder, plus blocklists-version.txt.
Only syntax that maps cleanly onto WebKit content blockers is converted; anything
else (scriptlets, extended CSS, regex rules, redirect/csp options...) is skipped.
A failed download leaves that list out, and the app falls back to its built-in list.
"""
import datetime
import json
import os
import re
import sys
import urllib.request

LISTS = {
    "ads": ["https://easylist.to/easylist/easylist.txt"],
    "trackers": [
        "https://easylist.to/easylist/easyprivacy.txt",
        "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext",
    ],
    "cookies": ["https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"],
    "annoyances": ["https://secure.fanboy.co.nz/fanboy-annoyance.txt"],
}

MAX_RULES = 140000

TYPE_MAP = {
    "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
    "font": "font", "media": "media", "xmlhttprequest": "raw", "xhr": "raw", "websocket": "raw",
    "ping": "raw", "other": "raw", "object": "raw", "subdocument": "document", "frame": "document",
    "popup": "popup",
}
ALL_TYPES = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]

EXTENDED_CSS = re.compile(
    r":(-abp-|has-text|contains|xpath|matches-css|upward|remove|style|matches-path|min-text-length|"
    r"watch-attr|others|if\(|if-not|nth-ancestor|matches-attr|matches-prop|matches-media|remove-attr|"
    r"remove-class|properties|shadow|light)"
)
UNSUPPORTED_COSMETIC = re.compile(r"#@?[?$%]#|\$@?\$|#\+js|#@\+js")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 SplitDeck-list-builder"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8", errors="replace")


def norm_domain(d):
    d = d.strip().lower().rstrip(".")
    if not d or "*" in d or "/" in d or " " in d:
        return None
    try:
        d = d.encode("idna").decode("ascii")
    except Exception:
        return None
    if not re.fullmatch(r"[a-z0-9.-]+", d):
        return None
    return d


def to_url_filter(pat):
    """Convert an ABP pattern to WebKit's url-filter regex subset, or None if it can't be expressed."""
    if pat.startswith("/") and pat.endswith("/") and len(pat) > 1:
        return None  # raw regex rules: syntax differs too much
    if any(ord(c) > 127 for c in pat):
        return None
    domain_anchor = start_anchor = end_anchor = False
    if pat.startswith("||"):
        domain_anchor, pat = True, pat[2:]
    elif pat.startswith("|"):
        start_anchor, pat = True, pat[1:]
    if pat.endswith("|"):
        end_anchor, pat = True, pat[:-1]
    if "|" in pat:
        return None
    if not domain_anchor and not start_anchor:
        pat = pat.lstrip("*")
    if not end_anchor:
        pat = pat.rstrip("*")
    # A trailing separator after a path can't be expressed without alternation: drop it.
    if pat.endswith("^") and "/" in pat:
        pat = pat[:-1]
    if not pat:
        return None
    out = []
    for c in pat:
        if c == "*":
            out.append(".*")
        elif c == "^":
            out.append("[/:?=&]")
        elif c in ".+?()[]{}\\$":
            out.append("\\" + c)
        else:
            out.append(c)
    body = re.sub(r"(\.\*)+", ".*", "".join(out))
    if body in (".*", ""):
        return None
    if domain_anchor:
        body = "^[^:]+://+([^:/]+\\.)?" + body
    elif start_anchor:
        body = "^" + body
    elif len(body) < 4:
        return None  # too broad to be safe
    if end_anchor:
        body += "$"
    return body


def parse_options(opt_str, exception):
    """Returns (trigger_extras, cosmetic_exception_kind) or None if the rule should be skipped."""
    trig = {}
    types_pos, types_neg = set(), set()
    if_dom, unless_dom = [], []
    kind = None
    for o in opt_str.split(","):
        o = o.strip()
        if not o:
            continue
        neg = o.startswith("~")
        name = o[1:] if neg else o
        val = None
        if "=" in name:
            name, val = name.split("=", 1)
        name = name.lower()
        if name in ("domain", "from"):
            if not val:
                return None
            for d in val.split("|"):
                n = d.startswith("~")
                d = norm_domain(d[1:] if n else d)
                if d is None:
                    return None
                (unless_dom if n else if_dom).append("*" + d)
        elif name in ("third-party", "3p"):
            trig["load-type"] = ["first-party" if neg else "third-party"]
        elif name in ("first-party", "1p"):
            trig["load-type"] = ["third-party" if neg else "first-party"]
        elif name == "match-case":
            trig["url-filter-is-case-sensitive"] = True
        elif name == "important":
            pass
        elif name == "all":
            types_pos.update(ALL_TYPES)
        elif name in TYPE_MAP:
            (types_neg if neg else types_pos).add(TYPE_MAP[name])
        elif name == "document" and not exception:
            types_pos.add("document")
        elif exception and name in ("elemhide", "ehide"):
            kind = "elemhide"
        elif exception and name in ("generichide", "ghide"):
            kind = kind or "generichide"
        else:
            return None  # csp, redirect, removeparam, $document exceptions, etc.
    if types_pos:
        types = sorted(types_pos)
    elif types_neg:
        types = [t for t in ALL_TYPES if t not in types_neg]
    else:
        types = None
    if types is not None:
        if not types:
            return None
        trig["resource-type"] = types
    if if_dom:
        trig["if-domain"] = sorted(set(if_dom))
    elif unless_dom:
        trig["unless-domain"] = sorted(set(unless_dom))
    return trig, kind


def convert(text):
    generic_css = {}          # selector -> set of excluded domains
    generic_killed = set()    # selectors excepted everywhere
    specific_css = []
    css_exceptions = {}       # selector -> set of domains
    gh_exc, eh_exc, blocks, allows = [], [], [], []
    skipped = 0

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("!") or line.startswith("["):
            continue
        if UNSUPPORTED_COSMETIC.search(line):
            skipped += 1
            continue
        m = re.match(r"^([^#]*?)(##|#@#)(.+)$", line)
        if m:
            doms, sep, sel = m.group(1), m.group(2), m.group(3).strip()
            if (not sel or sel.startswith("+js") or sel.startswith("^") or "{" in sel
                    or EXTENDED_CSS.search(sel) or any(ord(c) > 127 for c in sel)):
                skipped += 1
                continue
            pos, negs = [], []
            bad = False
            for d in filter(None, doms.split(",")):
                n = d.startswith("~")
                nd = norm_domain(d[1:] if n else d)
                if nd is None:
                    bad = True
                    break
                (negs if n else pos).append("*" + nd)
            if bad:
                skipped += 1
                continue
            if sep == "#@#":
                if pos:
                    css_exceptions.setdefault(sel, set()).update(pos)
                else:
                    generic_killed.add(sel)
                continue
            if pos:
                specific_css.append({"trigger": {"url-filter": ".*", "if-domain": sorted(set(pos))},
                                     "action": {"type": "css-display-none", "selector": sel}})
            else:
                generic_css.setdefault(sel, set()).update(negs)
            continue

        exception = line.startswith("@@")
        body = line[2:] if exception else line
        opts = ""
        if "$" in body and not (body.startswith("/") and body.endswith("/")):
            body, opts = body.rsplit("$", 1)
        parsed = parse_options(opts, exception) if opts else ({}, None)
        if parsed is None:
            skipped += 1
            continue
        extras, kind = parsed
        uf = to_url_filter(body) if body else None
        if uf is None:
            skipped += 1
            continue
        trigger = {"url-filter": uf, **extras}
        if kind:
            trigger.pop("resource-type", None)
            (eh_exc if kind == "elemhide" else gh_exc).append(
                {"trigger": trigger, "action": {"type": "ignore-previous-rules"}})
        elif exception:
            allows.append({"trigger": trigger, "action": {"type": "ignore-previous-rules"}})
        else:
            blocks.append({"trigger": trigger, "action": {"type": "block"}})

    generic = []
    for sel, negs in generic_css.items():
        if sel in generic_killed:
            continue
        negs = set(negs) | css_exceptions.get(sel, set())
        trig = {"url-filter": ".*"}
        if negs:
            trig["unless-domain"] = sorted(negs)
        generic.append({"trigger": trig, "action": {"type": "css-display-none", "selector": sel}})

    # Order matters: ignore-previous-rules only affects rules listed before it.
    rules = generic + gh_exc + specific_css + eh_exc + blocks + allows
    if len(rules) > MAX_RULES:
        rules = rules[:MAX_RULES - len(allows)] + allows
    return rules, skipped


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "Sources/Blocklists"
    os.makedirs(out_dir, exist_ok=True)
    for name, urls in LISTS.items():
        texts = []
        for u in urls:
            try:
                texts.append(fetch(u))
                print(f"downloaded {u}")
            except Exception as e:
                print(f"WARNING: could not download {u}: {e}")
        path = os.path.join(out_dir, f"sd-{name}.json")
        if not texts:
            if os.path.exists(path):
                os.remove(path)
            continue
        rules, skipped = convert("\n".join(texts))
        with open(path, "w") as f:
            json.dump(rules, f, separators=(",", ":"))
        print(f"{name}: {len(rules)} rules ({skipped} lines skipped)")
    with open(os.path.join(out_dir, "blocklists-version.txt"), "w") as f:
        f.write(datetime.datetime.utcnow().strftime("%Y%m%d%H%M"))


if __name__ == "__main__":
    main()
