#!/usr/bin/env bash
# configure.sh VNC_USER_PASSWORD VNC_PASSWORD NGROK_AUTH_TOKEN [NGROK_REGION]
#
# Kept for compatibility with the original one-shot setup. The work now lives in
# scripts/setup-vnc.sh and scripts/ngrok.sh, which the workflow calls directly.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/scripts/setup-vnc.sh" "$1" "${2:-}" || exit 1
bash "$HERE/scripts/ngrok.sh" "${3:?NGROK_AUTH_TOKEN is required}" "${4:-us}" 5900
