#!/bin/bash
# Launches the simulator build, checks it stays running, and reports any crash as run annotations.
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
xcrun simctl launch --stdout=/tmp/sd-out.txt --stderr=/tmp/sd-err.txt "$UDID" "$BUNDLE"
sleep 20
if xcrun simctl spawn "$UDID" launchctl list | grep -q "$BUNDLE"; then
  echo "::notice title=Launch test::SplitDeck is still running after 20 seconds"
  STATUS=0
else
  echo "::error title=Launch test::SplitDeck is not running 20 seconds after launch"
  STATUS=1
fi
sleep 5
python3 - << 'PY'
import glob, json, os
def esc(s): return s.replace('%', '%25').replace('\r', '').replace('\n', '%0A')
for f in ["/tmp/sd-err.txt", "/tmp/sd-out.txt"]:
    if os.path.exists(f):
        t = open(f, errors="replace").read().strip()
        if t:
            print(f"::warning title=App output ({os.path.basename(f)})::" + esc(t[-3000:]))
reports = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/SplitDeck*")))
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
        if asi: lines.append(f"Info: {json.dumps(asi)[:800]}")
        imgs = j.get("usedImages", [])
        th = next((t for t in j.get("threads", []) if t.get("triggered")), None)
        if th:
            for fr in th.get("frames", [])[:30]:
                name = imgs[fr["imageIndex"]].get("name", "?") if fr.get("imageIndex") is not None and fr["imageIndex"] < len(imgs) else "?"
                lines.append(f"{name}  {fr.get('symbol', hex(fr.get('imageOffset', 0)))}  {fr.get('sourceFile','')}:{fr.get('sourceLine','')}")
    except Exception as e:
        lines = raw.splitlines()[:60]
    print("::error title=Crash report::" + esc("\n".join(lines))[:8000])
PY
exit $STATUS
