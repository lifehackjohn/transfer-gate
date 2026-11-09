#!/bin/bash
# Transfer Gate v2 — Mac Launcher
# Double-click this file in Finder to start the online server and open the UI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$SCRIPT_DIR/transfer-gate-server.py"
PORT="${TG_PORT:-8080}"
URL="http://127.0.0.1:$PORT"

if [ ! -f "$SERVER" ]; then
  echo "ERROR: transfer-gate-server.py not found in $SCRIPT_DIR"
  echo "Make sure this launcher is in the TransferTool folder."
  echo ""
  echo "Press any key to close."
  read -n 1
  exit 1
fi

PYTHON=""
for cmd in python3 python; do
  if command -v "$cmd" >/dev/null 2>&1; then
    if "$cmd" -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" 2>/dev/null; then
      PYTHON="$cmd"
      break
    fi
  fi
done

if [ -z "$PYTHON" ]; then
  echo "ERROR: Python 3.8+ is required but was not found."
  echo ""
  echo "Install Python from https://www.python.org/downloads/ or via Homebrew:"
  echo "  brew install python3"
  echo ""
  echo "Press any key to close."
  read -n 1
  exit 1
fi

echo "Transfer Gate v2 — Mac Launcher"
echo "================================"
echo "Python: $($PYTHON --version)"
echo "Server: $SERVER"
echo "URL:    $URL"
echo ""

(sleep 2 && open "$URL") &

echo "Starting server... (press Ctrl+C to stop)"
echo ""
"$PYTHON" "$SERVER" --port "$PORT"
