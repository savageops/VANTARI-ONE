#!/usr/bin/env bash
set -euo pipefail

# Development script for the Vantari web app.
#
# Starts the Vite dev server. The Vantari owner (browser bridge) must run
# separately:
#   vantari serve --port 18833   # from the workspace root
#
# Usage:
#   bash scripts/dev.sh

cd "$(dirname "$0")/.."

echo "Starting Vite dev server..."
echo "Note: make sure the Vantari owner is running (vantari serve --port 18833)"
exec npx vite dev --host 127.0.0.1
