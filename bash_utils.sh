#!/bin/bash
# Utility functions for bash scripts
# gh_install vi/websocat websocat.x86_64-unknown-linux-musl


gh_install() {

  if [[ $# -ne 3 ]]; then
    echo "Please set repo, arch, and filename"
    return 1
  fi

  local repo="$1"
  local arch="$2"
  local filename="$3"

  echo "Set repo: $repo, arch: $arch, filename: $filename"

  local url=""
  local count=0

  while [[ -z "$url" && "$count" -lt 5 ]]; do
    content=$(curl -s -L -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$repo/releases")

    # 1. Get the list of all matching URLs as an array
    all_matches=$(echo "$content" | jq -r --arg arch "$arch" '.[0].assets[] | select(.name | endswith($arch)) | .browser_download_url')

    # 2. Count how many matches were found
    if [[ -z "$all_matches" ]]; then
        match_count=0
    else
        match_count=$(echo "$all_matches" | grep -c '^http' || echo 0)
    
    fi

    if [[ "$match_count" -gt 1 ]]; then
      echo "Error: Multiple assets match '$arch'. Please be more specific."
      echo "Matches found:"
      echo "$all_matches"
      return 1
    elif [[ "$match_count" -eq 1 ]]; then
      url="$all_matches"
      break;
    else
      # No matches, loop continues to retry...
      echo "No match found for '$arch' (Attempt $((count + 1))/5)"
      count=$((count + 1))
      sleep 1
    fi

  done

  if [[ -z "$url" ]]; then
    echo "Failed to find a valid download URL after $count attempts."
    return 1
  fi

  echo "Download URL: $url"
  echo "Download filename: $filename"
  curl -L "$url" -o "$filename" && echo "Downloaded $filename successfully." || echo "Failed to download $filename."
}

# Utility functions for managing processes
ps_kill() {

  if [[ $# -ne 1 ]]; then
    echo "Please set program"
    return 1
  fi
  program="$1"

  ps -A -o tid,cmd  | grep -v grep | grep "$program" | awk '{print $1}' | xargs -I {} /bin/bash -c ' sudo kill -9  {} '
}

kill_program(){

  if [[ $# -ne 1 ]]; then
    echo "Please set program"
    return 1
  fi
  program="$1"

  # Prefer pgrep when available; otherwise fall back to ps+grep.
  if command -v pgrep >/dev/null 2>&1; then
    EXISTING_PIDS=$(pgrep -f "$program" || true)
  else
    # Use ps to list processes, then filter. Use grep -F to match literal string.
    EXISTING_PIDS=$(ps -eo pid,cmd --no-headers | grep -v grep | grep -F -- "$program" | awk '{print $1}' || true)
  fi

  if [ -n "$EXISTING_PIDS" ]; then
    echo "Killing existing $program processes: $EXISTING_PIDS"
    kill -9 $EXISTING_PIDS || true
    sleep 1
  fi

}

histclean() {
  history | awk '{$1=""; print substr($0,2)}'
}


extract_var() {
    if [[ $# -ne 2 ]]; then
    echo "Please var-file var-name"
    return 1
  fi

    local BASHRC="$1"
    local var="$2"
    local raw

    raw=$(grep -E "^export ${var}=|^${var}=" "$BASHRC" \
        | head -n1 \
        | sed -E "s/^(export +)?${var}=//")

    # Trim leading/trailing spaces
    raw=$(echo "$raw" | sed -E 's/^[ \t]+|[ \t]+$//g')

    # Remove ONE matching pair of quotes if present
    raw=$(echo "$raw" | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')

    # ALSO remove any dangling quotes like: abc" or "abc
    raw=$(echo "$raw" | sed -E 's/^"//; s/"$//; s/^'\''//; s/'\''$//')

    echo "$raw"
}


extract_all_env() {
    grep -E '^(export +)?[A-Za-z_][A-Za-z0-9_]*=' "$VARFILE" \
    | sed -E 's/#.*$//' \
    | sed -E 's/^[ \t]+|[ \t]+$//g' \
    | while IFS= read -r line; do

        # Remove "export "
        line=$(echo "$line" | sed -E 's/^export +//')

        key="${line%%=*}"
        val="${line#*=}"

        # Strip surrounding quotes
        val=$(echo "$val" | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')
        val=$(echo "$val" | sed -E 's/^"//; s/"$//; s/^'\''//; s/'\''$//')

        printf "%s=%s\n" "$key" "$val"
    done
}

# Start a daemon with PID tracking
start_daemon() {
    local name="$1"
    local pid_file="$2"
    local log_file="$3"
    shift 3
    local cmd="$@"
    
    rm -f "$pid_file"
    
    nohup setsid bash -c '
        echo $$ > "'"$pid_file"'"
        exec '"$cmd"'
    ' > "$log_file" 2>&1 &
    
    sleep 2
    
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        echo "✅ $name started (PID: $(cat "$pid_file"))"
        return 0
    else
        echo "❌ $name failed to start"
        return 1
    fi
}

# Stop a daemon by PID file
stop_daemon() {
    local name="$1"
    local pid_file="$2"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$pid_file"
        echo "✅ $name stopped (PID: $pid)"
    fi
}

# Kill process and free port
# Usage: free_port <port> [process_pattern] [max_wait]
# Example: free_port 10000 "v2ray run" 20
free_port() {
    local port="$1"
    local process_pattern="${2:-}"
    local max_wait="${3:-20}"
    
    echo "=== Clearing port $port ==="
    
    # Install fuser if missing
    if ! command -v fuser &> /dev/null; then
        apt-get update && apt-get install -y psmisc
    fi
    
    # Step 1: Kill by process name if provided
    if [ -n "$process_pattern" ]; then
        echo "Killing processes matching: $process_pattern"
        pkill -9 -f "$process_pattern" || true
        sleep 1
    fi
    
    # Step 2: Kill anything on the port
    echo "Killing anything on port $port..."
    fuser -k -9 "$port/tcp" 2>/dev/null || true
    sleep 1
    
    # Step 3: Wait for port to be free
    echo "Waiting for port $port to be free..."
    local count=0
    while ss -tlnp | grep -q ":$port "; do
        sleep 1
        ((count++))
        
        if [ $count -ge $max_wait ]; then
            echo "❌ Port $port still in use after ${max_wait}s"
            ss -tlnp | grep ":$port " || true
            return 1
        fi
        
        # Retry kill every 5 seconds
        if [ $((count % 5)) -eq 0 ]; then
            echo "Retrying kill..."
            [ -n "$process_pattern" ] && pkill -9 -f "$process_pattern" || true
            fuser -k -9 "$port/tcp" 2>/dev/null || true
        fi
    done
    
    echo "✅ Port $port is free."
    return 0
}
