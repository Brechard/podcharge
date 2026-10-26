#!/bin/bash
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/podcharge-install-test.XXXXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
destination="$test_root/Apps with spaces"
fixture="$test_root/fixture"
mkdir -p "$destination" "$fixture/scripts" "$fixture/build"
destination=$(CDPATH= cd -- "$destination" && pwd -P)

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_clean() {
    if find "$destination" -maxdepth 1 -name '.podcharge-install.*' -print | /usr/bin/grep -q .; then
        fail 'installer left a staging directory'
    fi
}
assert_old() {
    [[ -f $destination/PodCharge.app/old-marker ]] || fail 'previous app was not preserved'
    assert_clean
}

# This first run builds and security-checks the actual app before installing it.
"$project_dir/scripts/install.sh" --destination "$destination" --no-open
[[ -f $destination/PodCharge.app/Contents/MacOS/PodCharge ]] || fail 'real app was not installed'
assert_clean

# Subsequent runs isolate replacement behavior without repeatedly compiling Swift.
cp "$project_dir/scripts/install.sh" "$fixture/scripts/install.sh"
/usr/bin/ditto "$project_dir/build/PodCharge.app" "$fixture/build/PodCharge.app"
cat > "$fixture/scripts/build.sh" <<'EOF'
#!/bin/bash
set -e
test -d build/PodCharge.app
EOF
cat > "$fixture/scripts/verify-security.sh" <<'EOF'
#!/bin/bash
set -e
test -d "$1"
if [[ ${FAIL_VERIFY:-0} == 1 ]]; then
    echo 'fixture verification failed' >&2
    exit 1
fi
EOF
chmod +x "$fixture/scripts/"*.sh

touch "$destination/PodCharge.app/stale-marker"
"$fixture/scripts/install.sh" --destination "$destination" --no-open
[[ ! -e $destination/PodCharge.app/stale-marker ]] || fail 'reinstall left a stale file'
assert_clean

touch "$destination/PodCharge.app/old-marker"
if FAIL_VERIFY=1 "$fixture/scripts/install.sh" --destination "$destination" --no-open; then
    fail 'installer succeeded after verification failed'
fi
assert_old

# Inject faults at the rename boundary while leaving the real installer code intact.
mkdir "$test_root/bin"
cat > "$test_root/bin/mv" <<'EOF'
#!/bin/bash
if [[ $1 == -n && $2 == */.podcharge-install.*/PodCharge.app && ${INJECT_MODE:-} == fail_new ]]; then
    echo 'fixture install rename failed' >&2
    exit 1
fi
if [[ $1 == "$INJECT_DEST/PodCharge.app" && $2 == */.podcharge-install.*/previous.app ]]; then
    /bin/mv "$@" || exit
    case ${INJECT_MODE:-} in
        term) kill -TERM "$PPID" ;;
        collision) mkdir "$INJECT_DEST/PodCharge.app"; touch "$INJECT_DEST/PodCharge.app/collision-marker" ;;
    esac
    exit 0
fi
exec /bin/mv "$@"
EOF
chmod +x "$test_root/bin/mv"
if INJECT_MODE=fail_new INJECT_DEST="$destination" PATH="$test_root/bin:$PATH" \
    "$fixture/scripts/install.sh" --destination "$destination" --no-open; then
    fail 'installer succeeded after install rename failed'
fi
assert_old

# The old rename succeeds, then its child signals only this installer process.
set +e
INJECT_MODE=term INJECT_DEST="$destination" PATH="$test_root/bin:$PATH" \
    "$fixture/scripts/install.sh" --destination "$destination" --no-open
term_status=$?
set -e
[[ $term_status -eq 143 ]] || fail "TERM installer exited $term_status instead of 143"
assert_old
echo "PASS: interrupted replacement exited $term_status and restored the old app"

# A directory appears after the old rename. macOS mv -n must not nest the new app.
collision_log="$test_root/collision.log"
set +e
INJECT_MODE=collision INJECT_DEST="$destination" PATH="$test_root/bin:$PATH" \
    "$fixture/scripts/install.sh" --destination "$destination" --no-open >"$collision_log" 2>&1
collision_status=$?
set -e
[[ $collision_status -eq 1 ]] || fail "collision installer exited $collision_status instead of 1"
[[ -f $destination/PodCharge.app/collision-marker ]] || fail 'collision target was modified'
[[ ! -e $destination/PodCharge.app/PodCharge.app ]] || fail 'new app nested in collision directory'
stage=$(find "$destination" -maxdepth 1 -type d -name '.podcharge-install.*' -print)
[[ -n $stage && -f $stage/previous.app/old-marker ]] || fail 'previous app backup was not preserved'
/usr/bin/grep -Fq "previous app is at $stage/previous.app" "$collision_log" || fail 'recovery path was not printed'
echo "PASS: destination collision exited $collision_status without nesting or deleting the backup"
rm -rf -- "$destination/PodCharge.app"
/bin/mv "$stage/previous.app" "$destination/PodCharge.app"
rm -rf -- "$stage"
assert_old

/bin/mv "$destination/PodCharge.app" "$test_root/old-app"
ln -s "$test_root/old-app" "$destination/PodCharge.app"
if "$fixture/scripts/install.sh" --destination "$destination" --no-open; then
    fail 'installer accepted a symlink target'
fi
[[ -L $destination/PodCharge.app ]] || fail 'symlink target was modified'
assert_clean
rm "$destination/PodCharge.app"
mkdir "$destination/PodCharge.app"
cat > "$destination/PodCharge.app/Contents.plist" <<'EOF'
unexpected app
EOF
if "$fixture/scripts/install.sh" --destination "$destination" --no-open; then
    fail 'installer accepted an unexpected target'
fi
[[ -f $destination/PodCharge.app/Contents.plist ]] || fail 'unexpected target was modified'
assert_clean

echo 'PASS: real install, clean reinstall, failure preservation, TERM rollback, collision recovery, and target rejection'
