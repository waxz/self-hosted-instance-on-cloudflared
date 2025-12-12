#!/usr/bin/env bash
set -euo pipefail

# --- Environment Setup ---
source /bin/bash_utils.sh

# --- 0. Root Check ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo or as root"
    exit 1
fi



V2_CONFIG_PATH="/usr/local/etc/v2ray/config.json"
V2_LOG_DIR="/var/log/v2ray"
V2RAY_LOG="/tmp/v2ray.log"
V2RAY_PID_FILE="/tmp/v2ray.pid"


# Choose mode: tor or direct
MODE="${1:-direct}"   # "tor" or "direct"

if [[ "$MODE" == "tor" ]]; then
  OUTBOUND=$(cat <<EOF
{
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": 9060
      }
    ]
  }
}
EOF
)
else
  OUTBOUND='{"protocol":"freedom","settings":{}}'
fi

# Update config.json
jq --argjson out "$OUTBOUND" '.outbounds[0]=$out' "$V2_CONFIG_PATH" > "${V2_CONFIG_PATH}.tmp" && mv "${V2_CONFIG_PATH}.tmp" "$V2_CONFIG_PATH"

# Restart V2Ray
# systemctl restart v2ray
stop_daemon "V2Ray" $V2RAY_PID_FILE
start_daemon "V2Ray" $V2RAY_PID_FILE $V2RAY_LOG "v2ray run -c $V2_CONFIG_PATH"


echo "✅ V2Ray restarted with outbound mode: $MODE. Check your ip at https://www.showmyip.com/"
