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
if [ $# -ne 1 ]; then
    echo "Usage: $0 <PORT>"
    exit 1
fi

PORT=$1
CLOUDFLARED_LOG="/tmp/cloudflared-tunnel-$PORT.log"
# CLOUDFLARED_PID_FILE="/var/run/cloudflared-tunnel-$PORT.pid" # Optional: Managed via logic below
WAIT_TIMEOUT=60
# ---------------------------------------------------

# --- 0. Root Privileges Check ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo or as root"
    exit 1
fi

# --- 1. Installation Check ---
echo "=== 1. Checking existing installations ==="
CLOUDFLARED_INSTALLED=false


if command -v cloudflared >/dev/null 2>&1; then
    echo "✅ cloudflared is installed."
    CLOUDFLARED_INSTALLED=true
else
    echo "⚠️ cloudflared not found. Will install."
fi

# --- 2. Cleanup & Port Release ---
kill_program "cloudflared tunnel --url "http://127.0.0.1:$PORT""
# --- 3. Install Dependencies (if missing) ---

if [ "$CLOUDFLARED_INSTALLED" = false ]; then
    echo "=== Installing cloudflared ==="
    gh_install cloudflare/cloudflared cloudflared-linux-amd64 /tmp/cloudflared && chmod +x /tmp/cloudflared
    cp /tmp/cloudflared /bin
fi


if ss -ltnp | grep -q "127.0.0.1:$PORT\\b"; then
    echo "✅ 127.0.0.1:$PORT is healthy"
else
    echo "❌ 127.0.0.1:$PORT is unhealthy"
fi

# --- 5. Start Cloudflared Tunnel ---
echo "=== Starting cloudflared tunnel ==="
mkdir -p "$(dirname "$CLOUDFLARED_LOG")"
: > "$CLOUDFLARED_LOG"

# 1. NO_PROXY: Ensures connection to localhost doesn't go through environment proxies.
# 2. setsid: Detaches process from shell.
# 3. url "http://127.0.0.1": Explicitly forces IPv4 HTTP connection (fixes connection refused errors).
# 4. --no-autoupdate: Prevents process restart/PID changes during startup.
env NO_PROXY="localhost,127.0.0.1" \
nohup setsid cloudflared tunnel \
    --url "http://127.0.0.1:$PORT" \
    --no-autoupdate \
    --logfile "$CLOUDFLARED_LOG" \
    > /dev/null 2>&1 &

CF_PID=$!
disown $CF_PID # Remove from jobs list

sleep 1

# --- 6. Wait for Public URL ---
echo "Waiting up to $WAIT_TIMEOUT seconds for cloudflared public URL..."
END_TIME=$(( $(date +%s) + WAIT_TIMEOUT ))
PUBLIC_URL=""

while [ "$(date +%s)" -le "$END_TIME" ]; do
    # Regex matches standard TryCloudflare URLs
    PUBLIC_URL=$(grep -Eo 'https?://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n1 || true)
    if [ -n "$PUBLIC_URL" ]; then break; fi
    sleep 1
done

if [ -z "$PUBLIC_URL" ]; then
    echo "❌ Failed to detect public URL. Check log: $CLOUDFLARED_LOG"
    exit 1
fi

echo "✅ Detected public URL: $PUBLIC_URL"

# --- 7. Connectivity Verification ---
echo "=== Verifying external connectivity ==="
# Wait a few seconds for DNS propagation/tunnel registration
sleep 4 

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PUBLIC_URL" || true)

if [[ "$HTTP_CODE" =~ ^2|3|4 ]]; then
    echo "✅ Cloudflared tunnel is reachable: HTTP $HTTP_CODE"
else
    echo "⚠️  Cloudflared tunnel status: HTTP $HTTP_CODE"
    echo "    (If 000, the tunnel process might have died or is blocked by firewall)"
fi

# --- 8. Final Output & JSON Update ---
echo
echo "=== Setup complete ==="
echo "Exposed Local:    127.0.0.1:$PORT"
echo "Public URL:    $PUBLIC_URL"
echo "Log File:      $CLOUDFLARED_LOG"
echo "" # Newline for clean exit