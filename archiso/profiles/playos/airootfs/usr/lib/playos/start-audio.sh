#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR=/run/playos

pipewire &
pipewire-pulse &
exec wireplumber
