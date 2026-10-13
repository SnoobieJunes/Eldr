#!/usr/bin/env bash
# Linux gate (DEVIATIONS AC172): every package's tests + every Linux executable must be
# green before a push. Usage: scripts/linux-ci.sh   (exit code != 0 ⇒ do not push)
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
for p in PQRCCore PQRCNostr PQRCAgent PQRCACP PQRCMCP EldrNode Eldrctl SwiftA2A EldrKeystore EldrLinux; do
  if out=$(swift test --package-path "Packages/$p" 2>&1); then
    echo "PASS $p: $(grep -E 'Test run with|Executed [0-9]+ tests' <<<"$out" | grep -v 'Executed 0 tests' | tail -2 | tr '\n' ' ')"
  else
    echo "FAIL $p"; grep -E '✘|error:' <<<"$out" | head -20; fail=1
  fi
done
for prod in "EldrLinux eldr-chat" "EldrLinux eldr-gtk" "EldrNode eldr-node" "PQRCACP eldr-acp" "Eldrctl eldrctl" "PQRCNostr pqrc-relay"; do
  set -- $prod
  if swift build --package-path "Packages/$1" --product "$2" >/dev/null 2>&1; then echo "BUILD OK $2"; else echo "BUILD FAIL $2"; fail=1; fi
done
exit $fail
