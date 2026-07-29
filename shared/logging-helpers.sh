#!/usr/bin/env bash
# logging-helpers.sh — Lightweight logging for inner build scripts.
#
# Sources shared/logging.sh if PLAYOS_LOG_DIR is available.  Otherwise
# provides fallback functions that just echo.
#
# Usage in any inner script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   ROOT="${PLAYOS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
#   source "$ROOT/shared/logging-helpers.sh"

set -euo pipefail

_LOGGING_HELPERS_LOADED=true

if [ -n "${PLAYOS_LOG_DIR:-}" ] && [ -f "${PLAYOS_ROOT:-/workspace}/shared/logging.sh" ]; then
    source "${PLAYOS_ROOT:-/workspace}/shared/logging.sh"
    _script_name="$(basename "${BASH_SOURCE[1]:-unknown}" .sh)"
    resume_logging "$_script_name"
else
    # Fallback: plain echo when logging infrastructure is unavailable
    _log_step()    { echo "==> $1"; }
    _log_info()    { echo "    $1"; }
    _log_warn()    { echo "    WARNING: $1" >&2; }
    _log_error()   { echo "    ERROR: $1" >&2; }
    _log_success() { echo "    ✓  $1"; }
    _log_debug()   { [ "${PLAYOS_LOG_LEVEL:-}" = "debug" ] && echo "    ·  $1"; }
    _log_cmd()     { [ "${PLAYOS_LOG_LEVEL:-}" = "debug" ] && echo "    \$ $1"; }

    # Underscore-free aliases for shared library compatibility.
    log_step()    { _log_step "$@"; }
    log_info()    { _log_info "$@"; }
    log_warn()    { _log_warn "$@"; }
    log_error()   { _log_error "$@"; }
    log_success() { _log_success "$@"; }
    log_debug()   { _log_debug "$@"; }
    log_cmd()     { _log_cmd "$@"; }
fi
