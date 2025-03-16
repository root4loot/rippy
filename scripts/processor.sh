#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <input_file> [album_art_file] [service]"
  echo
  echo "Convert audio file to AIFF format and embed album art"
  echo
  echo "Arguments:"
  echo "  input_file       Path to the input audio file (FLAC or MP3)"
  echo "  album_art_file   Path to the album art image file (optional)"
  echo "  service          Source service (tidal, qobuz, soundcloud) (optional)"
}

process_track() {
  local input_file="$1"
  local artwork_file="$2"
  local service="$3"
  
  if [[ -z "$input_file" ]]; then
    echo "ERROR: Input file is required" >&2
    usage
    return 1
  fi
  
  if [[ ! -f "$input_file" ]]; then
    echo "ERROR: Input file does not exist: $input_file" >&2
    return 1
  fi
  
  echo "INFO: Converting $input_file to AIFF format" >&2
  
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg is required but not installed" >&2
    return 1
  fi
  
  local dir_name=$(dirname "$input_file")
  local base_name=$(basename "$input_file" | sed 's/\.[^.]*$//')
  local output_file="${dir_name}/${base_name}.aiff"
  
  local temp_art_file=""
  if [[ -n "$artwork_file" && -f "$artwork_file" ]]; then
    temp_art_file="${dir_name}/temp_art_$$.jpg"
    ffmpeg -y -i "$artwork_file" -vf "scale=500:500" "$temp_art_file" >/dev/null 2>&1
    artwork_file="$temp_art_file"
  fi

  local ffmpeg_cmd="ffmpeg -i \"$input_file\""
  
  if [[ -n "$artwork_file" && -f "$artwork_file" ]]; then
    echo "INFO: Including album art from $artwork_file" >&2
    ffmpeg_cmd+=" -i \"$artwork_file\""
    ffmpeg_cmd+=" -map 0:a -map 1:v"
    ffmpeg_cmd+=" -id3v2_version 3"
    ffmpeg_cmd+=" -disposition:v attached_pic"
  fi
  
  ffmpeg_cmd+=" -c:a pcm_s16be"
  # ffmpeg_cmd+=" -ar 44100 -ac 2" # Ensure 44.1kHz 16-bit stereo
  ffmpeg_cmd+=" -write_id3v2 1"
  ffmpeg_cmd+=" -metadata comment=\"\" -metadata ICMT=\"\""
  
  if [[ -n "$service" ]]; then
    ffmpeg_cmd+=" -metadata source=\"$service\""
  fi
  
  ffmpeg_cmd+=" -y \"$output_file\""
  
  echo "INFO: Executing command: $ffmpeg_cmd" >&2

  eval "$ffmpeg_cmd"
  
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: ffmpeg command failed with exit code $exit_code" >&2
    return $exit_code
  fi
  
  echo "INFO: Successfully converted to AIFF format: $output_file" >&2
  
  if [[ "$input_file" != "$output_file" ]]; then
    echo "INFO: Removing original file: $input_file" >&2
    rm -f "$input_file"
  fi
  
  if [[ -n "$temp_art_file" && -f "$temp_art_file" ]]; then
    rm -f "$temp_art_file"
  fi
  
  echo "{\"path\":\"$output_file\"}"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi
  
  if [[ $# -eq 1 ]]; then
    process_track "$1" "" ""
  elif [[ $# -eq 2 ]]; then
    process_track "$1" "$2" ""
  else
    process_track "$1" "$2" "$3"
  fi
fi