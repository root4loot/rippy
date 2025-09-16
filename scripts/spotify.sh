#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$ROOT_DIR/secrets.conf"

load_spotify_secrets() {
  if [[ -n "$SPOTIFY_CLIENT_ID" && -n "$SPOTIFY_CLIENT_SECRET" ]]; then
    return 0
  fi

  if [[ -f "$SECRETS_FILE" ]]; then
    source "$SECRETS_FILE"
  else
    echo "ERROR: Spotify credentials not found in environment or secrets file" >&2
    return 1
  fi
}

spotify_auth() {
  load_spotify_secrets || return 1
  
  local client_id="$SPOTIFY_CLIENT_ID"
  local client_secret="$SPOTIFY_CLIENT_SECRET"
  
  if [[ -z "$client_id" || -z "$client_secret" ]]; then
    echo "ERROR: Spotify client ID or secret is missing in secrets configuration" >&2
    return 1
  fi
  
  echo "DEBUG: Authenticating with Spotify API" >&2
  
  local auth_response=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=$client_id&client_secret=$client_secret")
  
  local access_token=$(echo "$auth_response" | jq -r '.access_token')
  
  if [[ "$access_token" == "null" || -z "$access_token" ]]; then
    echo "ERROR: Failed to get Spotify access token: $(echo "$auth_response" | jq -r '.error_description // "Unknown error"')" >&2
    return 1
  fi
  
  echo "$access_token"
}

get_playlist_id() {
  local playlist_url="$1"
  local playlist_id=$(echo "$playlist_url" | grep -oE 'playlist/([a-zA-Z0-9]+)' | cut -d'/' -f2)
  
  if [[ -z "$playlist_id" ]]; then
    echo "ERROR: Invalid Spotify playlist URL: $playlist_url" >&2
    return 1
  fi
  
  echo "$playlist_id"
}

get_spotify_playlist_tracks() {
  local playlist_url="$1"
  local playlist_id=$(get_playlist_id "$playlist_url")
  
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  
  local access_token=$(spotify_auth)
  
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  
  echo "INFO: Fetching playlist tracks from Spotify (ID: $playlist_id)" >&2
  
  local track_count=0
  local next_url="https://api.spotify.com/v1/playlists/$playlist_id/tracks?limit=100"
  
  while [[ "$next_url" != "null" && -n "$next_url" ]]; do
    local response=$(curl -s -X GET "$next_url" \
      -H "Authorization: Bearer $access_token")
    
    if echo "$response" | jq -e '.error' > /dev/null; then
      echo "ERROR: Spotify API error: $(echo "$response" | jq -r '.error.message')" >&2
      return 1
    fi
    
    local items_count=$(echo "$response" | jq '.items | length')
    
    for ((i=0; i<$items_count; i++)); do
      local track_info=$(echo "$response" | jq -c ".items[$i].track")
      
      if [[ "$track_info" == "null" ]]; then
        continue
      fi
      
      local track_id=$(echo "$track_info" | jq -r '.id')
      local track_name=$(echo "$track_info" | jq -r '.name')
      local artist_name=$(echo "$track_info" | jq -r '.artists[0].name')
      local album_name=$(echo "$track_info" | jq -r '.album.name')
      local album_art="null"
      
      if echo "$track_info" | jq -e '.album.images | length > 0' > /dev/null; then
        album_art=$(echo "$track_info" | jq -r '.album.images[0].url')
      fi
      
      local track_url=$(echo "$track_info" | jq -r '.external_urls.spotify')
      
      jq -c -n \
        --arg id "$track_id" \
        --arg name "$track_name" \
        --arg artist "$artist_name" \
        --arg album "$album_name" \
        --arg album_art "$album_art" \
        --arg url "$track_url" \
        '{id: $id, name: $name, artist: $artist, album: $album, album_art: $album_art, url: $url}'
      
      ((track_count++))
    done
    
    next_url=$(echo "$response" | jq -r '.next')
  done
  
  echo "INFO: Found $track_count tracks in playlist" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -ge 1 ]]; then
    get_spotify_playlist_tracks "$1"
  else
    echo "Usage: $0 <spotify_playlist_url>"
    exit 1
  fi
fi