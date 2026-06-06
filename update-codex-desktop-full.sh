#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

info() {
    printf '[codex-update] %s\n' "$*"
}

die() {
    printf '[codex-update][ERROR] %s\n' "$*" >&2
    exit 1
}

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<'USAGE'
Usage: ./update-codex-desktop-full.sh [options]

Updates, rebuilds, packages, and installs Codex Desktop Linux with the full
reviewed Linux feature set enabled.

Options:
  --remote NAME        Git remote to fast-forward from (default: origin)
  --branch NAME        Git branch to fast-forward from (default: main)
  --no-git             Skip git fetch/merge
  --allow-dirty        Allow tracked local modifications during git update
  --cached-dmg         Reuse cached Codex.dmg instead of downloading a fresh one
  --no-tests           Skip feature/static tests before building
  --no-install         Build package but do not install it
  -y, --yes            Do not prompt before stopping a running app
  -h, --help           Show this help

Environment:
  UPDATE_REMOTE=origin         Same as --remote origin
  UPDATE_BRANCH=main           Same as --branch main
  MAX_BUILD_THREADS=4          Build jobs/compression thread hint
  PACKAGE_WITH_UPDATER=0       Set 1 to include codex-update-manager
  CODEX_LINUX_FEATURES_CONFIG  Use an explicit feature config instead of the built-in full set
USAGE
}

UPDATE_REMOTE="${UPDATE_REMOTE:-}"
UPDATE_BRANCH="${UPDATE_BRANCH:-main}"
SKIP_GIT_UPDATE=0
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
FRESH_DMG=1
RUN_TESTS=1
INSTALL_PACKAGE=1
ASSUME_YES="${ASSUME_YES:-0}"
MAX_BUILD_THREADS="${MAX_BUILD_THREADS:-4}"
PACKAGE_WITH_UPDATER="${PACKAGE_WITH_UPDATER:-0}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --remote)
            [ "$#" -ge 2 ] || die "--remote requires a value"
            UPDATE_REMOTE="$2"
            shift 2
            ;;
        --branch)
            [ "$#" -ge 2 ] || die "--branch requires a value"
            UPDATE_BRANCH="$2"
            shift 2
            ;;
        --no-git)
            SKIP_GIT_UPDATE=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --cached-dmg)
            FRESH_DMG=0
            shift
            ;;
        --no-tests)
            RUN_TESTS=0
            shift
            ;;
        --no-install)
            INSTALL_PACKAGE=0
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[ -n "$UPDATE_REMOTE" ] || UPDATE_REMOTE="origin"

for command_name in git make; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done

if [ ! -f install.sh ] || [ ! -f Makefile ] || [ ! -d linux-features ]; then
    die "Run this script from the codex-desktop-linux checkout"
fi

FEATURE_CONFIG_CREATED=0
if [ -n "${CODEX_LINUX_FEATURES_CONFIG:-}" ]; then
    FEATURE_CONFIG="$CODEX_LINUX_FEATURES_CONFIG"
    [ -f "$FEATURE_CONFIG" ] || die "CODEX_LINUX_FEATURES_CONFIG does not exist: $FEATURE_CONFIG"
else
    FEATURE_CONFIG="$(mktemp "${TMPDIR:-/tmp}/codex-linux-features-full.XXXXXX.json")"
    FEATURE_CONFIG_CREATED=1
    cat >"$FEATURE_CONFIG" <<'JSON'
{
  "enabled": [
    "agent-workspace",
    "appshots",
    "codex-wrapper-updater",
    "conversation-mode",
    "copilot-reasoning-effort",
    "open-target-discovery",
    "read-aloud",
    "read-aloud-mcp",
    "remote-control-ui",
    "remote-mobile-control",
    "thorium-chrome-plugin",
    "x11-ewmh-computer-use",
    "zed-opener"
  ]
}
JSON
fi

cleanup() {
    if [ "$FEATURE_CONFIG_CREATED" -eq 1 ]; then
        rm -f "$FEATURE_CONFIG"
    fi
}
trap cleanup EXIT

export MAX_BUILD_THREADS PACKAGE_WITH_UPDATER

stop_running_app() {
    local pid_file pid name

    for pid_file in \
        "${XDG_STATE_HOME:-$HOME/.local/state}/codex-desktop/app.pid" \
        "${XDG_STATE_HOME:-$HOME/.local/state}/codex-desktop/webview.pid"
    do
        [ -f "$pid_file" ] || continue
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        case "$pid" in
            ''|*[!0-9]*) continue ;;
        esac
        kill -0 "$pid" 2>/dev/null || continue
        name="$(basename "$pid_file" .pid)"
        if ! truthy "$ASSUME_YES"; then
            printf '[codex-update] %s is running as pid %s. Stop it now? [y/N] ' "$name" "$pid"
            IFS= read -r answer
            case "$answer" in
                y|Y|yes|YES) ;;
                *) die "Close Codex Desktop and rerun the updater" ;;
            esac
        fi
        info "Stopping $name pid $pid"
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            info "$name pid $pid did not exit after TERM; sending KILL"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

run_git_update() {
    if truthy "$SKIP_GIT_UPDATE"; then
        info "Skipping git update"
        return
    fi

    git remote get-url "$UPDATE_REMOTE" >/dev/null 2>&1 ||
        die "Git remote not found: $UPDATE_REMOTE"

    if ! truthy "$ALLOW_DIRTY"; then
        git diff --quiet || die "Tracked worktree changes present; commit/stash them or pass --allow-dirty"
        git diff --cached --quiet || die "Staged changes present; commit/stash them or pass --allow-dirty"
    fi

    info "Fetching $UPDATE_REMOTE/$UPDATE_BRANCH"
    git fetch --prune "$UPDATE_REMOTE" "$UPDATE_BRANCH"

    info "Fast-forwarding current branch from $UPDATE_REMOTE/$UPDATE_BRANCH"
    git merge --ff-only FETCH_HEAD

    export CODEX_LINUX_SOURCE_REMOTE
    export CODEX_LINUX_SOURCE_BRANCH="$UPDATE_BRANCH"
    CODEX_LINUX_SOURCE_REMOTE="$(git remote get-url "$UPDATE_REMOTE")"
}

run_checks() {
    if ! truthy "$RUN_TESTS"; then
        info "Skipping tests"
        return
    fi

    command -v node >/dev/null 2>&1 || die "node is required for feature tests"

    info "Checking Linux feature JavaScript syntax"
    find linux-features -type f -name '*.js' -print0 | xargs -0 -n1 node --check

    info "Checking Linux feature shell syntax"
    find linux-features -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
    bash -n linux-features/appshots/bin/bare-modifier-monitor linux-features/read-aloud/bin/kokoro-stdin

    if command -v python >/dev/null 2>&1; then
        info "Checking read-aloud Python runner"
        python -m py_compile linux-features/read-aloud/bin/kokoro_stdin.py
    fi

    info "Running Linux feature tests"
    env -u CODEX_LINUX_FEATURES_CONFIG node --test linux-features/*/test.js
}

build_and_install() {
    local build_target

    stop_running_app

    if truthy "$FRESH_DMG"; then
        build_target="build-app-fresh"
    else
        build_target="build-app"
    fi

    info "Cleaning old package artifacts"
    CODEX_LINUX_FEATURES_CONFIG="$FEATURE_CONFIG" make clean-dist

    info "Building app with features from $FEATURE_CONFIG"
    CODEX_LINUX_FEATURES_CONFIG="$FEATURE_CONFIG" make "$build_target"

    info "Building native package"
    CODEX_LINUX_FEATURES_CONFIG="$FEATURE_CONFIG" make package

    if truthy "$INSTALL_PACKAGE"; then
        info "Installing native package"
        CODEX_LINUX_FEATURES_CONFIG="$FEATURE_CONFIG" make install
        if command -v kbuildsycoca6 >/dev/null 2>&1; then
            kbuildsycoca6 >/dev/null 2>&1 || true
        fi
    else
        info "Skipping package install"
    fi
}

info "Repo: $ROOT_DIR"
info "Feature config: $FEATURE_CONFIG"
info "Build threads: $MAX_BUILD_THREADS"
info "Package updater included: $PACKAGE_WITH_UPDATER"

run_git_update
run_checks
build_and_install

info "Done"
