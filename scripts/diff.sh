#!/bin/bash

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to show usage
usage() {
  echo "Usage: $0 <spotify_playlist_url> <output_folder>"
  echo
  echo "Compare Spotify playlist tracks with local files and identify differences"
  echo
  echo "Arguments:"
  echo "  spotify_playlist_url  URL of the Spotify playlist to compare"
  echo "  output_folder         Local folder containing audio files"
  echo
  echo "Output:"
  echo "  JSON Lines format with 'action' field indicating 'download' or 'delete'"
}

normalize_filename() {
  local artist="$1"
  local title="$2"
  local filename=$(echo "${artist} - ${title}" | tr '[:upper:]' '[:lower:]')
  
  filename=$(echo "$filename" | sed -e 's/[^a-z0-9 ]//g')
  filename=$(echo "$filename" | sed -e 's/[[:space:]]\+/ /g')
  filename=$(echo "$filename" | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
  
  echo "$filename"
}

get_local_files() {
  local output_folder="$1"
  local local_files=()
  
  if [[ ! -d "$output_folder" ]]; then
    echo "WARNING: Output folder does not exist: $output_folder" >&2
    return
  fi
  
  echo "DEBUG: Looking for .wav and .aiff files in $output_folder" >&2
  
  while IFS= read -r file; do
    local filename=$(basename "$file")
    local basename="${filename%.*}"
    local_files+=("$basename")
    echo "DEBUG: Found local file: $basename" >&2
  done < <(find "$output_folder" -type f \( -name "*.wav" -o -name "*.aiff" \) | sort)
  
  if [[ ${#local_files[@]} -eq 0 ]]; then
    echo "WARNING: No audio files found in $output_folder" >&2
  else
    echo "DEBUG: Found ${#local_files[@]} local audio files" >&2
  fi
  
  printf '%s\n' "${local_files[@]}" | jq -R . | jq -s .
}

find_differences() {
  local playlist_url="$1"
  local output_folder="$2"
  
  if [[ -z "$playlist_url" ]]; then
    echo "ERROR: Spotify playlist URL is required" >&2
    usage
    return 1
  fi
  
  if [[ -z "$output_folder" ]]; then
    echo "ERROR: Output folder is required" >&2
    usage
    return 1
  fi
  
  echo "INFO: Getting tracks from Spotify playlist" >&2
  local spotify_tracks=$("$SCRIPT_DIR/spotify.sh" "$playlist_url")
  
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to get Spotify tracks" >&2
    return 1
  fi
  
  echo "INFO: Scanning local files in $output_folder" >&2
  local local_files_json=$(get_local_files "$output_folder")
  
  echo "$spotify_tracks" | while read -r track_json; do
    local id=$(echo "$track_json" | jq -r '.id')
    local name=$(echo "$track_json" | jq -r '.name')
    local artist=$(echo "$track_json" | jq -r '.artist')
    local album=$(echo "$track_json" | jq -r '.album')
    local url=$(echo "$track_json" | jq -r '.url')
    local album_art=$(echo "$track_json" | jq -r '.album_art')
    local norm_filename=$(normalize_filename "$artist" "$name")
    local exists=false
    local temp_file=$(mktemp)

    echo "false" > "$temp_file"
    
    echo "$local_files_json" | jq -r '.[]' | while read -r local_file; do
      local lower_local=$(echo "$local_file" | tr '[:upper:]' '[:lower:]')
      local norm_local=$(echo "$lower_local" | sed -e 's/[^a-z0-9 ]//g' -e 's/[[:space:]]\+/ /g')
      
      if [[ "$norm_local" == "$norm_filename" ]]; then
        echo "DEBUG: EXACT MATCH: $local_file = $artist - $name" >&2
        echo "true" > "$temp_file"
        break
      fi
      
      if [[ "$norm_local" == *"$artist"* && "$norm_local" == *"$name"* ]]; then
        echo "DEBUG: PARTIAL MATCH: $local_file contains $artist and $name" >&2
        echo "true" > "$temp_file"
        break
      fi
      
      local reverse_norm=$(normalize_filename "$name" "$artist")
      if [[ "$norm_local" == *"$reverse_norm"* ]]; then
        echo "DEBUG: REVERSE MATCH: $local_file matches $name - $artist" >&2
        echo "true" > "$temp_file"
        break
      fi
    done
    
    exists=$(cat "$temp_file")
    rm "$temp_file"
    
    if [[ "$exists" == "false" ]]; then
      echo "DEBUG: No match found - marking for download" >&2
      echo "$track_json" | jq -c --arg action "download" '. + {action: $action}'
    else
      echo "DEBUG: Match found - skipping" >&2
    fi
  done
  
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then
    usage
    exit 1
  fi
  
  find_differences "$1" "$2"
fi