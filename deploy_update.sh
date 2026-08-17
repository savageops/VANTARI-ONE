#!/usr/bin/env bash
set -euo pipefail

# VANTARI Self-Destructing Deploy Script
# Stops running VANTARI, swaps binary, restarts, then deletes itself.

WORKSPACE="/home/github/vantari"
BINARY_SRC="${WORKSPACE}/apps/backend/zig-out/bin/vantari"
BINARY_DST="/usr/local/bin/vantari"
OWNER_JSON="${WORKSPACE}/.var/runtime/execution-owner.json"
PORT=18833
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="${BINARY_DST}.bak.${TIMESTAMP}"

# --- Verify build artifact exists ---
if [ ! -f "$BINARY_SRC" ]; then
  echo "FATAL: Build artifact not found at $BINARY_SRC"
  exit 1
fi

# --- SHA-256 of new binary ---
NEW_HASH=$(sha256sum "$BINARY_SRC" | awk '{print $1}')
echo "New binary SHA-256: $NEW_HASH"

# --- Read PID from execution-owner.json ---
PID=""
if [ -f "$OWNER_JSON" ]; then
  PID=$(python3 -c "import json; print(json.load(open('$OWNER_JSON')).get('pid',''))" 2>/dev/null || echo "")
fi

# --- Kill running VANTARI (graceful then force) ---
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  echo "Stopping VANTARI (PID $PID)..."
  kill "$PID" 2>/dev/null || true
  for i in $(seq 1 10); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$PID" 2>/dev/null; then
    echo "Process did not exit gracefully, sending SIGKILL..."
    kill -9 "$PID" 2>/dev/null || true
    sleep 2
  fi
else
  echo "No running VANTARI process found via owner record."
  # Fallback: try pkill on the binary path
  pkill -f "$BINARY_DST" 2>/dev/null && sleep 2 || true
fi

# --- Backup current binary ---
if [ -f "$BINARY_DST" ]; then
  echo "Backing up current binary to $BACKUP_PATH"
  cp "$BINARY_DST" "$BACKUP_PATH"
else
  echo "No existing binary at $BINARY_DST (first install)."
fi

# --- Install new binary ---
echo "Installing new binary..."
cp "$BINARY_SRC" "$BINARY_DST"
chmod +x "$BINARY_DST"

# --- Verify installed binary SHA-256 matches ---
INSTALLED_HASH=$(sha256sum "$BINARY_DST" | awk '{print $1}')
if [ "$NEW_HASH" != "$INSTALLED_HASH" ]; then
  echo "FATAL: SHA-256 mismatch after copy! Rolling back..."
  if [ -f "$BACKUP_PATH" ]; then
    cp "$BACKUP_PATH" "$BINARY_DST"
    chmod +x "$BINARY_DST"
    echo "Rolled back to previous binary."
  fi
  exit 1
fi
echo "SHA-256 verified: $INSTALLED_HASH"

# --- Restart VANTARI ---
echo "Starting VANTARI on port $PORT..."
# Launch in background, detached from this script
nohup "$BINARY_DST" serve --port "$PORT" > /tmp/vantari-restart.log 2>&1 &
NEW_PID=$!
echo "VANTARI restarted with PID $NEW_PID"

# --- Wait briefly and verify it started ---
sleep 3
if kill -0 "$NEW_PID" 2>/dev/null; then
  echo "VANTARI is running (PID $NEW_PID)."
else
  echo "WARNING: VANTARI process not detected after restart. Check /tmp/vantari-restart.log"
  echo "Manual restart may be needed: $BINARY_DST serve --port $PORT &"
fi

# --- Self-destruct ---
echo "Deploy complete. Self-destructing this script..."
rm -- "$0"
echo "Script removed."
