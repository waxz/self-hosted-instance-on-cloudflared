#!/usr/bin/env bash
set -euo pipefail

# --- Dependency Import & Environment Setup ---
source /bin/bash_utils.sh
VARFILE="/opt/.vars"

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
PORT=38010
CLOUDFLARED_LOG="/tmp/cloudflared-tunnel-$PORT.log"
TTYD_LOG="/tmp/ttyd-$PORT.log"
TTYD_PID_FILE="/tmp/ttyd.pid"
WAIT_TIMEOUT=60
# ---------------------------------------------------

# --- 0. Root Privileges Check ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo or as root"
    exit 1
fi

# --- 1. Installation Check ---
echo "=== 1. Checking existing installations ==="
TTYD_INSTALLED=false
CLOUDFLARED_INSTALLED=false

if command -v ttyd >/dev/null 2>&1; then
    echo "✅ ttyd is installed."
    TTYD_INSTALLED=true
else
    echo "⚠️ ttyd not found. Will install."
fi

if command -v cloudflared >/dev/null 2>&1; then
    echo "✅ cloudflared is installed."
    CLOUDFLARED_INSTALLED=true
else
    echo "⚠️ cloudflared not found. Will install."
fi

# --- 2. Cleanup & Port Release ---
echo "=== 2. Force releasing port $PORT ==="

free_port "$PORT" "ttyd -i"
echo "✅ Port $PORT is free."

# --- 3. Install Dependencies (if missing) ---
if [ "$TTYD_INSTALLED" = false ]; then
    echo "=== Installing ttyd ==="
    gh_install tsl0922/ttyd ttyd.x86_64 /tmp/ttyd && chmod +x /tmp/ttyd
    cp /tmp/ttyd /bin
fi

if [ "$CLOUDFLARED_INSTALLED" = false ]; then
    echo "=== Installing cloudflared ==="
    gh_install cloudflare/cloudflared cloudflared-linux-amd64 /tmp/cloudflared && chmod +x /tmp/cloudflared
    cp /tmp/cloudflared /bin
fi

# --- 4. Start TTYD ---
echo "=== Starting ttyd on 127.0.0.1:$PORT ==="

# 1. setsid: Detaches process from current shell so it survives script exit.
# 2. -i 127.0.0.1: STRICTLY binds to IPv4 loopback to prevent IPv6 resolution errors.
# nohup setsid ttyd -i 127.0.0.1 -W -p "$PORT" -t enableTrzsz=true -c "$JSONBINKEY:$JSONBINKEY" bash > "$TTYD_LOG" 2>&1 &
# TTYD_PID=$!
# disown $TTYD_PID # Remove from jobs list

stop_daemon "ttyd" $TTYD_PID_FILE
start_daemon "ttyd" $TTYD_PID_FILE $TTYD_LOG "ttyd -i 127.0.0.1 -W -p $PORT -t enableTrzsz=true -c $JSONBINKEY:$JSONBINKEY bash"



sleep 1

# Verify TTYD is listening specifically on 127.0.0.1
if ss -ltnp | grep -q "127.0.0.1:$PORT\\b"; then
    echo "✅ ttyd is listening on 127.0.0.1:$PORT"
else
    echo "❌ ttyd failed to start. Checking logs:"
    tail -n 5 "$TTYD_LOG"
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
echo "TTYD Local:    127.0.0.1:$PORT"
echo "Public URL:    $PUBLIC_URL"
echo "Log File:      $CLOUDFLARED_LOG"
echo "Updating JSONBIN..."
echo "$JSONBINURL/$JSONBINAWSTTYDPATH/?key=$JSONBINKEY&q=url" "-->" "$PUBLIC_URL"
echo "$JSONBINURL/$JSONBINAWSTTYDPATH/?key=$JSONBINKEY&r=1"
curl -s "$JSONBINURL/$JSONBINAWSTTYDPATH/?key=$JSONBINKEY&q=url" -d "$PUBLIC_URL"
echo "" # Newline for clean exit