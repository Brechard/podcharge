#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/install.sh [--destination DIR] [--no-open] [--help]

Build, verify, and install PodCharge.app in DIR (default: /Applications).
Use --destination "$HOME/Applications" if /Applications is not writable.
EOF
}

destination=/Applications
open_app=true
while (($#)); do
    case $1 in
        --destination)
            if (($# < 2)) || [[ -z $2 ]]; then
                echo "ERROR: --destination requires a directory" >&2
                exit 2
            fi
            destination=$2
            shift 2
            ;;
        --no-open) open_app=false; shift ;;
        --help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$project_dir"
if [[ ! -d $destination || ! -w $destination ]]; then
    echo "ERROR: destination is missing or not writable: $destination" >&2
    echo 'Try --destination "$HOME/Applications" (create that directory first).' >&2
    exit 1
fi
destination=$(CDPATH= cd -- "$destination" && pwd -P)
target="$destination/PodCharge.app"
built="$project_dir/build/PodCharge.app"

check_target() {
    if [[ -L $target ]]; then
        echo "ERROR: refusing to replace symlink: $target" >&2
        return 1
    fi
    if [[ -e $target ]]; then
        if [[ ! -d $target ]] ||
            [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true) != org.podcharge.local ]]; then
            echo "ERROR: refusing to replace an unexpected app at $target" >&2
            return 1
        fi
    fi
}

check_running() {
    local pid executable
    executable="$target/Contents/MacOS/PodCharge"
    while IFS= read -r pid; do
        [[ -n $pid ]] || continue
        if /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/grep -Fqx "n$executable"; then
            echo "ERROR: PodCharge is running from $target. Quit it, then retry the install." >&2
            return 1
        fi
    done < <(/usr/bin/pgrep -x PodCharge || true)
}

check_target
./scripts/build.sh
./scripts/verify-security.sh "$built"

stage=$(mktemp -d "$destination/.podcharge-install.XXXXXXXX") || {
    echo "ERROR: could not create a staging directory in $destination" >&2
    exit 1
}
new_installed=false
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ ( -e $stage/previous.app || -L $stage/previous.app ) && $new_installed == false ]]; then
        if [[ ! -e $target && ! -L $target ]] && mv "$stage/previous.app" "$target"; then
            echo "Restored previous app at $target" >&2
        else
            echo "ERROR: rollback could not restore $target; previous app is at $stage/previous.app" >&2
            exit 1
        fi
    fi
    rm -rf -- "$stage"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ditto "$built" "$stage/PodCharge.app"
./scripts/verify-security.sh "$stage/PodCharge.app"
check_target
check_running

if [[ -e $target ]]; then
    mv "$target" "$stage/previous.app"
fi
mv -n "$stage/PodCharge.app" "$destination/"
if [[ -e $stage/PodCharge.app ]]; then
    echo "ERROR: install could not replace $target" >&2
    exit 1
fi
new_installed=true
echo "Installed $target"
if [[ $open_app == true ]]; then
    open "$target"
fi
