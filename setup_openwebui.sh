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
for var in JSONBINKEY JSONBINURL JSONBINOPENWEBUIPATH OPENWEBUIRCLONEPATH; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Error: $var is not set in $VARFILE."
        exit 1
    fi
done

# ------------------ Configuration ------------------
PORT=38071
CONFIGPATH="/tmp/openwebui"
OPENWEBUI_LOG="/tmp/openwebui.log"
OPENWEBUI_PID_FILE="/tmp/openwebui.pid"
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
for cmd in python3 cloudflared rclone; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ $cmd not found. Please install it first."
        exit 1
    fi
    echo "✅ $cmd is installed."
done

# --- 2. Port Cleanup ---
echo "=== 2. Clearing port $PORT ==="
free_port "$PORT"
echo "✅ Port $PORT is free."

# --- 3. Start cloudflared tunnel ---
echo "=== 3. Starting cloudflared tunnel ==="
/bin/setup_cftunnel.sh "$PORT"

# --- 4. Wait for Public URL ---
echo "=== 4. Waiting up to $WAIT_TIMEOUT seconds for cloudflared public URL..."
ELAPSED=0
PUBLIC_URL=""
while [ $ELAPSED -lt $WAIT_TIMEOUT ]; do
    PUBLIC_URL=$(grep -Eo 'https?://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" 2>/dev/null | head -n1 || true)
    [ -n "$PUBLIC_URL" ] && break
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ -z "$PUBLIC_URL" ]; then
    echo "❌ Failed to detect public URL. Check log: $CLOUDFLARED_LOG"
    exit 1
fi

echo "✅ Detected public URL: $PUBLIC_URL"

# --- 5. Mount Open-webui data ---
echo "=== 5. Mounting Open-webui data from rclone remote ==="
mkdir -p "$CONFIGPATH/data" /tmp/.rclone_cache

# Unmount if already mounted
fusermount -u "$CONFIGPATH/data" 2>/dev/null || umount "$CONFIGPATH/data" 2>/dev/null || true

#rclone mount "$OPENWEBUIRCLONEPATH" "$CONFIGPATH/data" \
#    --cache-dir /tmp/.rclone_cache \
#    --vfs-cache-mode full \
#    --vfs-write-back 5s \
#    --vfs-cache-max-age 24h \
#    --allow-non-empty \
#    --daemon

RCLONE_MOUNT=1

    sync_to_cloud() {
        echo "⬆️ Syncing data to Cloud..."
        rclone sync "$CONFIGPATH/data" "$OPENWEBUIRCLONEPATH" \
            --transfers 4 \
            --create-empty-src-dirs \
            --exclude "*.log" \
            --exclude "*.tmp" \
            --exclude "*.pid"
        echo "✅ Sync complete at $(date)"
    }

if [ -z "$RCLONE_MOUNT" ]; then
rclone mount "$OPENWEBUIRCLONEPATH" "$CONFIGPATH/data" \
    --cache-dir /tmp/.rclone_cache \
    --vfs-cache-mode full \
    --vfs-cache-max-age 168h \
    --vfs-cache-max-size 10G \
    --vfs-write-back 30s \
    --vfs-read-chunk-size 128M \
    --vfs-read-chunk-size-limit 2G \
    --buffer-size 64M \
    --dir-cache-time 24h \
    --poll-interval 15m \
    --vfs-fast-fingerprint \
    --allow-non-empty \
    --daemon
else

# --- Check for inotifywait ---
    if ! command -v inotifywait >/dev/null 2>&1; then
        echo "❌ 'inotify-tools' is missing. Please run: apt-get install -y inotify-tools"
        exit 1
    fi

# --- A. Smart Restore (Cloud -> Local) ---
    echo "⬇️ Restoring data from Cloud (Smart Update)..."
    rclone copy "$OPENWEBUIRCLONEPATH" "$CONFIGPATH/data" \
        --update \
        --transfers 4 \
        --buffer-size 100M \
        -P



# --- C. Trap Exit Signals ---
    trap 'echo "🛑 Script stopping! Final sync..."; sync_to_cloud; exit' SIGINT SIGTERM EXIT

    # --- D. Watch for 'close_write' with Debounce ---
    (
        echo "👀 Listening for completed file writes..."
        
        while true; do
            # 1. BLOCK until the FIRST 'close_write', 'move', or 'delete' event happens.
            # We exclude logs to prevent unnecessary triggers.
            inotifywait -r \
                -e close_write,moved_to,delete \
                "$CONFIGPATH/data" \
                --exclude ".*\.log" \
                -qq

            # 2. THE DEBOUNCE LOOP (The "Cool-down" Phase)
            # Once an event is detected, we enter this loop.
            # We verify that NO NEW events happen for 5 seconds.
            while true; do
                # Check for MORE events with a 5-second timeout (-t 5)
                if inotifywait -r -e close_write,moved_to,delete "$CONFIGPATH/data" --exclude ".*\.log" -qq -t 5; then
                    # If inotifywait returns 0 (True), it means ANOTHER event happened inside the 5s window.
                    # So we loop again and restart the 5-second timer.
                    echo "⏳ Detected ongoing activity, resetting timer..."
                    continue
                else
                    # If inotifywait returns 1/2 (False), it timed out. 
                    # This means 5 seconds passed with NO new writes.
                    # We are safe to sync.
                    break
                fi
            done

            # 3. Trigger Sync
            sync_to_cloud
        done
    ) &
    BG_PID=$!
    
    trap "kill $BG_PID 2>/dev/null; sync_to_cloud; exit" SIGINT SIGTERM EXIT

    echo "✅ Live Sync Active: Triggered 5s after file activity stops."


fi


# Wait for mount
sleep 3
echo "✅ Rclone mount initiated"

# --- 6. Start Open-webui service ---
echo "=== 6. Starting Open-webui service ==="
[ -f "$VENV_PATH/bin/activate" ] && source "$VENV_PATH/bin/activate" || true

kill_program "open-webui serve --port" 2>/dev/null || true

DATA_DIR="$CONFIGPATH/data" nohup open-webui serve --port "$PORT" --host 0.0.0.0 >"$OPENWEBUI_LOG" 2>&1 &
echo $! > "$OPENWEBUI_PID_FILE"

# Wait for service to start
sleep 5
echo "✅ Open-webui started (PID: $(cat "$OPENWEBUI_PID_FILE"))"

# --- 7. Final Output & JSON Update ---
echo
echo "=== Setup complete ==="
echo "Local:         127.0.0.1:$PORT"
echo "Public URL:    $PUBLIC_URL"
echo "Logs:          $CLOUDFLARED_LOG | $OPENWEBUI_LOG"
echo
echo "Updating JSONBIN..."

curl -sf "$JSONBINURL/$JSONBINOPENWEBUIPATH/?key=$JSONBINKEY&q=url" -d "$PUBLIC_URL" && \
    echo "✅ JSONBIN updated" || echo "⚠️  JSONBIN update failed"

echo
echo "✅ All services running"
