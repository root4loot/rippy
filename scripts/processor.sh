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
  local compressed_file=""
  
  if [[ -n "$artwork_file" && -f "$artwork_file" ]]; then
    temp_art_file="${dir_name}/temp_art_$$.jpg"
    
    # Redirect both stdout and stderr to /dev/null to suppress warnings
    ffmpeg -y -i "$artwork_file" -vf "scale=min(800,iw):min(800,ih):force_original_aspect_ratio=decrease" "$temp_art_file" >/dev/null 2>&1
    
    local art_size=$(du -k "$temp_art_file" | cut -f1)
    if [[ $art_size -gt 500 ]]; then
      echo "INFO: Compressing album art to meet CDJ requirements" >&2
      compressed_file="${dir_name}/temp_art_compressed_$$.jpg"
      
      for quality in 95 90 85 80 75 70; do
        ffmpeg -y -i "$temp_art_file" -q:v $((30-$quality/5)) "$compressed_file" >/dev/null 2>&1
        local new_size=$(du -k "$compressed_file" | cut -f1)
        
        if [[ $new_size -le 500 ]]; then
          mv "$compressed_file" "$temp_art_file"
          break
        fi
      done
      
      if [[ $(du -k "$temp_art_file" | cut -f1) -gt 500 ]]; then
        ffmpeg -y -i "$artwork_file" -vf "scale=800:800:force_original_aspect_ratio=decrease" -q:v 10 "$compressed_file" >/dev/null 2>&1
        mv "$compressed_file" "$temp_art_file"
      fi
      
      if [[ -f "$compressed_file" ]]; then
        rm -f "$compressed_file"
      fi
    fi
    
    artwork_file="$temp_art_file"
  fi

  trap 'rm -f "$temp_art_file" "$compressed_file"' EXIT

  local ffmpeg_cmd="ffmpeg -nostdin -i \"$input_file\""
  
  if [[ -n "$artwork_file" && -f "$artwork_file" ]]; then
    echo "INFO: Including album art from $artwork_file" >&2
    ffmpeg_cmd+=" -i \"$artwork_file\""
    ffmpeg_cmd+=" -map 0:a -map 1:v"
    ffmpeg_cmd+=" -id3v2_version 3"
    ffmpeg_cmd+=" -disposition:v attached_pic"
  fi
  
  ffmpeg_cmd+=" -ar 44100"
  ffmpeg_cmd+=" -c:a pcm_s16be"
  ffmpeg_cmd+=" -write_id3v2 1"
  ffmpeg_cmd+=" -metadata comment=\"\" -metadata ICMT=\"\""

  ffmpeg_cmd+=" -loglevel error -nostats -y \"$output_file\""
  
  echo "INFO: Executing command: $ffmpeg_cmd" >&2
  eval "$ffmpeg_cmd" 2>/tmp/ffmpeg_error.log
  
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: ffmpeg command failed with exit code $exit_code" >&2
    echo "ERROR: ffmpeg error log:" >&2
    cat /tmp/ffmpeg_error.log >&2
    rm -f /tmp/ffmpeg_error.log
    return $exit_code
  fi
  
  rm -f /tmp/ffmpeg_error.log
  
  echo "INFO: Successfully converted to AIFF format: $output_file" >&2
  
  if [[ "$input_file" != "$output_file" ]]; then
    echo "INFO: Removing original file: $input_file" >&2
    rm -f "$input_file"
  fi
  
  # Clean up temporary files
  if [[ -n "$temp_art_file" && -f "$temp_art_file" ]]; then
    rm -f "$temp_art_file"
  fi
  
  if [[ -n "$compressed_file" && -f "$compressed_file" ]]; then
    rm -f "$compressed_file"
  fi
  
  # Remove trap since we've manually cleaned up
  trap - EXIT
  
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