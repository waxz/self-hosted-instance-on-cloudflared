#!/usr/bin/env bash
set -euo pipefail

# --- Environment Setup ---
source /bin/bash_utils.sh
VARFILE="/opt/config/.vars"

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
SUB_DATA_PATH="/tmp/sub_data.txt"
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

if command -v xray >/dev/null 2>&1; then
    echo "✅ Xray is installed."
    V2_INSTALLED=true
    V2RAY_CMD="xray"
elif command -v v2ray >/dev/null 2>&1; then
    echo "✅ V2Ray is installed."
    V2_INSTALLED=true
    V2RAY_CMD="v2ray"
fi

if ! command -v cloudflared >/dev/null 2>&1; then
    echo "❌ cloudflared not found. Please install it first."
    exit 1
else
    echo "✅ cloudflared is installed."
fi

# --- 2. Port Cleanup ---
echo "=== 2. Clearing port $PORT ==="
service v2ray stop 2>/dev/null || true
service xray stop 2>/dev/null || true
free_port "$PORT" "v2ray run"
free_port "$PORT" "xray run"

echo "✅ Port $PORT is free."

# --- 3. Install if missing ---
if [ "$V2_INSTALLED" = false ]; then
    echo "=== Installing Xray-core ==="
    apt update -y && apt install -y curl jq uuid-runtime || true
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
    V2RAY_CMD="xray"
fi

# --- 4. Configuration Prep ---
UUID=$(uuidgen)
echo "Generated UUID: $UUID"

mkdir -p "$V2_LOG_DIR"
if [ -f /etc/systemd/system/xray.service ]; then
    V2_USER=$(grep '^User=' /etc/systemd/system/xray.service 2>/dev/null | cut -d= -f2 || echo "root")
    V2_GROUP=$(grep '^Group=' /etc/systemd/system/xray.service 2>/dev/null | cut -d= -f2 || echo "root")
else
    V2_USER=$(grep '^User=' /etc/systemd/system/v2ray.service 2>/dev/null | cut -d= -f2 || echo "root")
    V2_GROUP=$(grep '^Group=' /etc/systemd/system/v2ray.service 2>/dev/null | cut -d= -f2 || echo "root")
fi
chown -R "$V2_USER:$V2_GROUP" "$V2_LOG_DIR"
chmod 755 "$V2_LOG_DIR"

# --- 5. Write Config (VLESS + WebSocket) ---
echo "=== Writing config (VLESS + WebSocket) ==="
mkdir -p "$(dirname "$V2_CONFIG_PATH")"

cat >"$V2_CONFIG_PATH" <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0,
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$WS_PATH",
          "headers": {
            "Host": ""
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    }
  ],
  "log": {
    "access": "$V2_LOG_DIR/access.log",
    "error": "$V2_LOG_DIR/error.log",
    "loglevel": "debug"
  }
}
EOF

if ! jq empty "$V2_CONFIG_PATH" 2>/dev/null; then
    echo "❌ Invalid JSON!"
    exit 1
fi

# --- 6. Start Xray ---
echo "=== Starting $V2RAY_CMD ==="
stop_daemon "$V2RAY_CMD" $V2RAY_PID_FILE
start_daemon "$V2RAY_CMD" $V2RAY_PID_FILE $V2RAY_LOG "$V2RAY_CMD run -c $V2_CONFIG_PATH"

sleep 2
if ! ss -ltnp | grep -q "127.0.0.1:$PORT"; then
    echo "❌ Failed to start. Logs:"
    tail -n 20 "$V2RAY_LOG"
    exit 1
fi
echo "✅ Listening on 127.0.0.1:$PORT"

# --- 7. Start Cloudflared ---
echo "=== Starting cloudflared ==="
/bin/setup_cftunnel.sh "$PORT"

# --- 8. Get URL ---
echo "Waiting for URL..."
PUBLIC_URL=""
for i in {1..30}; do
    PUBLIC_URL=$(grep -Eo 'https?://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n1 || true)
    [ -n "$PUBLIC_URL" ] && break
    sleep 1
done

if [ -z "$PUBLIC_URL" ]; then
    echo "❌ No URL found"
    tail -n 20 "$CLOUDFLARED_LOG"
    exit 1
fi

echo "✅ URL: $PUBLIC_URL"
PUBLIC_HOST=$(echo "$PUBLIC_URL" | sed -E 's#^https?://([^/:]+).*#\1#')

# --- 9. Update Host & Restart ---
echo "=== Updating host ==="
jq --arg host "$PUBLIC_HOST" '.inbounds[0].streamSettings.wsSettings.headers.Host = $host' "$V2_CONFIG_PATH" >"${V2_CONFIG_PATH}.tmp" && mv "${V2_CONFIG_PATH}.tmp" "$V2_CONFIG_PATH"

stop_daemon "$V2RAY_CMD" $V2RAY_PID_FILE
start_daemon "$V2RAY_CMD" $V2RAY_PID_FILE $V2RAY_LOG "$V2RAY_CMD run -c $V2_CONFIG_PATH"

sleep 2

# --- 10. Generate Subscription ---
date=$(date '+%Y-%m-%d-%H-%M-%S')
name="cf-ws-$date"

VLESS_LINK="vless://${UUID}@${PUBLIC_HOST}:443?encryption=none&security=tls&type=ws&host=${PUBLIC_HOST}&path=${WS_PATH}&flow=#${name}"

echo "$VLESS_LINK" > "$SUB_DATA_PATH.temp"

name="cf-ws"
VLESS_LINK="vless://${UUID}@${PUBLIC_HOST}:443?encryption=none&security=tls&type=ws&host=${PUBLIC_HOST}&path=${WS_PATH}&flow=#${name}"

echo "$VLESS_LINK" >> "$SUB_DATA_PATH.temp"

base64 -w0 $SUB_DATA_PATH.temp > "$SUB_DATA_PATH"

cat >"$SUB_JSON_PATH" <<EOF
[{
    "protocol": "vless",
    "ps": "$name",
    "add": "$PUBLIC_HOST",
    "port": "443",
    "id": "$UUID",
    "encryption": "none",
    "net": "ws",
    "type": "none",
    "host": "$PUBLIC_HOST",
    "path": "$WS_PATH",
    "tls": "tls",
    "sni": "$PUBLIC_HOST",
    "flow": ""
}]
EOF

# --- 11. Test ---
echo "=== Testing ==="
sleep 4
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PUBLIC_URL" || true)
echo "HTTP Response: $HTTP_CODE"

# --- 12. Output ---
echo
echo "=== Complete ==="
echo "Protocol: VLESS + WebSocket"
echo "UUID: $UUID"
echo "URL: $PUBLIC_URL"
echo
cat "$SUB_DATA_PATH"
echo
curl -s "$JSONBINURL/$JSONBINV2RAYPATH/?key=$JSONBINKEY&q=sub" -d @"$SUB_DATA_PATH"
echo
echo "✅ Done! Check logs if delay test fails:"
echo "   sudo tail -f /var/log/v2ray/access.log"
echo "   sudo tail -f /var/log/v2ray/error.log"
