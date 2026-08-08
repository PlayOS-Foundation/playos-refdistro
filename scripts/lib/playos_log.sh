#!/usr/bin/env bash
# playos_log.sh — Shared bash logging framework for all PlayOS scripts
#
# Usage:
#   . "$(dirname "$0")/../lib/playos_log.sh"
#
# Functions:
#   playos_log_debug TAG MSG   — grey,   [DEBUG]
#   playos_log_info  TAG MSG   — white,  [INFO]
#   playos_log_ok    TAG MSG   — green,  [OK]
#   playos_log_warn  TAG MSG   — yellow, [WARN]
#   playos_log_error TAG MSG   — red,    [ERROR]
#   playos_log_fatal TAG MSG   — red bold, [FATAL] → exit 1
#   playos_log_step  MSG       — section banner
#
# Environment:
#   PLAYOS_LOG_LEVEL  — minimum visible level (default: INFO)
#                       Values: DEBUG=0, INFO=1, OK=2, WARN=3, ERROR=4, FATAL=5

set -euo pipefail

# ── Level constants ────────────────────────────────────────────────
declare -r PLAYOS_LOG_LEVEL_DEBUG=0
declare -r PLAYOS_LOG_LEVEL_INFO=1
declare -r PLAYOS_LOG_LEVEL_OK=2
declare -r PLAYOS_LOG_LEVEL_WARN=3
declare -r PLAYOS_LOG_LEVEL_ERROR=4
declare -r PLAYOS_LOG_LEVEL_FATAL=5

# ── Default level ──────────────────────────────────────────────────
: "${PLAYOS_LOG_LEVEL:=INFO}"

playos_log_level_num() {
    case "${1:-INFO}" in
        DEBUG) echo "$PLAYOS_LOG_LEVEL_DEBUG" ;;
        INFO)  echo "$PLAYOS_LOG_LEVEL_INFO"  ;;
        OK)    echo "$PLAYOS_LOG_LEVEL_OK"    ;;
        WARN)  echo "$PLAYOS_LOG_LEVEL_WARN"  ;;
        ERROR) echo "$PLAYOS_LOG_LEVEL_ERROR" ;;
        FATAL) echo "$PLAYOS_LOG_LEVEL_FATAL" ;;
        *)     echo "$PLAYOS_LOG_LEVEL_INFO"  ;;
    esac
}

# ── Colour helpers ─────────────────────────────────────────────────
_playos_use_colour() {
    [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]
}

_playos_colour_reset()  { _playos_use_colour && echo -ne '\033[0m' || true; }
_playos_colour_grey()   { _playos_use_colour && echo -ne '\033[90m' || true; }
_playos_colour_white()  { _playos_use_colour && echo -ne '\033[97m' || true; }
_playos_colour_green()  { _playos_use_colour && echo -ne '\033[32m' || true; }
_playos_colour_yellow() { _playos_use_colour && echo -ne '\033[33m' || true; }
_playos_colour_red()    { _playos_use_colour && echo -ne '\033[31m' || true; }
_playos_colour_boldred(){ _playos_use_colour && echo -ne '\033[1;31m' || true; }

# ── Core log function ──────────────────────────────────────────────
_playos_log() {
    local level="$1"
    local tag="$2"
    local msg="$3"
    local colour_fn="$4"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    local current
    current="$(playos_log_level_num "$PLAYOS_LOG_LEVEL")"
    local this_level
    this_level="$(playos_log_level_num "$level")"

    if [[ "$this_level" -ge "$current" ]]; then
        printf "%s" "$(_playos_colour_reset)"
        printf "[%s] " "$timestamp"
        "$colour_fn"
        printf "[%-5s] " "$level"
        printf "[%s] " "$tag"
        printf "%s" "$msg"
        printf "%s\n" "$(_playos_colour_reset)"
    fi
}

# ── Public API ──────────────────────────────────────────────────────
playos_log_debug() { _playos_log "DEBUG" "$1" "$2" _playos_colour_grey; }
playos_log_info()  { _playos_log "INFO"  "$1" "$2" _playos_colour_white; }
playos_log_ok()    { _playos_log "OK"    "$1" "$2" _playos_colour_green; }
playos_log_warn()  { _playos_log "WARN"  "$1" "$2" _playos_colour_yellow; }
playos_log_error() { _playos_log "ERROR" "$1" "$2" _playos_colour_red; }

playos_log_fatal() {
    _playos_log "FATAL" "$1" "$2" _playos_colour_boldred
    exit 1
}

playos_log_step() {
    local msg="$1"
    local line
    line="$(printf '%0.s─' $(seq 1 60))"
    printf "%s\n" "$(_playos_colour_reset)"
    printf "%s\n" "$line"
    printf " ▶  %s\n" "$msg"
    printf "%s\n" "$line"
    printf "%s" "$(_playos_colour_reset)"
}
