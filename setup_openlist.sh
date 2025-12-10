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
for var in JSONBINKEY JSONBINURL JSONBINOPENLISTDATAPATH JSONBINOPENLISTPATH FILEN_EMAIL FILEN_PASSWORD; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: $var is not set in $VARFILE."
        exit 1
    fi
done

# ------------------ Configuration ------------------
PORT=5244
FILEN_PORT=5255
RCLONE_R2_1_PORT=5260
RCLONE_R2_2_PORT=5261

CLOUDFLARED_LOG="/tmp/cloudflared-tunnel-$PORT.log"
OPENLIST_LOG="/tmp/openlist-$PORT.log"
FILEN_LOG="/tmp/filen-$FILEN_PORT.log"
RCLONE_R2_1_LOG="/tmp/rclone-$RCLONE_R2_1_PORT.log"
RCLONE_R2_2_LOG="/tmp/rclone-$RCLONE_R2_2_PORT.log"

WAIT_TIMEOUT=60

OUTPUTFILE="/tmp/openlist_archive.tar.gz"
CONFIGPATH="/tmp/openlist_data"
mkdir -p $CONFIGPATH
echo OUTPUTFILE $OUTPUTFILE
# if [ -f "$OUTPUTFILE" ] ; then rm $OUTPUTFILE; fi

echo "=== 1. Downloading OpenList Data from JSONBIN ==="
if [ ! -f $OUTPUTFILE ] ; then
  echo "$OUTPUTFILE does not exist, downloading..."
  curl "$JSONBINURL/$JSONBINOPENLISTDATAPATH/?key=$JSONBINKEY" -o $OUTPUTFILE
fi

tarvalid=$(tar -tf $OUTPUTFILE &> /dev/null; echo $?)
if [ "$tarvalid" -eq "0" ]; then 
  echo "$OUTPUTFILE is valid, extracting..." 
  echo "Extracting to $CONFIGPATH"
  tar -xzvf $OUTPUTFILE -C $CONFIGPATH
  
else
 echo "$OUTPUTFILE is not valid, initializing new openlist config"
 cd $CONFIGPATH && openlist admin set $JSONBINKEY
fi



echo "=== 2. Setting up OpenList Configuration ==="

kill_program "openlist server"
# openlist admin set "$JSONBINKEY" --data /tmp/openlist_data/data

cat $CONFIGPATH/data/config.json | jq  '.log.name="/tmp/.openlist/log.log"' |sponge $CONFIGPATH/data/config.json
if [ -d "$CONFIGPATH/data/log" ] ; then echo "removing log file" ;rm -r "$CONFIGPATH/data/log"; fi

tar -czvf $OUTPUTFILE $CONFIGPATH/data/
curl "$JSONBINURL/$JSONBINOPENLISTDATAPATH/?key=$JSONBINKEY" --data-binary @$OUTPUTFILE

nohup setsid bash -c "cd $CONFIGPATH && openlist server" >"$OPENLIST_LOG" 2>&1 &
sleep 3

echo "=== 3. Starting Filen WebDAV Server ==="
kill_program "filen webdav"
kill_program "rclone serve webdav"
nohup setsid bash -c "filen webdav --email $FILEN_EMAIL --password $FILEN_PASSWORD --w-user $JSONBINKEY --w-password $JSONBINKEY --w-port $FILEN_PORT" > "$FILEN_LOG" 2>&1 &

nohup setsid bash -c "rclone serve webdav  --htpasswd /opt/config/htpasswd  --addr 127.0.0.1:$RCLONE_R2_1_PORT  r2-1:" > "$RCLONE_R2_1_LOG" 2>&1 &
nohup setsid bash -c "rclone serve webdav  --htpasswd /opt/config/htpasswd  --addr 127.0.0.1:$RCLONE_R2_2_PORT  r2-2:" > "$RCLONE_R2_2_LOG" 2>&1 &

sleep 3
# --- 5. Start Cloudflared Tunnel ---
echo "=== 4. Starting cloudflared tunnel for OpenList and Filen ==="
/bin/setup_cftunnel.sh "$PORT"



# --- 6. Wait for Public URL ---
echo "=== 6. Waiting up to $WAIT_TIMEOUT seconds for cloudflared public URL..."
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
echo "Expose Local:    127.0.0.1:$PORT"
echo "Public URL:    $PUBLIC_URL"
echo "Log File:      $CLOUDFLARED_LOG"
echo "Updating JSONBIN..."
echo "$JSONBINURL/$JSONBINOPENLISTPATH/?key=$JSONBINKEY&q=url" "-->" "$PUBLIC_URL"
echo "$JSONBINURL/$JSONBINOPENLISTPATH/?key=$JSONBINKEY&r=1"

curl -s "$JSONBINURL/$JSONBINOPENLISTPATH/?key=$JSONBINKEY&q=url" -d "$PUBLIC_URL"
echo "" # Newline for clean exit
while true; do
inotifywait -e modify,create,delete -r $CONFIGPATH/data && \
cd $CONFIGPATH && tar -czvf $OUTPUTFILE ./data/ && \
curl "$JSONBINURL/$JSONBINOPENLISTDATAPATH/?key=$JSONBINKEY" --data-binary @$OUTPUTFILE && \
echo "✅ Openlist data updated to JSONBIN." && sleep 10
done
