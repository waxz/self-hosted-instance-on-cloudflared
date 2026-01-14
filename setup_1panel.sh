#!/usr/bin/env bash
set -euo pipefail

# --- Dependency Import & Environment Setup ---
source /bin/bash_utils.sh
VARFILE="/opt/config/.vars"

# Extract all environment variables from the helper function
while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    export "$k=$v"
done < <(extract_all_env)

# Validate essential environment variables
for var in JSONBINKEY JSONBINURL JSONBINAWSTTYDPATH; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: $var is not set in $VARFILE."
        exit 1
    fi
done

# ------------------ Configuration ------------------
PORT=40636
CLOUDFLARED_LOG="/tmp/cloudflared-tunnel-$PORT.log"
PROGRAM="1panel"
PROGRAM_PATH=$(which $PROGRAM)
PROGRAM_LOG="/tmp/$PROGRAM-$PORT.log"
PROGRAM_PID_FILE="/tmp/$PROGRAM.pid"
JSONBINPATH="$JSONBINURL/$JSONBINAWS_PANEL_PATH/?key=$JSONBINKEY"
WAIT_TIMEOUT=60
# ---------------------------------------------------

# --- 0. Root Privileges Check ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo or as root"
    exit 1
fi

# --- 1. Installation Check ---
echo "=== 1. Checking existing installations ==="
PANEL_INSTALLED=false
CLOUDFLARED_INSTALLED=false

if command -v $PROGRAM >/dev/null 2>&1; then
    echo "✅ 1PANEL is installed."
    PANEL_INSTALLED=true
else
    echo "⚠️ 1PANEL not found. Will install."
fi

if command -v cloudflared >/dev/null 2>&1; then
    echo "✅ cloudflared is installed."
    CLOUDFLARED_INSTALLED=true
else
    echo "⚠️ cloudflared not found. Will install."
fi

# --- 2. Cleanup & Port Release ---
echo "=== 2. Force releasing port $PORT ==="

free_port "$PORT" $PROGRAM_PATH
echo "✅ Port $PORT is free."

# --- 3. Install Dependencies (if missing) ---
if [ "$PANEL_INSTALLED" = false ]; then
    echo "=== Installing $PROGRAM ==="
    curl -sSL https://resource.1panel.pro/quick_start.sh -o /tmp/quick_start.sh && bash /tmp/quick_start.sh
fi

if [ "$CLOUDFLARED_INSTALLED" = false ]; then
    echo "=== Installing cloudflared ==="
    gh_install cloudflare/cloudflared cloudflared-linux-amd64 /tmp/cloudflared && chmod +x /tmp/cloudflared
    cp /tmp/cloudflared /bin
fi

# --- 4. Start PANEL ---
echo "=== Starting $PROGRAM on 127.0.0.1:$PORT ==="

stop_daemon "$PROGRAM" $PROGRAM_PID_FILE
start_daemon "$PROGRAM" $PROGRAM_PID_FILE $PROGRAM_LOG "$PROGRAM"



sleep 1

# Verify PROGRAM is listening specifically on 127.0.0.1
if ss -ltnp | grep -q ":$PORT\\b"; then
    echo "✅ $PROGRAM is listening on 127.0.0.1:$PORT"
else
    echo "❌ $PROGRAM failed to start. Checking logs:"
    tail -n 5 "$PROGRAM_LOG"
    exit 1
fi
# --- 5. Start Cloudflared Tunnel ---
/bin/setup_cftunnel.sh "$PORT"

# --- 6. Wait for Public URL ---
echo "Waiting up to $WAIT_TIMEOUT seconds for cloudflared public URL..."
PUBLIC_URL=""

PUBLIC_URL=$(grep -Eo 'https?://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n1 || true)

if [ -z "$PUBLIC_URL" ]; then
    echo "❌ Failed to detect public URL. Check log: $CLOUDFLARED_LOG"
    exit 1
fi

echo "✅ Detected public URL: $PUBLIC_URL"

# --- 8. Final Output & JSON Update ---
echo
echo "=== Setup complete ==="
echo "$PROGRAM Local:    127.0.0.1:$PORT"
echo "Public URL:    $PUBLIC_URL"
echo "Log File:      $CLOUDFLARED_LOG"
echo "Updating JSONBIN..."
echo "$JSONBINPATH&q=url" "-->" "$PUBLIC_URL"
echo "$JSONBINPATH&r=1"
curl -s "$JSONBINPATH&q=url" -d "$PUBLIC_URL"
echo "" # Newline for clean exit
