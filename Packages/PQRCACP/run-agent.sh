#!/usr/bin/env bash
# run-agent.sh — one-command launcher for the EldrChat ACP agent REPL.
#
# Builds (release) and runs `eldr-acp-run`, a terminal ACP client that spawns the
# real `eldr-acp` agent and lets you drive it by hand against your local model.
# Defaults target LM Studio's local OpenAI server; override via the ELDR_LLM_* env.
#
# Usage:
#   ./run-agent.sh [--dir <path>] [--yes]
#   ELDR_LLM_MODEL=qwen2.5-coder ./run-agent.sh --dir ~/code/MyApp
#   ELDR_ACP_FAKE_LLM=1 ./run-agent.sh --yes      # no model server needed (echo LLM)
set -euo pipefail

cd "$(dirname "$0")"

# LM Studio defaults (override by exporting these before running).
export ELDR_LLM_URL="${ELDR_LLM_URL:-http://127.0.0.1:1234/v1}"
export ELDR_LLM_MODEL="${ELDR_LLM_MODEL:-local-model}"
export ELDR_LLM_TOKEN="${ELDR_LLM_TOKEN:-}"
export ELDR_LLM_TIMEOUT_SECONDS="${ELDR_LLM_TIMEOUT_SECONDS:-120}"

echo "Building eldr-acp + eldr-acp-run (release)…"
swift build -c release --product eldr-acp >/dev/null
swift build -c release --product eldr-acp-run >/dev/null

BIN_DIR="$(swift build -c release --show-bin-path)"
# Point the runner at the freshly-built agent binary in the same bin dir.
export ELDR_ACP_BIN="${ELDR_ACP_BIN:-$BIN_DIR/eldr-acp}"

exec "$BIN_DIR/eldr-acp-run" "$@"
