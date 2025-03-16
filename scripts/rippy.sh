#!/bin/bash


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"

source "$SCRIPT_DIR/utils.sh"

usage() {
  echo "Usage: $0 <spotify_playlist_url> <output_dir>"
  echo
  echo "Sync a Spotify playlist to local AIFF files"
}

get_album_art_url() {
  local track_id="$1"
  load_secrets
  
  local access_token=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=$SPOTIFY_CLIENT_ID&client_secret=$SPOTIFY_CLIENT_SECRET" \
    | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"//;s/"//')
  
  if [[ -z "$access_token" ]]; then
    log_error "Failed to get Spotify access token"
    return 1
  fi
  
  local track_info=$(curl -s -X GET "https://api.spotify.com/v1/tracks/$track_id" \
    -H "Authorization: Bearer $access_token")
  
  local album_art_url=""
  if command -v jq >/dev/null 2>&1; then
    album_art_url=$(echo "$track_info" | jq -r '.album.images[0].url')
  else
    album_art_url=$(echo "$track_info" | sed -n 's/.*"images":\[{"url":"\([^"]*\)".*/\1/p')
  fi
  
  echo "$album_art_url"
}

download_album_art() {
  local url="$1"
  local output_file="$2"
  
  if [[ -z "$url" ]]; then
    log_error "Album art URL is empty"
    return 1
  fi
  
  log_info "Downloading album art from $url"
  curl -s "$url" -o "$output_file"
  
  if [[ $? -ne 0 || ! -s "$output_file" ]]; then
    log_warning "Failed to download album art"
    return 1
  fi
  
  log_info "Album art saved to $output_file"
  return 0
}

process_track() {
  local track_url="$1"
  local output_dir="$2"

  local track_id=$(echo "$track_url" | grep -o 'track/[a-zA-Z0-9]*' | cut -d'/' -f2)
  
  if [[ -z "$track_id" ]]; then
    log_error "Invalid Spotify track URL: $track_url"
    return 1
  fi
  
  log_info "Getting album art for track $track_id"
  local album_art_url=$(get_album_art_url "$track_id")

  log_info "Ripping track: $track_url"
  local rip_result=$("$SCRIPT_DIR/rip.sh" "$track_url" "$output_dir")
  
  if [[ $? -ne 0 ]]; then
    log_error "Failed to rip track: $track_url"
    return 1
  fi
  
  local track_path=$(echo "$rip_result" | grep -o '"path":"[^"]*"' | sed 's/"path":"//;s/"//')
  local service=$(echo "$rip_result" | grep -o '"service":"[^"]*"' | sed 's/"service":"//;s/"//')
  
  if [[ -z "$track_path" ]]; then
    log_error "Failed to get track path from rip result"
    return 1
  fi
  
  local art_file="${track_path%.*}_cover.jpg"
  download_album_art "$album_art_url" "$art_file"
  
  # process
  log_info "Processing track: $track_path"
  local process_result=$("$SCRIPT_DIR/processor.sh" "$track_path" "$art_file" "$service")
  
  if [[ $? -ne 0 ]]; then
    log_error "Failed to process track: $track_path"
    return 1
  fi
  
  if [[ -f "$art_file" && "$KEEP_ARTWORK" != "true" ]]; then
    rm -f "$art_file"
  fi
  
  log_info "Successfully processed track: $track_url"
  return 0
}

sync_playlist() {
  local playlist_url="$1"
  local output_dir="$2"
  
  log_info "Starting sync for playlist: $playlist_url"

  log_info "Finding differences between Spotify and local files"
  local diff_output=$("$SCRIPT_DIR/diff.sh" "$playlist_url" "$output_dir")
  
  log_info "Processing tracks to download"
  echo "$diff_output" | grep '"action":"download"' | while read -r line; do
    local track_url=$(echo "$line" | grep -o '"url":"[^"]*"' | sed 's/"url":"//;s/"//')
    
    if [[ -n "$track_url" ]]; then
      log_info "Processing track: $track_url"
      process_track "$track_url" "$output_dir"
      
      # sleep
      if [[ -n "$DOWNLOAD_INTERVAL" && "$DOWNLOAD_INTERVAL" -gt 0 ]]; then
        log_info "Sleeping for $DOWNLOAD_INTERVAL seconds before next download"
        sleep "$DOWNLOAD_INTERVAL"
      fi
    fi
  done
  
  # delete tracks
  log_info "Processing tracks to delete"
  echo "$diff_output" | grep '"action":"delete"' | while read -r line; do
    local file_path=$(echo "$line" | grep -o '"file":"[^"]*"' | sed 's/"file":"//;s/"//')
    
    if [[ -n "$file_path" ]]; then
      log_info "Deleting file: $file_path"
      rm -f "$output_dir/$file_path".*
    fi
  done
  
  log_info "Sync completed for playlist: $playlist_url"
}

# Load configuration
load_config() {
  if [[ -f "$CONFIG_DIR/rippy.conf" ]]; then
    source "$CONFIG_DIR/rippy.conf"
  fi

  SYNC_INTERVAL=${SYNC_INTERVAL:-3600}      # Default 1 hour
  DOWNLOAD_INTERVAL=${DOWNLOAD_INTERVAL:-0} # Default no delay
  KEEP_ARTWORK=${KEEP_ARTWORK:-false}       # Default don't keep artwork
}

# Load secrets
load_secrets() {
  if [[ -n "$SPOTIFY_CLIENT_ID" && -n "$SPOTIFY_CLIENT_SECRET" ]]; then
    return 0
  fi
  
  if [[ -f "$CONFIG_DIR/secrets.conf" ]]; then
    source "$CONFIG_DIR/secrets.conf"
  else
    log_error "Spotify credentials not found in environment or secrets file"
    exit 1
  fi
}

main() {
  load_config
  
  if [[ $# -lt 2 ]]; then
    usage
    exit 1
  fi
  
  local PLAYLIST_URL="$1"
  local OUTPUT_DIR="$2"
  
  mkdir -p "$OUTPUT_DIR"
  log_info "Starting in daemon mode, syncing every $SYNC_INTERVAL seconds"
  
  while true; do
    sync_playlist "$PLAYLIST_URL" "$OUTPUT_DIR"
    log_info "Sleeping for $SYNC_INTERVAL seconds until next sync"
    sleep "$SYNC_INTERVAL"
  done
}

main "$@"