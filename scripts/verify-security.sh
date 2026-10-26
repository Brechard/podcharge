#!/bin/bash
set -uo pipefail

usage() {
    echo "Usage: $0 [--probe] /path/to/PodCharge.app" >&2
}

run_probe=false
if [[ ${1:-} == "--probe" ]]; then
    run_probe=true
    shift
fi
if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

app_input=$1
if [[ ! -d "$app_input" ]]; then
    echo "FAIL: app bundle does not exist: $app_input" >&2
    exit 2
fi
app_dir=$(cd "$app_input" && pwd -P) || exit 2
root_dir=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
info_plist="$app_dir/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
    echo "FAIL: missing Contents/Info.plist in $app_dir" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/podcharge-security.XXXXXX") || exit 2
trap 'rm -rf "$tmp_dir"' EXIT

failures=0
inconclusives=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
inconclusive() { printf 'INCONCLUSIVE: %s\n' "$1" >&2; inconclusives=$((inconclusives + 1)); }

if /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"; then
    pass "code signature verifies"
else
    fail "code signature does not verify"
fi

entitlements="$tmp_dir/entitlements.plist"
if /usr/bin/codesign -d --entitlements :- --xml "$app_dir" >"$entitlements" 2>"$tmp_dir/codesign-entitlements.log" \
    && /usr/bin/plutil -lint "$entitlements" >/dev/null 2>&1; then
    pass "signed entitlements can be read"
else
    fail "could not read a valid signed entitlement plist"
    entitlements=""
fi

plist_value() {
    local plist=$1 key=$2
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

if [[ -n "$entitlements" ]]; then
    for key in com.apple.security.app-sandbox com.apple.security.device.bluetooth; do
        if [[ $(plist_value "$entitlements" "$key" || true) == true ]]; then
            pass "required entitlement is true: $key"
        else
            fail "required entitlement is missing or false: $key"
        fi
    done

    entitlement_xml=$(/usr/bin/plutil -convert xml1 -o - "$entitlements" 2>/dev/null || true)
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        case "$key" in
            com.apple.security.app-sandbox|com.apple.security.device.bluetooth|com.apple.application-identifier|com.apple.developer.team-identifier)
                ;;
            com.apple.security.*)
                fail "unexpected security entitlement: $key"
                ;;
            *)
                fail "unexpected entitlement: $key"
                ;;
        esac
    done < <(printf '%s\n' "$entitlement_xml" | sed -nE 's/^[[:space:]]*<key>([^<]+)<\/key>[[:space:]]*$/\1/p')

    forbidden_entitlements='com\.apple\.security\.(network\.|get-task-allow|device\.audio-input|files\.|inherit|cs\.(debugger|allow-dyld-environment-variables|allow-unsigned-executable-memory|disable-library-validation))'
    if printf '%s\n' "$entitlement_xml" | grep -Eq "<key>${forbidden_entitlements}"; then
        fail "forbidden network, debug, microphone, file-access, or inherited entitlement found"
    else
        pass "no forbidden network, debug, microphone, file-access, or inherited entitlement"
    fi
fi

bundle_id=$(plist_value "$info_plist" CFBundleIdentifier || true)
executable_name=$(plist_value "$info_plist" CFBundleExecutable || true)
if [[ -n "$bundle_id" ]]; then
    pass "bundle identifier: $bundle_id"
else
    fail "CFBundleIdentifier is missing"
fi
main_executable="$app_dir/Contents/MacOS/$executable_name"
if [[ -n "$executable_name" && -f "$main_executable" ]]; then
    pass "main executable exists: $executable_name"
else
    fail "CFBundleExecutable is missing or absent from Contents/MacOS"
fi

signature_details="$tmp_dir/signature-details.txt"
/usr/bin/codesign -d --verbose=2 "$app_dir" 2>"$signature_details" || true
if grep -q '^Signature=adhoc$' "$signature_details"; then
    echo "INFO: bundle is ad hoc signed; signature verification is not Developer ID certification or notarization"
else
    echo "INFO: signature is not reported as ad hoc; this script does not assess notarization or Gatekeeper policy"
fi

source_dir="$root_dir/Sources"
if [[ ! -d "$source_dir" ]]; then
    fail "production source directory is missing: $source_dir"
else
    source_files=0
    source_findings=0
    while IFS= read -r -d '' source_file; do
        source_files=$((source_files + 1))
        rel_file=${source_file#"$root_dir"/}
        network_pattern='URLSession|URLRequest|URLProtocol|NSURLConnection|NWConnection|NWListener|NWBrowser|NWPathMonitor|CFNetwork|CFHTTP|CFSocket|(^|[^[:alnum:]_.])socket[[:space:]]*\(|(^|[^[:alnum:]_.])connect[[:space:]]*\(|getaddrinfo|Network\.framework|WebSocket|Alamofire|Starscream|Moya|Sparkle|SUUpdater|SPUUpdater|Squirrel|auto.?updat(e|er)|update.?check'
        if grep -Ein "$network_pattern" "$source_file"; then
            printf 'FAIL: possible network or updater API in %s\n' "$rel_file" >&2
            source_findings=$((source_findings + 1))
        fi

        shell_pattern='NSTask|popen[[:space:]]*\(|(^|[^[:alnum:]_.])system[[:space:]]*\(|/bin/(ba)?sh|(^|[[:space:]])sh[[:space:]]+-c|shellPath|launchPath'
        if grep -Ein "$shell_pattern" "$source_file"; then
            printf 'FAIL: shell/process API in %s\n' "$rel_file" >&2
            source_findings=$((source_findings + 1))
        fi

        process_count=$(grep -Ec 'Process[[:space:]]*\(' "$source_file" || true)
        if [[ "$process_count" -gt 0 ]]; then
            allowed_profiler=false
            if [[ "$rel_file" == "Sources/AirPodsMonitor.swift" && "$process_count" -eq 1 ]] \
                && grep -Fq 'process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")' "$source_file" \
                && grep -Fq 'process.arguments = ["-json", "SPBluetoothDataType"]' "$source_file" \
                && [[ $(grep -Ec 'executableURL[[:space:]]*=' "$source_file" || true) -eq 1 ]]; then
                allowed_profiler=true
            fi
            if [[ "$allowed_profiler" == true ]]; then
                printf 'INFO: allowlisted fixed system_profiler Process in %s\n' "$rel_file"
            else
                grep -En 'Process[[:space:]]*\(' "$source_file" >&2 || true
                printf 'FAIL: Process API outside the fixed system_profiler allowlist in %s\n' "$rel_file" >&2
                source_findings=$((source_findings + 1))
            fi
        fi
    done < <(find "$source_dir" -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.c' -o -name '*.h' \) -print0)

    if [[ "$source_files" -eq 0 ]]; then
        fail "no production source files found under Sources"
    elif [[ "$source_findings" -eq 0 ]]; then
        pass "production source scan found no disallowed network, updater, or process APIs ($source_files files scanned)"
    else
        failures=$((failures + source_findings))
    fi
fi

if [[ -n "$main_executable" && -f "$main_executable" ]]; then
    extra_macho=0
    macho_count=0
    while IFS= read -r -d '' bundled_file; do
        if /usr/bin/file -b "$bundled_file" | grep -q 'Mach-O'; then
            macho_count=$((macho_count + 1))
            if [[ "$bundled_file" != "$main_executable" ]]; then
                printf 'FAIL: bundled helper/library executable found: %s\n' "${bundled_file#"$app_dir"/}" >&2
                extra_macho=$((extra_macho + 1))
            fi
        fi
    done < <(find "$app_dir/Contents" -type f -print0)
    if [[ "$extra_macho" -eq 0 && "$macho_count" -eq 1 ]]; then
        pass "bundle contains only its main Mach-O executable"
    else
        if [[ "$macho_count" -ne 1 ]]; then
            fail "expected one Mach-O executable in bundle; found $macho_count"
        fi
        failures=$((failures + extra_macho))
    fi

    for helper_dir in Frameworks PlugIns XPCServices Helpers LoginItems; do
        if [[ -d "$app_dir/Contents/$helper_dir" ]] && find "$app_dir/Contents/$helper_dir" -type f -print -quit | grep -q .; then
            fail "unexpected bundled helper content under Contents/$helper_dir"
        fi
    done

    if [[ -f "$main_executable" ]]; then
        dependency_findings=0
        dependency_count=0
        while IFS= read -r dependency; do
            [[ -z "$dependency" ]] && continue
            dependency_count=$((dependency_count + 1))
            case "$dependency" in
                /System/Library/*|/usr/lib/*|/System/Volumes/Preboot/Cryptexes/OS/System/Library/*|/System/Volumes/Preboot/Cryptexes/OS/usr/lib/*|/System/Cryptexes/App/usr/lib/*)
                    ;;
                *)
                    printf 'FAIL: non-system dynamic dependency: %s\n' "$dependency" >&2
                    dependency_findings=$((dependency_findings + 1))
                    ;;
            esac
        done < <(/usr/bin/otool -L "$main_executable" 2>/dev/null | sed '1d; s/^[[:space:]]*\([^[:space:]]*\).*/\1/')
        if [[ "$dependency_findings" -eq 0 && "$dependency_count" -gt 0 ]]; then
            pass "all $dependency_count dynamic dependencies resolve to Apple system library paths"
        elif [[ "$dependency_count" -eq 0 ]]; then
            fail "could not inspect dynamic dependencies (otool returned no dependency rows)"
        else
            failures=$((failures + dependency_findings))
        fi
    fi
fi

if [[ "$run_probe" == true ]]; then
    probe_source="$root_dir/Verification/NetworkSandboxProbe.swift"
    probe_app="$tmp_dir/NetworkSandboxProbe.app"
    probe_contents="$probe_app/Contents"
    probe_binary="$probe_contents/MacOS/NetworkSandboxProbe"
    if [[ -z "$entitlements" || ! -f "$probe_source" ]]; then
        fail "cannot run network sandbox probe without signed app entitlements and probe source"
    elif ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
        fail "cannot run network sandbox probe: swiftc is unavailable"
    elif mkdir -p "$probe_contents/MacOS" && swiftc -O -o "$probe_binary" "$probe_source"; then
        cat >"$probe_contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>NetworkSandboxProbe</string>
  <key>CFBundleIdentifier</key><string>org.podcharge.sandbox-verifier</string>
  <key>CFBundleName</key><string>NetworkSandboxProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
        if /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$probe_app" \
            && /usr/bin/codesign --verify --deep --strict "$probe_app"; then
            probe_log="$tmp_dir/probe-output.log"
            if "$probe_binary" >"$probe_log" 2>&1; then
                cat "$probe_log"
                pass "bundled sandbox probe received EPERM for its loopback-only TCP attempt"
            else
                probe_status=$?
                cat "$probe_log" >&2
                if [[ "$probe_status" -gt 128 ]]; then
                    probe_signal=$((probe_status - 128))
                    inconclusive "bundled probe process terminated by signal $probe_signal before reporting EPERM (exit $probe_status)"
                else
                    fail "bundled sandbox probe exited $probe_status without the expected EPERM result"
                fi
            fi
        else
            fail "could not sign or verify the bundled network sandbox probe"
        fi
    else
        fail "could not compile the bundled network sandbox probe"
    fi
fi

if [[ "$failures" -eq 0 && "$inconclusives" -eq 0 ]]; then
    echo "RESULT: PASS (0 failed checks)"
    exit 0
fi
if [[ "$failures" -eq 0 ]]; then
    echo "RESULT: INCONCLUSIVE ($inconclusives inconclusive check(s))" >&2
    exit 2
fi
echo "RESULT: FAIL ($failures failed check(s), $inconclusives inconclusive check(s))" >&2
exit 1
