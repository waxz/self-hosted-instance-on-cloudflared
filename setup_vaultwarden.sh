#!/usr/bin/env bash
set -euo pipefail

# --- Environment Setup ---
source /bin/bash_utils.sh
VARFILE="/opt/config/.vars" # or /home/codespace/.vars depending on env

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
PORT=38070
CONFIGPATH="/tmp/vaultwarden"
VAULTWARDEN_DOMAIN="${VAULTWARDEN_DOMAIN:-example.com}"
VAULTWARDEN_LOG="/tmp/vaultwarden.log"
VAULTWARDEN_PID_FILE="/tmp/vaultwarden.pid"
CLOUDFLARED_LOG="/tmp/cloudflared-tunnel-$PORT.log"
WAIT_TIMEOUT=60
OUTPUTFILE="/tmp/vaultwarden_archive.tar.gz"
# ---------------------------------------------------   
# --- 0. Root Check ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo or as root"
    exit 1
fi


# --- 1. Dependency Checks ---
# check and install docker and cloudflared

echo "=== 1. Checking installations ==="
DOCKER_INSTALLED=false
if command -v docker >/dev/null 2>&1; then
    echo "✅ Docker is installed."
    DOCKER_INSTALLED=true
    
    else
    echo "❌ Docker not found. Please install it first."
    exit 1
fi  
if ! command -v cloudflared >/dev/null 2>&1; then
    echo "❌ cloudflared not found. Please install it first."
    exit 1
else
    echo "✅ cloudflared is installed."
fi


# 2. Port Cleanup
echo "=== 2. Clearing port $PORT ==="
free_port "$PORT"
echo "✅ Port $PORT is free."


# 3. start cloudflared tunnel
echo "=== 3. Starting cloudflared tunnel ==="
/bin/setup_cftunnel.sh "$PORT"



# --- 4. Wait for Public URL ---
echo "=== 4. Waiting up to $WAIT_TIMEOUT seconds for cloudflared public URL..."
PUBLIC_URL=""

PUBLIC_URL=$(grep -Eo 'https?://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n1 || true)

if [ -z "$PUBLIC_URL" ]; then
    echo "❌ Failed to detect public URL. Check log: $CLOUDFLARED_LOG"
    exit 1
fi

echo "✅ Detected public URL: $PUBLIC_URL"


# 4. Start Vaultwarden Docker Container

mkdir -p "$CONFIGPATH/data"



echo "=== 1. Downloading vaultwarden Data from JSONBIN ==="
if [ ! -f $OUTPUTFILE ] ; then
  echo "$OUTPUTFILE does not exist, downloading..."
  curl "$JSONBINURL/$JSONBINVAULTWARDENDATAPATH/?key=$JSONBINKEY" -o $OUTPUTFILE
fi

tarvalid=$(tar -tf $OUTPUTFILE &> /dev/null; echo $?)
if [ "$tarvalid" -eq "0" ]; then 
  echo "$OUTPUTFILE is valid, extracting..." 
  echo "Extracting to $CONFIGPATH"
  tar -xzvf $OUTPUTFILE -C $CONFIGPATH
  
else
 echo "$OUTPUTFILE is not valid, initializing new openlist config"
fi




echo "=== 5. Starting Vaultwarden Docker Container ==="

cp /opt/config/vaultwarden-docker-compose-example.yml $CONFIGPATH/docker-compose.yml
sed -i "s#https://vw.domain.tld#$PUBLIC_URL#g" $CONFIGPATH/docker-compose.yml
sed -i "s#8000#$PORT#g" $CONFIGPATH/docker-compose.yml
sed -i "s#/tmp/vw-data#$CONFIGPATH/data#g" $CONFIGPATH/docker-compose.yml

cd $CONFIGPATH && docker compose kill && docker compose rm -f
cd $CONFIGPATH && docker compose up -d



# --- 8. Final Output & JSON Update ---
echo
echo "=== Setup complete ==="
echo "Expose Local:    127.0.0.1:$PORT"
echo "Public URL:    $PUBLIC_URL"
echo "Log File:      $CLOUDFLARED_LOG"
echo "Updating JSONBIN..."
echo "$JSONBINURL/$JSONBINVAULTWARDENPATH/?key=$JSONBINKEY&q=url" "-->" "$PUBLIC_URL"
echo "$JSONBINURL/$JSONBINVAULTWARDENPATH/?key=$JSONBINKEY&r=1"

curl -s "$JSONBINURL/$JSONBINVAULTWARDENPATH/?key=$JSONBINKEY&q=url" -d "$PUBLIC_URL"
echo "" # Newline for clean exit
while true; do
inotifywait -e modify,create,delete -r $CONFIGPATH/data && \
cd $CONFIGPATH/ && tar -czvf $OUTPUTFILE ./data/ && \
curl "$JSONBINURL/$JSONBINVAULTWARDENDATAPATH/?key=$JSONBINKEY" --data-binary @$OUTPUTFILE && \
echo "✅ Vaultwarden data updated to JSONBIN." && sleep 10
done
