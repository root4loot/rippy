#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"

usage() {
  echo "Usage: $0 <spotify_track_url> <output_dir>"
  echo
  echo "Download a track from Spotify via lucida.to"
  echo
  echo "Arguments:"
  echo "  spotify_track_url   URL of the Spotify track to download"
  echo "  output_dir          Directory to save the downloaded file"
}

urlencode() {
  local string="$1"
  local length="${#string}"
  local encoded=""
  
  for ((i=0; i<length; i++)); do
    local c="${string:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded="$encoded$c" ;;
      *) encoded="$encoded$(printf '%%%02X' "'$c")" ;;
    esac
  done
  
  echo "$encoded"
}

json_extract() {
  local json="$1"
  local key="$2"
  echo "$json" | sed -n 's/.*"'"$key"'"\s*:\s*"\([^"]*\)".*/\1/p'
}

download_from_service() {
  local spotify_url="$1"
  local output_dir="$2"
  local service="$3"
  local artist="$4"
  local title="$5"
  local attempt="$6"
  
  echo "INFO: Trying to download from $service (attempt $attempt)..." >&2
  
  local encoded_url=$(urlencode "$spotify_url")
  local lucida_url="https://lucida.to/?url=${encoded_url}&country=auto&to=${service}"
  
  echo "INFO: Making initial request to lucida.to (service: $service), waiting for response..." >&2
  
  local redirect_response=$(curl -s -I "$lucida_url" -H "Origin: https://lucida.to")
  local location=$(echo "$redirect_response" | grep -i "Location:" | sed 's/Location: //' | tr -d '\r')
  
  echo "INFO: Received response from lucida.to" >&2
  
  if [[ "$location" == *"failed-to=$service"* ]]; then
    echo "INFO: Track not available on $service" >&2
    return 1
  fi

  if [[ -z "$location" ]]; then
    echo "ERROR: No redirect received for $service" >&2
    return 1
  fi
  
  echo "INFO: Redirected to: $location" >&2

  local service_url=$(echo "$location" | sed 's/.*url=\([^&]*\).*/\1/' | sed 's/%3A/:/g; s/%2F/\//g')
  
  if [[ -z "$service_url" ]]; then
    echo "ERROR: Failed to extract service URL from redirect" >&2
    echo "DEBUG: Location header: $location" >&2
    return 1
  fi
  
  echo "INFO: Service URL: $service_url" >&2
  
  local current_time=$(date +%s)
  local expiry=$((current_time + 86400))
  
  local post_data='{
    "url":"'"$service_url"'",
    "metadata":true,
    "compat":false,
    "private":true,
    "handoff":true,
    "account":{"type":"country","id":"auto"},
    "upload":{"enabled":false,"service":"pixeldrain"},
    "downscale":"original",
    "token":{"primary":"y5STwMUrIXJZ6yb5xYHh3VEiM-c","expiry":'"$expiry"'}
  }'
  
  echo "INFO: Sending POST request to initiate download" >&2
  
  local post_response=$(curl -s -X POST "https://lucida.to/api/load?url=/api/fetch/stream/v2" \
    -H "Content-Type: text/plain;charset=UTF-8" \
    -H "Origin: https://lucida.to" \
    -d "$post_data")
  
  echo "DEBUG: POST response: $post_response" >&2

  local request_id=$(json_extract "$post_response" "handoff")
  
  if [[ -z "$request_id" ]]; then
    request_id=$(json_extract "$post_response" "id")
  fi
  
  if [[ -z "$request_id" ]]; then
    echo "ERROR: Failed to get request/handoff ID. Response: $post_response" >&2
    return 1
  fi
  
  local server_name=$(json_extract "$post_response" "name")
  if [[ -z "$server_name" ]]; then
    server_name="hund"
  fi
  
  echo "INFO: Got handoff ID: $request_id on server: $server_name. Polling for status..." >&2
  
  local status="started"
  local poll_count=0
  local max_polls=120

  while [[ "$status" != "completed" && $poll_count -lt $max_polls ]]; do
    sleep 2
    ((poll_count++))
    
    local status_response=$(curl -s "https://$server_name.lucida.to/api/fetch/request/$request_id")
    echo "DEBUG: Status response: $status_response" >&2
    
    status=$(json_extract "$status_response" "status")
    local message=$(json_extract "$status_response" "message")

    if [[ -z "$status" ]]; then
      local success=$(echo "$status_response" | sed -n 's/.*"success":\s*\([^,}]*\).*/\1/p')
      if [[ "$success" == "true" ]]; then
        status="working"
      else
        status="error"
      fi
    fi
    
    echo "INFO: Status: $status - $message" >&2

    if [[ "$status" == "error" || "$status" == "failed" ]]; then
      echo "ERROR: Download failed with status: $status" >&2
      return 1
    fi
  done
  
  if [[ "$status" != "completed" ]]; then
    echo "ERROR: Download timed out" >&2
    return 1
  fi
  
  echo "INFO: Download marked as completed, retrieving file..." >&2
  
  local safe_artist=$(echo "$artist" | sed 's/[\/]/_/g')
  local safe_title=$(echo "$title" | sed 's/[\/]/_/g')
  local output_file="$output_dir/${safe_artist} - ${safe_title}"
  local extension="flac"
  if [[ "$service" == "soundcloud" ]]; then
    extension="mp3"
  fi
  
  curl -s "https://$server_name.lucida.to/api/fetch/request/$request_id/download" \
    -H "Origin: https://lucida.to" \
    -o "${output_file}.${extension}"
  
  if [[ $? -eq 0 && -f "${output_file}.${extension}" && -s "${output_file}.${extension}" ]]; then
    echo "INFO: Successfully downloaded to ${output_file}.${extension}" >&2
    echo "{\"path\":\"${output_file}.${extension}\",\"artist\":\"$artist\",\"title\":\"$title\",\"service\":\"$service\"}"
    return 0
  else
    echo "ERROR: Failed to download file" >&2
    return 1
  fi
}

rip_track() {
  local spotify_url="$1"
  local output_dir="$2"
  
  if [[ -z "$spotify_url" ]]; then
    echo "ERROR: Spotify track URL is required" >&2
    usage
    return 1
  fi
  
  if [[ -z "$output_dir" ]]; then
    echo "ERROR: Output directory is required" >&2
    usage
    return 1
  fi
  
  mkdir -p "$output_dir"
  
  echo "INFO: Getting track info from Spotify..." >&2
  local track_id=$(echo "$spotify_url" | grep -o 'track/[a-zA-Z0-9]*' | cut -d'/' -f2)
  
  if [[ -z "$track_id" ]]; then
    echo "ERROR: Invalid Spotify track URL: $spotify_url" >&2
    return 1
  fi
  
  if [[ -n "$SPOTIFY_CLIENT_ID" && -n "$SPOTIFY_CLIENT_SECRET" ]]; then
    echo "DEBUG: Using Spotify credentials from environment variables" >&2
  else
    if [[ -f "$CONFIG_DIR/secrets.conf" ]]; then
      source "$CONFIG_DIR/secrets.conf"
      echo "DEBUG: Using Spotify credentials from config: ID=$SPOTIFY_CLIENT_ID" >&2
    else
      echo "ERROR: Spotify credentials not found in environment or secrets file" >&2
      return 1
    fi
  fi
  
  local token_response=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=$SPOTIFY_CLIENT_ID&client_secret=$SPOTIFY_CLIENT_SECRET")
  
  local access_token=$(json_extract "$token_response" "access_token")
  
  if [[ -z "$access_token" ]]; then
    echo "ERROR: Failed to get Spotify access token. Response: $token_response" >&2
    return 1
  fi
  
  local track_info=$(curl -s -X GET "https://api.spotify.com/v1/tracks/$track_id" \
    -H "Authorization: Bearer $access_token")
  
  local artist=""
  local title=""
  
  if command -v jq >/dev/null 2>&1; then
    artist=$(echo "$track_info" | jq -r '.artists[0].name')
    title=$(echo "$track_info" | jq -r '.name')
  else
    artist=$(echo "$track_info" | sed -n 's/.*"artists":\[{".*"name":"\([^"]*\)".*/\1/p')
    title=$(echo "$track_info" | sed -n 's/.*"name":"\([^"]*\)","popularity".*/\1/p')
    
    if [[ -z "$title" ]]; then
      title=$(echo "$track_info" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)
    fi
  fi
  
  if [[ -z "$artist" || -z "$title" ]]; then
    echo "ERROR: Failed to extract artist or title from Spotify API response" >&2
    echo "DEBUG: Spotify API response: $track_info" >&2
    return 1
  fi
  
  echo "INFO: Found track: $artist - $title" >&2
  
  local result=""
  local max_tidal_retries=10
  local tidal_retry_delay=30
  
  result=$(download_from_service "$spotify_url" "$output_dir" "qobuz" "$artist" "$title" "1")
  if [[ $? -eq 0 && -n "$result" ]]; then
    echo "$result"
    return 0
  fi
  
  for ((retry=1; retry<=max_tidal_retries; retry++)); do
    result=$(download_from_service "$spotify_url" "$output_dir" "tidal" "$artist" "$title" "$retry")
    if [[ $? -eq 0 && -n "$result" ]]; then
      echo "$result"
      return 0
    fi
    
    if [[ $retry -lt $max_tidal_retries ]]; then
      echo "INFO: Tidal download failed, retrying in $tidal_retry_delay seconds..." >&2
      sleep $tidal_retry_delay
    fi
  done
  
  echo "INFO: All Tidal attempts failed, trying SoundCloud as last resort" >&2
  result=$(download_from_service "$spotify_url" "$output_dir" "soundcloud" "$artist" "$title" "1")
  if [[ $? -eq 0 && -n "$result" ]]; then
    echo "$result"
    return 0
  fi
  
  echo "ERROR: Failed to download track from any service" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then
    usage
    exit 1
  fi
  rip_track "$1" "$2"
fi