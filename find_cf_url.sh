#!/usr/bin/env bash
# set -euo pipefail

# https://stackoverflow.com/questions/3236871/how-to-return-a-string-value-from-a-bash-function

find_cf_url(){
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 CLOUDFLARED_LOG return_var"
    return 0
  fi 

  CLOUDFLARED_LOG=$1
  return_var=$2

  if [[ ! -f $CLOUDFLARED_LOG ]];then
    echo "Cannot find $CLOUDFLARED_LOG"
    return 0
  fi 

  WAIT_TIMEOUT=60
  #echo "Waiting up to $WAIT_TIMEOUT seconds for cloudflared public URL in $CLOUDFLARED_LOG"
  #exit 0
  END_TIME=$(( $(date +%s) + WAIT_TIMEOUT ))
  PUBLIC_URL=""

  while [ "$(date +%s)" -le "$END_TIME" ]; do
      # Regex matches standard TryCloudflare URLs
      PUBLIC_URL=$(grep -Eo 'https?://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n1 || true)
      if [ -n "$PUBLIC_URL" ]; then break; fi
      sleep 1
  done
  echo $PUBLIC_URL
  eval "$2='$PUBLIC_URL'"
}
