#!/bin/bash

# Logging levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARNING=2
LOG_LEVEL_ERROR=3

CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

log_debug() {
  if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_DEBUG ]]; then
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
  fi
}

log_info() {
  if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_INFO ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
  fi
}

log_warning() {
  if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_WARNING ]]; then
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
  fi
}

log_error() {
  if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_ERROR ]]; then
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
  fi
}

sanitize_filename() {
  local filename="$1"
  
  filename=$(echo "$filename" | sed -e 's/[\/:\*\?"<>\|]/_/g')
  filename=$(echo "$filename" | sed -e 's/[\$]/_/g')
  filename=$(echo "$filename" | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')

  if [[ ${#filename} -gt 255 ]]; then
    filename="${filename:0:255}"
  fi
  
  echo "$filename"
}

normalize_filename() {
  local filename="$1"

  filename=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
  filename=$(echo "$filename" | sed -e 's/[^a-z0-9 ]//g')
  filename=$(echo "$filename" | sed -e 's/[[:space:]]\+/ /g')
  filename=$(echo "$filename" | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
  
  echo "$filename"
}