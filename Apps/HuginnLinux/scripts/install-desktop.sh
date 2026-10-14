#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Put Huginn in the desktop's app menu: ~/.local/bin/huginn → scripts/huginn, plus a .desktop entry.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
ln -sf "$here/huginn" "$HOME/.local/bin/huginn"
sed "s|@HUGINN@|$HOME/.local/bin/huginn|" "$here/huginn.desktop.in" > "$HOME/.local/share/applications/huginn.desktop"
echo "Installed: $HOME/.local/bin/huginn and $HOME/.local/share/applications/huginn.desktop"
