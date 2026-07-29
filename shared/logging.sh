#!/usr/bin/env bash
# logging.sh — Unified logging for PlayOS build scripts.
#
# Usage:
#   source "$ROOT/shared/logging.sh"
#   init_logging "build-iso-ubuntu"    # optional: script_name
#
# Log levels (via PLAYOS_LOG_LEVEL env, default: info):
#   debug — Everything (verbose command output)
#   info  — Steps + info + success + warn + error (default)
#   warn  — Steps + warn + error only
#   error — Errors only
#
# Functions:
#   log_step "msg"    — Major phase marker → summary.log + script log
#   log_info "msg"    — Informational → script log only
#   log_warn "msg"    — Warning → script log + summary.log
#   log_error "msg"   — Error → script log + summary.log + stderr
#   log_success "msg" — Success marker → script log + summary.log
#   log_debug "msg"   — Debug detail → script log only (when level=debug)
#   log_cmd "cmd"     — Log a command being invoked
#   log_duration      — Print elapsed time since init_logging
#   close_logging exit_code summary_msg  — Finalize run, write metadata.json
#
# Output:
#   logs/YYYY-MM-DD_HH-MM-SS--<distro>-<version>--<arch>/
#     summary.log           High-level phase markers with timestamps
#     <script_name>.log     Per-script detailed log
#     full.log              Combined stdout+stderr (when redirect enabled)
#     metadata.json         Run metadata
#   logs/latest → most recent run dir

set -euo pipefail

# ── Globals ──────────────────────────────────────────────────────────────────
PLAYOS_LOG_LEVEL="${PLAYOS_LOG_LEVEL:-info}"
PLAYOS_LOG_RUN_ID="${PLAYOS_LOG_RUN_ID:-}"
PLAYOS_LOG_DIR="${PLAYOS_LOG_DIR:-}"
PLAYOS_LOG_SCRIPT_NAME="${PLAYOS_LOG_SCRIPT_NAME:-}"
PLAYOS_LOG_START_TIME="${PLAYOS_LOG_START_TIME:-}"
PLAYOS_LOG_CURRENT_PHASE=""
PLAYOS_LOG_PHASES=()

# ── Internal helpers ─────────────────────────────────────────────────────────

_log_should_show() {
    local level="$1"
    case "$PLAYOS_LOG_LEVEL" in
        debug) return 0 ;;
        info)  [[ "$level" != "debug" ]] ;;
        warn)  [[ "$level" == "warn" || "$level" == "error" ]] ;;
        error) [[ "$level" == "error" ]] ;;
        *)     [[ "$level" != "debug" ]] ;;
    esac
}

_log_ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_log_write() {
    local logfile="$1" level="$2" prefix="$3" msg="$4"
    local ts
    ts="$(_log_ts)"
    echo "[$ts] $prefix $msg" >> "$logfile"
}

_log_to_both() {
    local level="$1" prefix="$2" msg="$3"
    if [ -n "${PLAYOS_LOG_DIR:-}" ] && [ -d "$PLAYOS_LOG_DIR" ]; then
        _log_write "$PLAYOS_LOG_DIR/summary.log" "$level" "$prefix" "$msg"
        _log_write "$PLAYOS_LOG_DIR/${PLAYOS_LOG_SCRIPT_NAME}.log" "$level" "$prefix" "$msg"
    fi
}

_log_to_script() {
    local level="$1" prefix="$2" msg="$3"
    if [ -n "${PLAYOS_LOG_DIR:-}" ] && [ -d "$PLAYOS_LOG_DIR" ]; then
        _log_write "$PLAYOS_LOG_DIR/${PLAYOS_LOG_SCRIPT_NAME}.log" "$level" "$prefix" "$msg"
    fi
}

# ── Public API ───────────────────────────────────────────────────────────────

# init_logging [script_name] [--redirect-full-log]
# Must be called once at script start. Creates the run directory and sets up
# globals. If PLAYOS_LOG_DIR is already set (passed from parent), reuses it.
init_logging() {
    PLAYOS_LOG_SCRIPT_NAME="${1:-$(basename "${BASH_SOURCE[1]:-unknown}" .sh)}"
    PLAYOS_LOG_START_TIME="$(_log_ts)"

    if [ -z "${PLAYOS_LOG_DIR:-}" ]; then
        # Generate run directory name
        local distro="${PLAYOS_DISTRO:-alpine}"
        local version="${PLAYOS_ALPINE_BRANCH:-${PLAYOS_KERNEL_VARIANT:-unknown}}"
        local arch="${PLAYOS_ARCH:-x86_64}"
        local ts
        ts="$(date -u '+%Y-%m-%d_%H-%M-%S')"
        PLAYOS_LOG_RUN_ID="${ts}--${distro}-${version}--${arch}"

        # Determine repo root
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        local repo_root
        repo_root="$(cd "$script_dir/.." && pwd)"

        PLAYOS_LOG_DIR="$repo_root/logs/$PLAYOS_LOG_RUN_ID"
        mkdir -p "$PLAYOS_LOG_DIR"

        # Create latest symlink
        ln -sfn "$PLAYOS_LOG_RUN_ID" "$repo_root/logs/latest"

        # Create metadata skeleton
        cat > "$PLAYOS_LOG_DIR/metadata.json" <<META
{
  "run_id": "$PLAYOS_LOG_RUN_ID",
  "started_at": "$PLAYOS_LOG_START_TIME",
  "distro": "$distro",
  "version": "$version",
  "arch": "$arch",
  "host": "$(hostname 2>/dev/null || echo unknown)",
  "script": "$PLAYOS_LOG_SCRIPT_NAME",
  "phases": []
}
META

        # Print a console banner so the user sees where logs are going
        echo
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║  PlayOS Build Log                                               ║"
        echo "║  Run:  $PLAYOS_LOG_RUN_ID"
        echo "║  Logs: logs/${PLAYOS_LOG_RUN_ID}/"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        echo
    else
        PLAYOS_LOG_RUN_ID="$(basename "$PLAYOS_LOG_DIR")"
    fi

    export PLAYOS_LOG_DIR PLAYOS_LOG_RUN_ID PLAYOS_LOG_LEVEL PLAYOS_LOG_START_TIME

    log_info "Logging initialized — run: $PLAYOS_LOG_RUN_ID"
    log_info "Script: $PLAYOS_LOG_SCRIPT_NAME, level: $PLAYOS_LOG_LEVEL"
}

# Major phase marker — also written to summary.log
log_step() {
    local msg="$1"
    PLAYOS_LOG_CURRENT_PHASE="$msg"
    PLAYOS_LOG_PHASES+=("$msg:$(_log_ts)")
    if _log_should_show info; then
        echo "==> $msg"
        _log_to_both "STEP" "  " "$msg"
    fi
}

# Underscore-prefixed aliases — shared library compatibility.
# Shared libraries (verify-sibling-repos, fstab-generate, etc.) use _log_*
# while the orchestrator sources logging.sh directly. These aliases ensure
# both naming conventions work regardless of which logger is loaded.
_log_step()   { log_step "$@"; }
_log_info()   { log_info "$@"; }
_log_warn()   { log_warn "$@"; }
_log_error()  { log_error "$@"; }
_log_success(){ log_success "$@"; }
_log_debug()  { log_debug "$@"; }
_log_cmd()    { log_cmd "$@"; }

log_info() {
    if _log_should_show info; then
        echo "    $1"
        _log_to_script "INFO" "   " "$1"
    fi
}

log_warn() {
    if _log_should_show warn; then
        echo "    ⚠  $1" >&2
        _log_to_both "WARN" "   " "$1"
    fi
}

log_error() {
    if _log_should_show error; then
        echo "    ✗  $1" >&2
        _log_to_both "ERROR" "  " "$1"
    fi
}

log_success() {
    if _log_should_show info; then
        echo "    ✓  $1"
        _log_to_both "OK" "    " "$1"
    fi
}

log_debug() {
    if _log_should_show debug; then
        echo "    ·  $1"
        _log_to_script "DEBUG" "  " "$1"
    fi
}

# Log a command that's about to be run
log_cmd() {
    if _log_should_show debug; then
        echo "    \$ $1"
    fi
    _log_to_script "CMD" "   " "$1"
}

# Print elapsed time since init_logging
log_duration() {
    local now
    now="$(date -u +%s)"
    local start
    start="$(date -u -d "$PLAYOS_LOG_START_TIME" +%s 2>/dev/null || echo "$now")"
    local elapsed=$((now - start))
    if _log_should_show info; then
        echo "    ⏱  Elapsed: ${elapsed}s"
    fi
    _log_to_script "TIME" "  " "Elapsed: ${elapsed}s"
}

# Finalize logging: write metadata.json with outcome and duration.
# Call before exit.  Pass exit code and optional summary.
close_logging() {
    local exit_code="${1:-0}"
    local summary_msg="${2:-}"

    local ended_at
    ended_at="$(_log_ts)"
    local started_epoch
    started_epoch="$(date -u -d "$PLAYOS_LOG_START_TIME" +%s 2>/dev/null || echo 0)"
    local ended_epoch
    ended_epoch="$(date -u +%s)"
    local duration_secs=$((ended_epoch - started_epoch))

    local outcome="success"
    [ "$exit_code" -ne 0 ] && outcome="failure"

    if [ -n "${PLAYOS_LOG_DIR:-}" ] && [ -d "$PLAYOS_LOG_DIR" ]; then
        # Build phases JSON array
        local phases_json="["
        local first=true
        for phase in "${PLAYOS_LOG_PHASES[@]}"; do
            local phase_name="${phase%%:*}"
            local phase_ts="${phase#*:}"
            if $first; then first=false; else phases_json+=","; fi
            phases_json+="{\"name\":\"$phase_name\",\"timestamp\":\"$phase_ts\"}"
        done
        phases_json+="]"

        cat > "$PLAYOS_LOG_DIR/metadata.json" <<META
{
  "run_id": "$PLAYOS_LOG_RUN_ID",
  "started_at": "$PLAYOS_LOG_START_TIME",
  "ended_at": "$ended_at",
  "duration_seconds": $duration_secs,
  "distro": "${PLAYOS_DISTRO:-alpine}",
  "version": "${PLAYOS_ALPINE_BRANCH:-${PLAYOS_KERNEL_VARIANT:-unknown}}",
  "arch": "${PLAYOS_ARCH:-x86_64}",
  "host": "$(hostname 2>/dev/null || echo unknown)",
  "script": "$PLAYOS_LOG_SCRIPT_NAME",
  "outcome": "$outcome",
  "exit_code": $exit_code,
  "summary": "$summary_msg",
  "phases": $phases_json
}
META

        _log_to_both "FINAL" " " "Run $PLAYOS_LOG_RUN_ID ended: $outcome (${duration_secs}s, exit=$exit_code)"
    fi

    # Console footer
    echo
    echo "╔══════════════════════════════════════════════════════════════════╗"
    if [ "$exit_code" -eq 0 ]; then
        echo "║  ✅ Build ${outcome} — ${duration_secs}s                            ║"
    else
        echo "║  ❌ Build ${outcome} — ${duration_secs}s (exit=$exit_code)          ║"
    fi
    echo "║  Logs: logs/${PLAYOS_LOG_RUN_ID}/"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo
}

# Shortcut: start logging for sourced scripts (called when PLAYOS_LOG_DIR is inherited)
# Only re-runs echo-to-console; the log dir is already set up.
resume_logging() {
    local script_name="${1:-$(basename "${BASH_SOURCE[1]:-unknown}" .sh)}"
    PLAYOS_LOG_SCRIPT_NAME="$script_name"
    if [ -z "${PLAYOS_LOG_START_TIME:-}" ]; then
        PLAYOS_LOG_START_TIME="$(_log_ts)"
    fi
    export PLAYOS_LOG_SCRIPT_NAME PLAYOS_LOG_START_TIME
    log_info "Script $script_name resumed — logging to ${PLAYOS_LOG_DIR:-unknown}"
}
