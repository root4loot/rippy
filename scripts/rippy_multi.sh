#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"

# Default values
SYNC_INTERVAL=${SYNC_INTERVAL:-300}  # 5 minutes
DOWNLOAD_INTERVAL=${DOWNLOAD_INTERVAL:-30}  # 30 seconds
KEEP_ARTWORK=${KEEP_ARTWORK:-false}

load_secrets() {
  # Try to load from .env file first
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    source "$ROOT_DIR/.env"
    set +a
  fi

  if [[ -z "$SPOTIFY_CLIENT_ID" || -z "$SPOTIFY_CLIENT_SECRET" ]]; then
    log_error "Spotify credentials not found!"
    log_info "Please provide credentials via:"
    log_info "  - SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET environment variables"
    log_info "  - .env file in project root"
    log_info "  - --client-id and --client-secret command line arguments"
    exit 1
  fi
}

get_album_art_url() {
  local track_id="$1"

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

get_soundcloud_artwork_url() {
  local track_url="$1"

  # Use Python script to get artwork URL from SoundCloud API
  local artwork_url=$(python3 "$SCRIPT_DIR/get_soundcloud_artwork.py" "$track_url" 2>/dev/null)

  if [[ -n "$artwork_url" && "$artwork_url" != "null" ]]; then
    echo "$artwork_url"
  fi
}

download_album_art() {
  local url="$1"
  local output_file="$2"

  if [[ -z "$url" ]]; then
    return 1
  fi

  curl -s "$url" -o "$output_file"

  if [[ $? -ne 0 || ! -s "$output_file" ]]; then
    return 1
  fi

  return 0
}

process_spotify_track() {
  local track_url="$1"
  local output_dir="$2"
  local playlist_name="$3"

  local track_id=$(echo "$track_url" | grep -o 'track/[a-zA-Z0-9]*' | cut -d'/' -f2)

  if [[ -z "$track_id" ]]; then
    log_error "[$playlist_name] Invalid Spotify track URL: $track_url"
    return 1
  fi

  log_info "[$playlist_name] Getting album art for track $track_id"
  local album_art_url=$(get_album_art_url "$track_id")

  log_info "[$playlist_name] Ripping track: $track_url"
  local rip_result=$("$SCRIPT_DIR/rip.sh" "$track_url" "$output_dir" 2>&1)

  # Extract the JSON result from the output
  local json_result=$(echo "$rip_result" | grep '^{' | tail -1)

  if [[ -z "$json_result" ]]; then
    log_error "[$playlist_name] Failed to rip track: $track_url"
    return 1
  fi

  local track_path=$(echo "$json_result" | jq -r '.path' 2>/dev/null)
  local service=$(echo "$json_result" | jq -r '.service' 2>/dev/null)

  if [[ -z "$track_path" ]]; then
    log_error "[$playlist_name] Failed to get track path from rip result"
    return 1
  fi

  local art_file="${track_path%.*}_cover.jpg"
  download_album_art "$album_art_url" "$art_file"

  log_info "[$playlist_name] Processing track: $track_path"
  local process_result=$("$SCRIPT_DIR/processor.sh" "$track_path" "$art_file" "$service" 2>&1)

  if [[ $? -ne 0 ]]; then
    log_error "[$playlist_name] Failed to process track: $track_path"
    return 1
  fi

  if [[ -f "$art_file" && "$KEEP_ARTWORK" != "true" ]]; then
    rm -f "$art_file"
  fi

  log_info "[$playlist_name] Successfully processed track: $track_url"
  return 0
}

process_soundcloud_track() {
  local track_url="$1"
  local output_dir="$2"
  local playlist_name="$3"

  log_info "[$playlist_name] Ripping SoundCloud track via lucida.to: $track_url"

  # Use the existing rip.sh script - it should handle SoundCloud URLs
  local rip_result=$("$SCRIPT_DIR/rip.sh" "$track_url" "$output_dir" 2>&1)

  # Extract the JSON result from the output
  local json_result=$(echo "$rip_result" | grep '^{' | tail -1)

  if [[ -z "$json_result" ]]; then
    log_error "[$playlist_name] Failed to rip SoundCloud track: $track_url"
    return 1
  fi

  local track_path=$(echo "$json_result" | jq -r '.path' 2>/dev/null)
  local service=$(echo "$json_result" | jq -r '.service' 2>/dev/null)

  if [[ -z "$track_path" ]]; then
    log_error "[$playlist_name] Failed to get track path from rip result"
    return 1
  fi

  # Get SoundCloud artwork just like Spotify
  log_info "[$playlist_name] Getting album art for SoundCloud track"
  local album_art_url=$(get_soundcloud_artwork_url "$track_url")

  local art_file="${track_path%.*}_cover.jpg"
  download_album_art "$album_art_url" "$art_file"

  log_info "[$playlist_name] Processing track: $track_path"
  local process_result=$("$SCRIPT_DIR/processor.sh" "$track_path" "$art_file" "$service" 2>&1)

  if [[ $? -ne 0 ]]; then
    log_error "[$playlist_name] Failed to process track: $track_path"
    log_error "[$playlist_name] Processor output: $process_result"
    return 1
  fi

  # Clean up artwork file if configured to do so
  if [[ -f "$art_file" && "$KEEP_ARTWORK" != "true" ]]; then
    rm -f "$art_file"
  fi

  log_info "[$playlist_name] Successfully processed SoundCloud track: $track_url"
  return 0
}

process_soundcloud_track_with_metadata() {
  local track_url="$1"
  local output_dir="$2"
  local playlist_name="$3"
  local artist="$4"
  local title="$5"

  log_info "[$playlist_name] Ripping SoundCloud track via lucida.to: $artist - $title"

  # Use the existing rip.sh script - it should handle SoundCloud URLs
  local rip_result=$("$SCRIPT_DIR/rip.sh" "$track_url" "$output_dir" 2>&1)

  # Extract the JSON result from the output
  local json_result=$(echo "$rip_result" | grep '^{' | tail -1)

  if [[ -z "$json_result" ]]; then
    log_error "[$playlist_name] Failed to rip SoundCloud track: $track_url"
    return 1
  fi

  local track_path=$(echo "$json_result" | jq -r '.path' 2>/dev/null)
  local service=$(echo "$json_result" | jq -r '.service' 2>/dev/null)

  if [[ -z "$track_path" ]]; then
    log_error "[$playlist_name] Failed to get track path from rip result"
    return 1
  fi

  # Get SoundCloud artwork just like Spotify
  log_info "[$playlist_name] Getting album art for SoundCloud track"
  local album_art_url=$(get_soundcloud_artwork_url "$track_url")

  local art_file="${track_path%.*}_cover.jpg"
  download_album_art "$album_art_url" "$art_file"

  log_info "[$playlist_name] Processing track: $track_path"
  local process_result=$("$SCRIPT_DIR/processor.sh" "$track_path" "$art_file" "$service" 2>&1)

  if [[ $? -ne 0 ]]; then
    log_error "[$playlist_name] Failed to process track: $track_path"
    log_error "[$playlist_name] Processor output: $process_result"
    return 1
  fi

  # Clean up artwork file if configured to do so
  if [[ -f "$art_file" && "$KEEP_ARTWORK" != "true" ]]; then
    rm -f "$art_file"
  fi

  log_info "[$playlist_name] Successfully processed SoundCloud track: $artist - $title"
  return 0
}

process_track() {
  local track_url="$1"
  local output_dir="$2"
  local playlist_name="$3"

  # Detect track type and call appropriate function
  if [[ "$track_url" == *"open.spotify.com/track"* ]]; then
    process_spotify_track "$track_url" "$output_dir" "$playlist_name"
  elif [[ "$track_url" == *"soundcloud.com"* ]]; then
    process_soundcloud_track "$track_url" "$output_dir" "$playlist_name"
  else
    log_error "[$playlist_name] Unsupported track URL: $track_url"
    return 1
  fi
}

sync_spotify_playlist() {
  local name="$1"
  local playlist_url="$2"
  local output_dir="$3"

  log_info "[$name] Finding differences between Spotify and local files"
  local diff_output=$("$SCRIPT_DIR/diff.sh" "$playlist_url" "$output_dir" 2>&1)

  local tracks_to_download=$(echo "$diff_output" | grep '"action":"download"')
  local download_count=$(echo "$tracks_to_download" | grep -c '"action":"download"' || echo "0")

  if [[ "$download_count" -gt 0 ]]; then
    log_info "[$name] Found $download_count tracks to download"

    local current=0
    echo "$tracks_to_download" | while read -r line; do
      ((current++))
      local track_url=$(echo "$line" | grep -o '"url":"[^"]*"' | sed 's/"url":"//;s/"//')

      if [[ -n "$track_url" ]]; then
        log_info "[$name] Downloading track $current/$download_count: $track_url"
        process_track "$track_url" "$output_dir" "$name"

        if [[ "$current" -lt "$download_count" && -n "$DOWNLOAD_INTERVAL" && "$DOWNLOAD_INTERVAL" -gt 0 ]]; then
          log_info "[$name] Waiting $DOWNLOAD_INTERVAL seconds before next download..."
          sleep "$DOWNLOAD_INTERVAL"
        fi
      fi
    done
  else
    log_info "[$name] Playlist is up to date - no tracks to download"
  fi

  # Handle deletions
  local tracks_to_delete=$(echo "$diff_output" | grep '"action":"delete"')
  local delete_count=$(echo "$tracks_to_delete" | grep -c '"action":"delete"' || echo "0")

  if [[ "$delete_count" -gt 0 ]]; then
    log_info "[$name] Found $delete_count tracks to delete"
    echo "$tracks_to_delete" | while read -r line; do
      local file_path=$(echo "$line" | grep -o '"file":"[^"]*"' | sed 's/"file":"//;s/"//')
      if [[ -n "$file_path" ]]; then
        log_info "[$name] Deleting file: $file_path"
        rm -f "$output_dir/$file_path".*
      fi
    done
  fi
}

sync_soundcloud_playlist() {
  local name="$1"
  local playlist_url="$2"
  local output_dir="$3"

  log_info "[$name] Finding differences between SoundCloud playlist and local files"

  # Get SoundCloud tracks in same format as Spotify
  local sc_tracks=$(python3 "$SCRIPT_DIR/soundcloud_api.py" "$playlist_url" 2>&1)
  if [[ $? -ne 0 ]]; then
    log_error "[$name] Failed to get SoundCloud playlist tracks"
    return 1
  fi

  # Use same diff logic as Spotify - find files that need downloading
  local local_files=()
  if [[ -d "$output_dir" ]]; then
    while IFS= read -r file; do
      local basename="${file%.*}"
      local_files+=("$basename")
    done < <(find "$output_dir" -type f \( -name "*.wav" -o -name "*.aiff" \) 2>/dev/null | xargs -I {} basename {} | sort)
  fi

  local tracks_to_download=""
  local download_count=0

  # Same diff logic as Spotify but with SoundCloud data
  while read -r track_json; do
    [[ -z "$track_json" || "$track_json" == "null" ]] && continue

    local artist=$(echo "$track_json" | jq -r '.artist')
    local title=$(echo "$track_json" | jq -r '.name')
    local track_url=$(echo "$track_json" | jq -r '.url')

    # Use same normalization as Spotify diff.sh
    local norm_filename=$(echo "${artist} - ${title}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9 ]//g' -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')

    local found=false
    for local_file in "${local_files[@]}"; do
      local norm_local=$(echo "$local_file" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9 ]//g' -e 's/[[:space:]]\+/ /g')

      # Same matching logic as diff.sh
      if [[ "$norm_local" == "$norm_filename" ]] || [[ "$norm_local" == *"$artist"* && "$norm_local" == *"$title"* ]]; then
        found=true
        break
      fi
    done

    if [[ "$found" == "false" ]]; then
      echo "$track_json" | jq -c --arg action "download" '. + {action: $action}'
      ((download_count++))
    fi
  done <<< "$(echo "$sc_tracks" | grep '^{')" > /tmp/sc_tracks_to_download

  local tracks_to_download=$(cat /tmp/sc_tracks_to_download)
  local download_count=$(echo "$tracks_to_download" | grep -c '"action":"download"' || echo "0")

  if [[ "$download_count" -gt 0 ]]; then
    log_info "[$name] Found $download_count tracks to download"

    local current=0
    echo "$tracks_to_download" | while read -r line; do
      ((current++))
      local track_url=$(echo "$line" | jq -r '.url')
      local artist=$(echo "$line" | jq -r '.artist')
      local title=$(echo "$line" | jq -r '.name')

      if [[ -n "$track_url" ]]; then
        log_info "[$name] Downloading track $current/$download_count: $artist - $title"
        process_soundcloud_track_with_metadata "$track_url" "$output_dir" "$name" "$artist" "$title"

        if [[ "$current" -lt "$download_count" && -n "$DOWNLOAD_INTERVAL" && "$DOWNLOAD_INTERVAL" -gt 0 ]]; then
          log_info "[$name] Waiting $DOWNLOAD_INTERVAL seconds before next download..."
          sleep "$DOWNLOAD_INTERVAL"
        fi
      fi
    done
  else
    log_info "[$name] Playlist is up to date - no tracks to download"
  fi

  rm -f /tmp/sc_tracks_to_download
}

sync_playlist() {
  local name="$1"
  local playlist_url="$2"
  local output_dir="$3"

  # Detect playlist type and call appropriate sync function
  if [[ "$playlist_url" == *"open.spotify.com/playlist"* ]]; then
    sync_spotify_playlist "$name" "$playlist_url" "$output_dir"
  elif [[ "$playlist_url" == *"soundcloud.com"* ]] && [[ "$playlist_url" == *"/sets/"* ]]; then
    sync_soundcloud_playlist "$name" "$playlist_url" "$output_dir"
  else
    log_error "[$name] Unsupported playlist URL: $playlist_url"
    return 1
  fi
}

sync_all_playlists() {
  local playlist_file="$1"
  local output_base_dir="$2"

  # Parse playlist file and build arrays
  local -a playlist_names=()
  local -a playlist_urls=()
  local -a playlist_dirs=()

  local count=0
  while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Extract Spotify or SoundCloud URL
    local url=""
    local playlist_id=""
    local service=""

    if [[ "$line" =~ https://open.spotify.com/playlist/ ]]; then
      url=$(echo "$line" | grep -o 'https://open.spotify.com/playlist/[^[:space:]]*' | head -1)
      playlist_id=$(echo "$url" | sed 's|.*/playlist/||;s|?.*||')
      service="spotify"
    elif [[ "$line" =~ https://soundcloud.com/ ]] && [[ "$line" =~ /sets/ ]]; then
      url=$(echo "$line" | grep -o 'https://soundcloud.com/[^[:space:]]*' | head -1)
      # Extract playlist name from SoundCloud URL
      playlist_id=$(echo "$url" | sed 's|.*/sets/||;s|/.*||;s|?.*||')
      service="soundcloud"
    fi

    if [[ -n "$url" ]]; then
      ((count++))
      local name="${service}_${count}"
      # Use the same output directory for all playlists - no subfolders
      local dir="${output_base_dir}"

      playlist_names+=("$name")
      playlist_urls+=("$url")
      playlist_dirs+=("$dir")

      mkdir -p "$dir"
      log_info "Added $name: ${url:0:60}..."
    fi
  done < "$playlist_file"

  if [[ ${#playlist_urls[@]} -eq 0 ]]; then
    log_error "No valid playlist URLs found in $playlist_file"
    exit 1
  fi

  log_info "Syncing ${#playlist_urls[@]} playlists every $SYNC_INTERVAL seconds"
  log_info "Press Ctrl+C to stop"
  echo ""

  # Main sync loop
  while true; do
    log_info "=== Starting sync cycle at $(date '+%Y-%m-%d %H:%M:%S') ==="

    for i in "${!playlist_urls[@]}"; do
      sync_playlist "${playlist_names[$i]}" "${playlist_urls[$i]}" "${playlist_dirs[$i]}"
      echo ""
    done

    log_info "=== Sync cycle completed at $(date '+%Y-%m-%d %H:%M:%S') ==="
    log_info "Sleeping for $SYNC_INTERVAL seconds until next sync..."
    log_info "Press Ctrl+C to stop"
    sleep "$SYNC_INTERVAL"
  done
}

usage() {
  echo "Usage: $0 --playlist-file <file> [options]"
  echo ""
  echo "Options:"
  echo "  --playlist-file <file>     File containing playlist URLs (one per line, # for comments)"
  echo "  --output-dir <dir>         Base output directory (default: $ROOT_DIR/music)"
  echo "  --sync-interval <seconds>  Time between syncs (default: 300)"
  echo "  --download-interval <secs> Time between downloads (default: 30)"
  echo "  --client-id <id>           Spotify client ID"
  echo "  --client-secret <secret>   Spotify client secret"
  echo ""
  echo "Example:"
  echo "  $0 --playlist-file playlists.txt --output-dir /home/user/music"
  echo ""
  echo "Playlist file format:"
  echo "  # Comment lines start with #"
  echo "  https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"
  echo "  https://open.spotify.com/playlist/37i9dQZF1DX0XUsuxWHRQd"
}

# Parse arguments
PLAYLIST_FILE=""
OUTPUT_DIR="$ROOT_DIR/music"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --playlist-file)
      PLAYLIST_FILE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --sync-interval)
      SYNC_INTERVAL="$2"
      shift 2
      ;;
    --download-interval)
      DOWNLOAD_INTERVAL="$2"
      shift 2
      ;;
    --client-id)
      export SPOTIFY_CLIENT_ID="$2"
      shift 2
      ;;
    --client-secret)
      export SPOTIFY_CLIENT_SECRET="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$PLAYLIST_FILE" ]]; then
  echo "Error: --playlist-file is required"
  usage
  exit 1
fi

if [[ ! -f "$PLAYLIST_FILE" ]]; then
  echo "Error: Playlist file not found: $PLAYLIST_FILE"
  exit 1
fi

# Load credentials and start syncing
load_secrets

log_info "Starting multi-playlist sync"
log_info "Playlist file: $PLAYLIST_FILE"
log_info "Output directory: $OUTPUT_DIR"
log_info "Sync interval: $SYNC_INTERVAL seconds"
log_info "Download interval: $DOWNLOAD_INTERVAL seconds"
echo ""

sync_all_playlists "$PLAYLIST_FILE" "$OUTPUT_DIR"