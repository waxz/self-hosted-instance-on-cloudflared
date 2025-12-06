#!/usr/bin/env bash
set -euo pipefail

# --- Environment Setup ---
source /bin/bash_utils.sh
VARFILE="/opt/.vars" # or /home/codespace/.vars depending on env

# Extract all environment variables
while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    export "$k=$v"
done < <(extract_all_env)

# Validate critical variables
for var in JSONBINKEY JSONBINURL JSONBINV2RAYPATH; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: $var is not set in $VARFILE."
        exit 1
    fi
done

# ------------------ Configuration ------------------
PORT=10000
WS_PATH="/ray"
SUB_JSON_PATH="/tmp/sub.json"
SUB_VMESS_PATH="/tmp/sub_vmess.txt"
V2_CONFIG_PATH="/usr/local/etc/v2ray/config.json"
V2_LOG_DIR="/var/log/v2ray"
V2RAY_LOG="/tmp/v2ray.log"
V2RAY_PID_FILE="/tmp/v2ray.pid"
CLOUDFLARED_LOG="/tmp/cloudflared-tunnel-$PORT.log"
WAIT_TIMEOUT=60
# ---------------------------------------------------

# --- 0. Root Check ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo or as root"
    exit 1
fi

# --- 1. Dependency Checks ---
echo "=== 1. Checking installations ==="
V2_INSTALLED=false
if command -v v2ray >/dev/null 2>&1; then
    echo "✅ V2Ray is installed."
    V2_INSTALLED=true
fi

if ! command -v cloudflared >/dev/null 2>&1; then
    echo "❌ cloudflared not found. Please install it first."
    exit 1
else
    echo "✅ cloudflared is installed."
fi

# --- 2. Port Cleanup ---
echo "=== 2. Clearing port $PORT ==="
service v2ray stop || true
free_port "$PORT" "v2ray run"

echo "✅ Port $PORT is free."

# --- 3. Install V2Ray (if missing) ---
if [ "$V2_INSTALLED" = false ]; then
    echo "=== Installing V2Ray ==="
    apt update -y && apt install -y curl jq uuid-runtime || true
    bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
fi

# --- 4. Configuration Prep ---
UUID=$(uuidgen)
echo "Generated UUID: $UUID"

# Set up logs
mkdir -p "$V2_LOG_DIR"
# Attempt to detect systemd user, fallback to root if in container
V2_USER=$(grep '^User=' /etc/systemd/system/v2ray.service 2>/dev/null | cut -d= -f2 || echo "root")
V2_GROUP=$(grep '^Group=' /etc/systemd/system/v2ray.service 2>/dev/null | cut -d= -f2 || echo "root")
chown -R "$V2_USER:$V2_GROUP" "$V2_LOG_DIR"
chmod 755 "$V2_LOG_DIR"

# --- 5. Write Initial V2Ray Config ---
echo "=== Writing V2Ray config ==="
mkdir -p "$(dirname "$V2_CONFIG_PATH")"

# Note: "listen": "127.0.0.1" is CRITICAL. It forces IPv4 to prevent connection errors.
cat >"$V2_CONFIG_PATH" <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "$UUID", "alterId": 0, "security": "auto" }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH",
          "headers": { "Host": "" }
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ],
  "log": {
    "access": "$V2_LOG_DIR/access.log",
    "error": "$V2_LOG_DIR/error.log",
    "loglevel": "warning"
  }
}
EOF

# --- 6. Start V2Ray (Initial) ---
echo "=== Starting V2Ray (Initial) ==="
# setsid: Detaches process from script session to prevent killing on exit
# nohup setsid v2ray run -c $V2_CONFIG_PATH >"$V2RAY_LOG" 2>&1 &
# V2_PID=$!
# disown $V2_PID
stop_daemon "V2Ray" $V2RAY_PID_FILE
start_daemon "V2Ray" $V2RAY_PID_FILE $V2RAY_LOG "v2ray run -c $V2_CONFIG_PATH"


sleep 1
if ! ss -ltnp | grep -q "127.0.0.1:$PORT"; then
    echo "❌ V2Ray failed to start. Logs:"
    tail -n 5 "$V2RAY_LOG"
    exit 1
fi
echo "✅ V2Ray listening on 127.0.0.1:$PORT"
# --- 7. Start Cloudflared Tunnel ---
echo "=== Starting cloudflared tunnel ==="
/bin/setup_cftunnel.sh "$PORT"

# --- 8. Wait for Public URL ---
echo "Waiting for tunnel URL..."
PUBLIC_URL=""
PUBLIC_URL=$(grep -Eo 'https?://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n1 || true)
    
if [ -z "$PUBLIC_URL" ]; then
    echo "❌ Failed to obtain URL. Check log: $CLOUDFLARED_LOG"
    exit 1
fi

echo "✅ URL: $PUBLIC_URL"
PUBLIC_HOST=$(echo "$PUBLIC_URL" | sed -E 's#^https?://([^/:]+).*#\1#')

# --- 9. Update Config & Hot Restart ---
# We update the 'Host' header in V2Ray config to match the Cloudflare domain
echo "=== Updating V2Ray Host header ==="
jq --arg host "$PUBLIC_HOST" '.inbounds[0].streamSettings.wsSettings.headers.Host = $host' "$V2_CONFIG_PATH" >"${V2_CONFIG_PATH}.tmp" && mv "${V2_CONFIG_PATH}.tmp" "$V2_CONFIG_PATH"

# Kill the initial V2Ray process and restart with new config
# kill $V2_PID 2>/dev/null || true
# wait $V2_PID 2>/dev/null || true

echo "=== Restarting V2Ray with new config ==="
# nohup setsid v2ray run -c $V2_CONFIG_PATH >"$V2RAY_LOG" 2>&1 &
# NEW_V2_PID=$!
# disown $NEW_V2_PID
stop_daemon "V2Ray" $V2RAY_PID_FILE
start_daemon "V2Ray" $V2RAY_PID_FILE $V2RAY_LOG "v2ray run -c $V2_CONFIG_PATH"

sleep 1

# --- 10. Generate Subscriptions ---
# Plain JSON
cat >"$SUB_JSON_PATH" <<EOF
[{
    "v": "2", "ps": "CF-Tunnel", "add": "$PUBLIC_HOST", "port": "443",
    "id": "$UUID", "aid": "0", "net": "ws", "type": "none",
    "host": "$PUBLIC_HOST", "path": "$WS_PATH", "tls": "tls"
}]
EOF

# VMess Link (Base64)
date=$(date '+%Y-%m-%d-%H-%M-%S')
name="cf-tunnel-$date"
NODE_JSON=$(jq -n \
  --arg add "$PUBLIC_HOST" --arg name "$name" --arg id "$UUID" --arg host "$PUBLIC_HOST" --arg path "$WS_PATH" \
  '{v:"2", ps:$name, add:$add, port:"443", id:$id, aid:"0", net:"ws", type:"none", host:$host, path:$path, tls:"tls"}'
)
echo "vmess://$(echo -n "$NODE_JSON" | base64 -w0)" > "$SUB_VMESS_PATH"

# --- 11. Verification ---
echo "=== Verifying connectivity ==="
sleep 4
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PUBLIC_URL" || true)

if [[ "$HTTP_CODE" =~ ^2|3|4 ]]; then
    echo "✅ Tunnel Reachable: HTTP $HTTP_CODE"
else
    echo "⚠️  Tunnel returned HTTP $HTTP_CODE (Check firewall or logs)"
fi

# --- 12. Final Output ---
echo
echo "=== Setup Complete ==="
echo "UUID: $UUID"
echo "URL:  $PUBLIC_URL"
echo "Sub:  vmess://..."
# Dump contents for debug
cat "$SUB_VMESS_PATH"
echo
echo "Uploading to JSONBIN..."
echo "$JSONBINURL/$JSONBINV2RAYPATH/?key=$JSONBINKEY&q=sub" "->" @"$PUBLIC_URL"
curl -s "$JSONBINURL/$JSONBINV2RAYPATH/?key=$JSONBINKEY&q=sub" -d @"$SUB_VMESS_PATH"
echo ""