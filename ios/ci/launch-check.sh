#!/usr/bin/env bash
# The launch check: opens the built app in the simulator the way a phone does (a normal launch, not as a unit-test
# host, so AppDelegate.underTest is false and the whole launch path runs: background refresh registration, permission
# prompts, region monitoring, the first replan) and fails if the app dies within WATCH seconds. Twice: a fresh install
# (no data, no permissions) and with the placeholder examples of ci/sample-data in its Application Support.
# Everything the app printed, its log lines and any crash report are kept in OUT; a screenshot of each run too.
#   ci/launch-check.sh UDID APP_PATH BUNDLE_ID SAMPLE_JSON OUT
set -uo pipefail
udid=$1 app=$2 bundle=$3 sample=$4 out=$5
# 40 s: with places and an event, the first replan may wait up to ~25 s for a location fix and MapKit's drive time
# before it opens region monitoring
watch=${WATCH:-40}
mkdir -p "$out"
reports="$HOME/Library/Logs/DiagnosticReports"
proc=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
failed=()

# the crash report of a run (the simulator's app is a Mac process: its reports land in the Mac's DiagnosticReports),
# shortened to what tells the cause: exception, assertion text, the crashed thread
crash_summary() {  # crash_summary IPS
  python3 - "$1" <<'EOF'
import json, sys
text = open(sys.argv[1]).read()
head, _, body = text.partition("\n")
try:
    r = json.loads(body)
except Exception:
    print(text[:4000]); sys.exit()
print("exception:", json.dumps(r.get("exception", {})))
print("termination:", json.dumps(r.get("termination", {}))[:600])
for k, v in (r.get("asi") or {}).items():
    print("app info:", k, v)
imgs = r.get("usedImages", [])
def frames(fs):
    for i, f in enumerate(fs[:25]):
        img = imgs[f.get("imageIndex", -1)].get("name", "?") if 0 <= f.get("imageIndex", -1) < len(imgs) else "?"
        loc = f" ({f['sourceFile']}:{f.get('sourceLine', '')})" if "sourceFile" in f else ""
        print(f"  {i:2} {img:28} {f.get('symbol', '?')}{loc}")
if r.get("lastExceptionBacktrace"):
    print("last exception backtrace:")
    frames(r["lastExceptionBacktrace"])
t = r.get("faultingThread")
if t is not None:
    print(f"crashed thread {t}:")
    frames(r["threads"][t].get("frames", []))
EOF
}

run() {  # run NAME: launch, watch, report
  local name=$1 log="$out/$1-console.txt" start pid alive=1 i
  echo "--- $name: launching $bundle, watching ${watch}s"
  touch "$out/.mark-$name"
  start=$(date +"%Y-%m-%d %H:%M:%S")
  # --console-pty: the app's stdout/stderr (an assertion's text goes there); simctl stays until the app exits
  xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle" > "$log" 2>&1 &
  local launcher=$!
  for i in $(seq 1 "$watch"); do
    sleep 1
    pid=$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null | awk -v b="UIKitApplication:$bundle" 'index($3, b) == 1 {print $1}')
    if [ "$i" -ge 3 ] && { [ -z "$pid" ] || [ "$pid" = "-" ]; }; then alive=0; break; fi
  done
  xcrun simctl io "$udid" screenshot "$out/launch-$name.png" > /dev/null 2>&1 || true
  xcrun simctl spawn "$udid" log show --start "$start" --style compact \
    --predicate "process == \"$proc\" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] \"assert\" OR eventMessage CONTAINS[c] \"exception\")" \
    > "$out/$name-log.txt" 2>&1 || true
  # this run's crash report (by the pid simctl printed); the crash reporter can take most of a minute
  local ips="" launched
  launched=$(sed -n "s/^$bundle: \([0-9][0-9]*\).*/\1/p" "$log" | head -1)
  for i in $(seq 1 $([ "$alive" = 1 ] && echo 2 || echo 60)); do
    ips=$(grep -l "\"pid\" *: *${launched:-none}," "$reports/$proc"*.ips 2>/dev/null | head -1)
    [ -n "$ips" ] && break
    sleep 1
  done
  if [ "$alive" = 1 ] && [ -z "$ips" ]; then
    echo "$name: still running after ${watch}s (pid $pid)"
  else
    echo "::error title=Launch check ($name)::GupDo died within ${watch}s of a normal launch"
    failed+=("$name")
    echo "console:"; tail -40 "$log"
    if [ -n "$ips" ]; then
      cp "$ips" "$out/$name-crash.ips"
      echo "crash report:"; crash_summary "$ips" | tee "$out/$name-crash.txt"
    fi
    echo "log (errors and faults):"; tail -40 "$out/$name-log.txt"
  fi
  xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1 || true
  kill "$launcher" 2> /dev/null || true
  wait "$launcher" 2> /dev/null || true
}

# 1. a fresh install: no data, no permission answered yet (what a phone has on first open)
xcrun simctl uninstall "$udid" "$bundle" > /dev/null 2>&1 || true
xcrun simctl install "$udid" "$app" || { echo "::error title=Launch check::install failed"; exit 1; }
xcrun simctl privacy "$udid" reset all "$bundle" > /dev/null 2>&1 || true
run fresh

# 2. the placeholder examples in its data file (a habit ringing now, places, an event with a Where), permissions given
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
mkdir -p "$data/Library/Application Support"
cp "$sample" "$data/Library/Application Support/gupdo.json"
for s in location-always motion; do xcrun simctl privacy "$udid" grant "$s" "$bundle" > /dev/null 2>&1 || true; done
run sample

rm -f "$out"/.mark-*
# leave the simulator as the tests found it (no app, no data)
xcrun simctl uninstall "$udid" "$bundle" > /dev/null 2>&1 || true
if [ ${#failed[@]} -gt 0 ]; then
  echo "launch check FAILED: ${failed[*]} (details in $out)"
  exit 1
fi
echo "launch check: the app stayed open in every run"
