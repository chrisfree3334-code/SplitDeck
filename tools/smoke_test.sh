#!/bin/bash
# Launch test: installs the simulator build, then checks it survives a fresh launch, opening a page
# from a link, and a relaunch that restores tabs. Any crash is reported as a run annotation.
set -u
APP="$1"
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
for rt in sorted(d, reverse=True):
    if 'iOS' not in rt: continue
    for dev in d[rt]:
        if dev['name'].startswith('iPhone'):
            print(dev['udid']); sys.exit()
")
echo "Simulator: $UDID  Bundle: $BUNDLE"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
rm -f ~/Library/Logs/DiagnosticReports/SplitDeck* 2>/dev/null

report() {
python3 - "$1" << 'PY'
import glob, json, os, sys
label = sys.argv[1]
def esc(s): return s.replace('%', '%25').replace('\r', '').replace('\n', '%0A')
for f in ["/tmp/sd-err.txt"]:
    if os.path.exists(f):
        t = open(f, errors="replace").read().strip()
        if t: print(f"::warning title=App output ({label})::" + esc(t[-2500:]))
reports = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/SplitDeck*")), key=os.path.getmtime)
for r in reports[-1:]:
    raw = open(r, errors="replace").read()
    lines = []
    try:
        head, body = raw.split("\n", 1)
        j = json.loads(body)
        ex = j.get("exception", {})
        lines.append(f"Exception: {ex.get('type')} {ex.get('signal','')} {ex.get('subtype','')}")
        term = j.get("termination", {})
        lines.append(f"Termination: {term.get('indicator','')} {term.get('reasons','')}")
        asi = j.get("asi")
        if asi: lines.append(f"Info: {json.dumps(asi)[:1200]}")
        imgs = j.get("usedImages", [])
        th = next((t for t in j.get("threads", []) if t.get("triggered")), None)
        if th:
            for fr in th.get("frames", [])[:28]:
                i = fr.get("imageIndex")
                name = imgs[i].get("name", "?") if i is not None and i < len(imgs) else "?"
                lines.append(f"{name}  {fr.get('symbol', hex(fr.get('imageOffset', 0)))}  {fr.get('sourceFile','')}:{fr.get('sourceLine','')}")
    except Exception:
        lines = raw.splitlines()[:60]
    print(f"::error title=Crash report ({label})::" + esc("\n".join(lines))[:8000])
PY
}

alive() {
  sleep "$2"
  if xcrun simctl spawn "$UDID" launchctl list | grep -q "UIKitApplication:$BUNDLE"; then
    echo "::notice title=Launch test::$1: still running"
  else
    echo "::error title=Launch test::$1: SplitDeck stopped"
    sleep 5; report "$1"; exit 1
  fi
}

xcrun simctl launch --stderr=/tmp/sd-err.txt "$UDID" "$BUNDLE"
alive "Fresh launch" 15
xcrun simctl openurl "$UDID" "splitdeck://open?url=https://www.youtube.com"
alive "Opened YouTube from a link" 20
xcrun simctl openurl "$UDID" "splitdeck://open?url=https://www.lemonde.fr"
alive "Opened a French page" 20
xcrun simctl terminate "$UDID" "$BUNDLE"
sleep 2
xcrun simctl launch --stderr=/tmp/sd-err.txt "$UDID" "$BUNDLE"
alive "Relaunch with restored tabs" 20
exit 0
