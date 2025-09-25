#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"

parse_toml() {
    local file="$1"
    local section="$2"
    local key="$3"

    if [[ "$section" == "global" ]]; then
        grep "^${key}" "$file" | head -1 | sed 's/.*= *//; s/"//g; s/#.*//' | xargs
    fi
}

get_playlist_count() {
    local file="$1"
    grep -c '^\[\[playlists\]\]' "$file"
}

get_playlist_config() {
    local file="$1"
    local index="$2"

    awk -v idx="$index" '
        /^\[\[playlists\]\]/ {
            playlist_count++
            if (playlist_count == idx) {
                in_playlist=1
            } else {
                in_playlist=0
            }
            next
        }
        /^\[/ && !/^\[\[/ { in_playlist=0 }
        in_playlist && /^name/ { gsub(/.*= *"?/, ""); gsub(/".*/, ""); name=$0 }
        in_playlist && /^url/ { gsub(/.*= *"?/, ""); gsub(/".*/, ""); url=$0 }
        in_playlist && /^output_dir/ { gsub(/.*= *"?/, ""); gsub(/".*/, ""); output_dir=$0 }
        END {
            if (name && url && output_dir) {
                print name "|" url "|" output_dir
            }
        }
    ' "$file"
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
  local name="$1"
  local playlist_url="$2"
  local output_dir="$3"

  log_info "[$name] Starting sync for playlist: $playlist_url"

  log_info "[$name] Finding differences between Spotify and local files"
  local diff_output=$("$SCRIPT_DIR/diff.sh" "$playlist_url" "$output_dir")

  log_info "[$name] Processing tracks to download"
  echo "$diff_output" | grep '"action":"download"' | while read -r line; do
    local track_url=$(echo "$line" | grep -o '"url":"[^"]*"' | sed 's/"url":"//;s/"//')

    if [[ -n "$track_url" ]]; then
      log_info "[$name] Processing track: $track_url"
      process_track "$track_url" "$output_dir"

      if [[ -n "$DOWNLOAD_INTERVAL" && "$DOWNLOAD_INTERVAL" -gt 0 ]]; then
        log_info "[$name] Sleeping for $DOWNLOAD_INTERVAL seconds before next download"
        sleep "$DOWNLOAD_INTERVAL"
      fi
    fi
  done

  log_info "[$name] Processing tracks to delete"
  echo "$diff_output" | grep '"action":"delete"' | while read -r line; do
    local file_path=$(echo "$line" | grep -o '"file":"[^"]*"' | sed 's/"file":"//;s/"//')

    if [[ -n "$file_path" ]]; then
      log_info "[$name] Deleting file: $file_path"
      rm -f "$output_dir/$file_path".*
    fi
  done

  log_info "[$name] Sync completed for playlist: $playlist_url"
}

load_config_toml() {
    local config_file="$ROOT_DIR/playlists.toml"

    if [[ ! -f "$config_file" ]]; then
        return 1
    fi

    SYNC_INTERVAL=$(parse_toml "$config_file" "global" "sync_interval")
    DOWNLOAD_INTERVAL=$(parse_toml "$config_file" "global" "download_interval")
    KEEP_ARTWORK=$(parse_toml "$config_file" "global" "keep_artwork")
    LOG_LEVEL=$(parse_toml "$config_file" "global" "log_level")

    SYNC_INTERVAL=${SYNC_INTERVAL:-3600}
    DOWNLOAD_INTERVAL=${DOWNLOAD_INTERVAL:-60}
    KEEP_ARTWORK=${KEEP_ARTWORK:-false}
    LOG_LEVEL=${LOG_LEVEL:-INFO}

    export SYNC_INTERVAL
    export DOWNLOAD_INTERVAL
    export KEEP_ARTWORK
    export LOG_LEVEL

    return 0
}

load_config_legacy() {
  if [[ -f "$ROOT_DIR/rippy.conf" ]]; then
    source "$ROOT_DIR/rippy.conf"
  fi

  SYNC_INTERVAL=${SYNC_INTERVAL:-3600}
  DOWNLOAD_INTERVAL=${DOWNLOAD_INTERVAL:-0}
  KEEP_ARTWORK=${KEEP_ARTWORK:-false}
}

load_secrets() {
  if [[ -n "$SPOTIFY_CLIENT_ID" && -n "$SPOTIFY_CLIENT_SECRET" ]]; then
    return 0
  fi

  if [[ -f "$ROOT_DIR/secrets.toml" ]]; then
    SPOTIFY_CLIENT_ID=$(grep '^spotify_client_id' "$ROOT_DIR/secrets.toml" | sed 's/.*= *"//; s/"//')
    SPOTIFY_CLIENT_SECRET=$(grep '^spotify_client_secret' "$ROOT_DIR/secrets.toml" | sed 's/.*= *"//; s/"//')
    export SPOTIFY_CLIENT_ID
    export SPOTIFY_CLIENT_SECRET
  fi

  if [[ -z "$SPOTIFY_CLIENT_ID" || -z "$SPOTIFY_CLIENT_SECRET" ]]; then
    if [[ -f "$ROOT_DIR/secrets.conf" ]]; then
      source "$ROOT_DIR/secrets.conf"
    fi
  fi

  if [[ -z "$SPOTIFY_CLIENT_ID" || -z "$SPOTIFY_CLIENT_SECRET" ]]; then
    log_error "Spotify credentials not found!"
    log_info "Please provide credentials via:"
    log_info "  - SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET environment variables"
    log_info "  - $ROOT_DIR/secrets.toml or secrets.conf files"
    log_info "  - --client-id and --client-secret arguments"
    exit 1
  fi
}

start_playlist_sync() {
    local name="$1"
    local url="$2"
    local output_dir="$3"

    log_info "Starting sync for playlist: $name"
    log_info "  URL: $url"
    log_info "  Output: $output_dir"

    mkdir -p "$output_dir"

    nohup bash -c "
        export SYNC_INTERVAL='$SYNC_INTERVAL'
        export DOWNLOAD_INTERVAL='$DOWNLOAD_INTERVAL'
        export KEEP_ARTWORK='$KEEP_ARTWORK'
        export SPOTIFY_CLIENT_ID='$SPOTIFY_CLIENT_ID'
        export SPOTIFY_CLIENT_SECRET='$SPOTIFY_CLIENT_SECRET'

        source '$SCRIPT_DIR/utils.sh'

        $(declare -f load_secrets)
        $(declare -f get_album_art_url)
        $(declare -f download_album_art)
        $(declare -f process_track)
        $(declare -f sync_playlist)

        while true; do
            sync_playlist '$name' '$url' '$output_dir'
            log_info '[$name] Sleeping for $SYNC_INTERVAL seconds until next sync'
            sleep \$SYNC_INTERVAL
        done
    " > "$ROOT_DIR/logs/${name// /_}.log" 2>&1 &

    local pid=$!
    echo "$pid:$name:$url:$output_dir" >> "$ROOT_DIR/.playlist_pids"
    log_info "Started playlist sync with PID: $pid"
}

stop_all_syncs() {
    if [[ ! -f "$ROOT_DIR/.playlist_pids" ]]; then
        log_info "No running playlist syncs found"
        return 0
    fi

    log_info "Stopping all playlist syncs..."
    while IFS=':' read -r pid name url output_dir; do
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping playlist sync: $name (PID: $pid)"
            kill "$pid"
        fi
    done < "$ROOT_DIR/.playlist_pids"

    rm -f "$ROOT_DIR/.playlist_pids"
    log_info "All playlist syncs stopped"
}

show_status() {
    if [[ ! -f "$ROOT_DIR/.playlist_pids" ]]; then
        log_info "No running playlist syncs found"
        return 0
    fi

    echo "Active Playlist Syncs:"
    echo "----------------------"
    while IFS=':' read -r pid name url output_dir; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "✓ $name (PID: $pid)"
            echo "  URL: $url"
            echo "  Output: $output_dir"
            echo ""
        else
            echo "✗ $name (PID: $pid) - Not running"
            echo ""
        fi
    done < "$ROOT_DIR/.playlist_pids"
}

run_single_playlist() {
    local url="$1"
    local output_dir="$2"

    load_config_legacy
    load_secrets

    mkdir -p "$output_dir"
    log_info "Starting in daemon mode, syncing every $SYNC_INTERVAL seconds"

    while true; do
        sync_playlist "Single" "$url" "$output_dir"
        log_info "Sleeping for $SYNC_INTERVAL seconds until next sync"
        sleep "$SYNC_INTERVAL"
    done
}

run_from_playlist_file() {
    local playlist_file="$1"
    local output_base_dir="${2:-$ROOT_DIR/music}"

    if [[ ! -f "$playlist_file" ]]; then
        log_error "Playlist file not found: $playlist_file"
        exit 1
    fi

    load_config_legacy
    load_secrets

    # Override with command line options if provided
    SYNC_INTERVAL=${SYNC_INTERVAL:-300}  # Default 5 minutes between syncs
    DOWNLOAD_INTERVAL=${DOWNLOAD_INTERVAL:-30}  # Default 30 seconds between downloads

    log_info "Starting multi-playlist sync from file: $playlist_file"
    log_info "Output directory: $output_base_dir"
    log_info "Sync interval: $SYNC_INTERVAL seconds"
    log_info "Download interval: $DOWNLOAD_INTERVAL seconds"

    mkdir -p "$ROOT_DIR/logs"
    mkdir -p "$output_base_dir"

    # Stop any existing syncs
    stop_all_syncs

    local playlist_count=0
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Extract just the URL (remove any whitespace)
        local url=$(echo "$line" | grep -o 'https://open.spotify.com/playlist/[^[:space:]]*' | head -1)

        if [[ -n "$url" ]]; then
            ((playlist_count++))
            local playlist_id=$(echo "$url" | sed 's|.*/playlist/||;s|?.*||')
            local playlist_name="playlist_${playlist_count}_${playlist_id:0:8}"
            local output_dir="${output_base_dir}/${playlist_name}"

            log_info "Starting sync for playlist #${playlist_count}: $url"
            start_playlist_sync "$playlist_name" "$url" "$output_dir"
            sleep 2
        fi
    done < "$playlist_file"

    if [[ $playlist_count -eq 0 ]]; then
        log_error "No valid playlist URLs found in $playlist_file"
        exit 1
    fi

    log_info "Started $playlist_count playlist syncs"
    log_info "Use '$0 status' to check status"
    log_info "Use '$0 stop' to stop all syncs"
    log_info "Logs are available in: $ROOT_DIR/logs/"
}

run_multiple_playlists() {
    local command="${1:-start}"

    case "$command" in
        start)
            load_config_toml
            load_secrets

            mkdir -p "$ROOT_DIR/logs"
            stop_all_syncs

            local config_file="$ROOT_DIR/playlists.toml"
            local playlist_count=$(get_playlist_count "$config_file")

            log_info "Found $playlist_count playlists in configuration"

            for i in $(seq 1 "$playlist_count"); do
                local config=$(get_playlist_config "$config_file" "$i")
                if [[ -n "$config" ]]; then
                    IFS='|' read -r name url output_dir <<< "$config"
                    start_playlist_sync "$name" "$url" "$output_dir"
                    sleep 2
                fi
            done

            log_info "All playlist syncs started successfully"
            log_info "Use '$0 status' to check status"
            log_info "Use '$0 stop' to stop all syncs"
            log_info "Logs are available in: $ROOT_DIR/logs/"
            ;;

        stop)
            stop_all_syncs
            ;;

        status)
            show_status
            ;;

        restart)
            stop_all_syncs
            sleep 2
            run_multiple_playlists start
            ;;

        *)
            echo "Usage: $0 {start|stop|status|restart}"
            echo "       $0 \"[spotify-playlist-url]\" [output-dir] [options]"
            echo "       $0 --playlist-file [file] --output-dir [dir] [options]"
            echo ""
            echo "Multi-playlist from file:"
            echo "  --playlist-file [file]     File containing playlist URLs (one per line, # for comments)"
            echo "  --output-dir [dir]         Base output directory for all playlists"
            echo "  --sync-interval [seconds]  Time between playlist syncs (default: 300)"
            echo "  --download-interval [secs] Time between track downloads (default: 30)"
            echo ""
            echo "Multi-playlist commands:"
            echo "  start   - Start syncing all playlists defined in playlists.toml"
            echo "  stop    - Stop all running playlist syncs"
            echo "  status  - Show status of all running syncs"
            echo "  restart - Restart all playlist syncs"
            echo ""
            echo "Single playlist mode:"
            echo "  $0 \"[spotify-playlist-url]\" [output-dir]"
            echo "  $0 \"[spotify-playlist-url]\" [output-dir] --client-id [id] --client-secret [secret]"
            echo ""
            echo "Environment variables:"
            echo "  SPOTIFY_CLIENT_ID     - Spotify app client ID"
            echo "  SPOTIFY_CLIENT_SECRET - Spotify app client secret"
            exit 1
            ;;
    esac
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --client-id)
                export SPOTIFY_CLIENT_ID="$2"
                shift 2
                ;;
            --client-secret)
                export SPOTIFY_CLIENT_SECRET="$2"
                shift 2
                ;;
            --playlist-file)
                export PLAYLIST_FILE="$2"
                shift 2
                ;;
            --output-dir)
                export OUTPUT_DIR="$2"
                shift 2
                ;;
            --sync-interval)
                export SYNC_INTERVAL="$2"
                shift 2
                ;;
            --download-interval)
                export DOWNLOAD_INTERVAL="$2"
                shift 2
                ;;
            *)
                ARGS+=("$1")
                shift
                ;;
        esac
    done
}

main() {
    ARGS=()
    parse_arguments "$@"
    set -- "${ARGS[@]}"

    # If --playlist-file was specified, use that
    if [[ -n "$PLAYLIST_FILE" ]]; then
        OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/music"}
        run_from_playlist_file "$PLAYLIST_FILE" "$OUTPUT_DIR"
    elif [[ -f "$ROOT_DIR/playlists.toml" ]] && [[ $# -eq 0 || "$1" =~ ^(start|stop|status|restart)$ ]]; then
        run_multiple_playlists "$@"
    elif [[ $# -ge 2 ]] && [[ "$1" =~ ^https://open.spotify.com/playlist/ ]]; then
        run_single_playlist "$1" "$2"
    else
        run_multiple_playlists help
    fi
}

main "$@"