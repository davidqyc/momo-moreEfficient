#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_ROOT="$ROOT/ios"
PROJECT="$IOS_ROOT/MomoMoreEfficient.xcodeproj"
SCHEME="MomoMoreEfficient"
APP_ENTITLEMENTS="$IOS_ROOT/MomoMoreEfficient/MomoMoreEfficient.entitlements"
EXT_ENTITLEMENTS="$IOS_ROOT/ShareExtension/ShareExtension.entitlements"
APP_GROUP="group.com.jiripple.xiaoheiniao.capture"
APP_BUNDLE_ID="com.jiripple.xiaoheiniao"
EXT_BUNDLE_ID="com.jiripple.xiaoheiniao.ShareExtension"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

note() {
  echo
  echo "==> $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_command xcodebuild
require_command xcrun
require_command python3
[[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy not found"
[[ -d "$PROJECT" ]] || fail "Xcode project not found: $PROJECT"

note "Toolchain"
xcodebuild -version
xcrun simctl help >/dev/null

read_build_setting() {
  local target="$1"
  local key="$2"
  xcodebuild \
    -project "$PROJECT" \
    -target "$target" \
    -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }'
}

check_exact_app_group() {
  local file="$1"
  local first
  first="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$file" 2>/dev/null || true)"
  [[ "$first" == "$APP_GROUP" ]] || fail "$file App Group mismatch: '$first'"
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:1' "$file" >/dev/null 2>&1; then
    fail "$file contains more than the one approved capture App Group"
  fi
}

note "Static signing contract"
actual_app_bundle="$(read_build_setting MomoMoreEfficient PRODUCT_BUNDLE_IDENTIFIER)"
actual_ext_bundle="$(read_build_setting ShareExtension PRODUCT_BUNDLE_IDENTIFIER)"
actual_app_entitlements="$(read_build_setting MomoMoreEfficient CODE_SIGN_ENTITLEMENTS)"
actual_ext_entitlements="$(read_build_setting ShareExtension CODE_SIGN_ENTITLEMENTS)"

[[ "$actual_app_bundle" == "$APP_BUNDLE_ID" ]] || fail "main app bundle id mismatch: '$actual_app_bundle'"
[[ "$actual_ext_bundle" == "$EXT_BUNDLE_ID" ]] || fail "ShareExtension bundle id mismatch: '$actual_ext_bundle'"
[[ "$actual_app_entitlements" == "MomoMoreEfficient/MomoMoreEfficient.entitlements" ]] || fail "main app entitlements path mismatch: '$actual_app_entitlements'"
[[ "$actual_ext_entitlements" == "ShareExtension/ShareExtension.entitlements" ]] || fail "ShareExtension entitlements path mismatch: '$actual_ext_entitlements'"
check_exact_app_group "$APP_ENTITLEMENTS"
check_exact_app_group "$EXT_ENTITLEMENTS"
echo "PASS bundle ids and exact App Group contract"

SIM_UDID=""
cleanup() {
  if [[ -n "$SIM_UDID" ]]; then
    xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIM_UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -n "${IOS_DESTINATION:-}" ]]; then
  DESTINATION="$IOS_DESTINATION"
else
  note "Create an isolated latest-iOS simulator"
  runtime_id="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r.get("platform") == "iOS"]
if not runtimes:
    raise SystemExit("no available iOS simulator runtime")
def version(r):
    return tuple(int(p) for p in r.get("version", "0").split("."))
print(max(runtimes, key=version)["identifier"])
')"
  device_type="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
items = [d for d in json.load(sys.stdin)["devicetypes"] if d.get("name", "").startswith("iPhone")]
if not items:
    raise SystemExit("no iPhone simulator device type")
preferred = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16"]
by_name = {d["name"]: d["identifier"] for d in items}
for name in preferred:
    if name in by_name:
        print(by_name[name])
        break
else:
    print(items[-1]["identifier"])
')"
  SIM_UDID="$(xcrun simctl create "momo-capture-gate-${GITHUB_RUN_ID:-local}-$$" "$device_type" "$runtime_id")"
  xcrun simctl boot "$SIM_UDID"
  xcrun simctl bootstatus "$SIM_UDID" -b
  DESTINATION="platform=iOS Simulator,id=$SIM_UDID"
fi

echo "Using destination: $DESTINATION"

note "Focused capture XCTest gate"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -only-testing:MomoMoreEfficientTests/ShareCaptureTests \
  -only-testing:MomoMoreEfficientTests/CaptureReviewTests \
  -only-testing:MomoMoreEfficientUITests/CapturePendingReviewUITests \
  -only-testing:MomoMoreEfficientUITests/CaptureShareSheetUITests \
  test

note "Release simulator build including embedded ShareExtension"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

note "Release generic-device compile including embedded ShareExtension"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

note "Capture release automation PASS"
echo "System Share Sheet extension-row selection is now automated on Simulator (CaptureShareSheetUITests); no residual manual Share Sheet smoke for the routine regression case."
echo "The real out-of-process App Intents Testing lane requires the iOS 27.0+ Beta SDK, is deliberately not part of this project's toolchain yet, and is tracked separately in issue #165."