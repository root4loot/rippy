#!/usr/bin/env python3

import os
import sys
import json
import requests
import time
from urllib.parse import urlparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)

def load_soundcloud_secrets():
    """Load SoundCloud credentials from token file"""
    token_file = os.path.join(ROOT_DIR, '.soundcloud_tokens')

    if not os.path.exists(token_file):
        print("ERROR: .soundcloud_tokens not found. Run soundcloud_auth.py first.", file=sys.stderr)
        return None

    try:
        with open(token_file, 'r') as f:
            token_data = json.load(f)

        # Check if token might be expired
        created_at = token_data.get('created_at', 0)
        expires_in = token_data.get('expires_in', 3600)
        current_time = int(time.time())

        if current_time > (created_at + expires_in - 300):  # Refresh 5 minutes before expiry
            print("INFO: Access token is near expiry, attempting refresh...", file=sys.stderr)
            new_token = refresh_access_token_from_file(token_data)
            if new_token:
                token_data['access_token'] = new_token
                save_updated_token(token_data)

        return token_data

    except json.JSONDecodeError:
        print("ERROR: Invalid .soundcloud_tokens file. Run soundcloud_auth.py again.", file=sys.stderr)
        return None
    except Exception as e:
        print(f"ERROR: Failed to load tokens: {e}", file=sys.stderr)
        return None

def refresh_access_token_from_file(token_data):
    """Refresh access token using refresh token from file data"""
    if 'refresh_token' not in token_data:
        print("INFO: No refresh token available. Using existing access token.", file=sys.stderr)
        return None

    token_url = "https://api.soundcloud.com/oauth2/token"

    data = {
        'client_id': token_data['client_id'],
        'client_secret': token_data['client_secret'],
        'grant_type': 'refresh_token',
        'refresh_token': token_data['refresh_token']
    }

    response = requests.post(token_url, data=data)

    if response.status_code == 200:
        tokens = response.json()
        print("INFO: Access token refreshed successfully.", file=sys.stderr)
        return tokens['access_token']
    else:
        print(f"WARNING: Failed to refresh token. Using existing token. Status: {response.status_code}", file=sys.stderr)
        return None

def save_updated_token(token_data):
    """Update the token file with new access token and timestamp"""
    token_file = os.path.join(ROOT_DIR, '.soundcloud_tokens')

    token_data['created_at'] = int(time.time())

    with open(token_file, 'w') as f:
        json.dump(token_data, f, indent=2)

    os.chmod(token_file, 0o600)

def make_api_request(url, access_token, params=None):
    """Make authenticated request to SoundCloud API"""
    headers = {
        'Authorization': f'OAuth {access_token}',
        'Accept': 'application/json'
    }

    response = requests.get(url, headers=headers, params=params)

    if response.status_code == 401:
        print("WARNING: Access token may be expired. Try running soundcloud_auth.py again.", file=sys.stderr)
        return None
    elif response.status_code != 200:
        print(f"ERROR: API request failed with status {response.status_code}", file=sys.stderr)
        print(f"Response: {response.text}", file=sys.stderr)
        return None

    return response.json()

def get_playlist_id_from_url(playlist_url):
    """Extract playlist ID from SoundCloud URL"""
    # Handle various SoundCloud URL formats:
    # https://soundcloud.com/user/sets/playlist-name
    # https://soundcloud.com/user/sets/playlist-name?si=...

    parsed = urlparse(playlist_url)
    path_parts = parsed.path.strip('/').split('/')

    if len(path_parts) >= 3 and path_parts[1] == 'sets':
        # We have user/sets/playlist-name format
        user = path_parts[0]
        playlist_name = path_parts[2]
        return f"{user}/sets/{playlist_name}"

    print(f"ERROR: Invalid SoundCloud playlist URL format: {playlist_url}", file=sys.stderr)
    return None

def resolve_playlist_url(playlist_url, access_token):
    """Resolve SoundCloud playlist URL to get playlist data"""
    resolve_url = "https://api.soundcloud.com/resolve"
    params = {'url': playlist_url}

    playlist_data = make_api_request(resolve_url, access_token, params)
    return playlist_data

def get_soundcloud_playlist_tracks(playlist_url):
    """Get tracks from a SoundCloud playlist"""
    token_data = load_soundcloud_secrets()
    if not token_data:
        return 1

    access_token = token_data['access_token']

    print(f"INFO: Fetching SoundCloud playlist: {playlist_url}", file=sys.stderr)

    # Resolve the playlist URL
    playlist_data = resolve_playlist_url(playlist_url, access_token)
    if not playlist_data:
        return 1

    if playlist_data.get('kind') != 'playlist':
        print(f"ERROR: URL does not point to a playlist. Kind: {playlist_data.get('kind')}", file=sys.stderr)
        return 1

    tracks = playlist_data.get('tracks', [])
    print(f"INFO: Found {len(tracks)} tracks in playlist", file=sys.stderr)

    track_count = 0
    for track in tracks:
        if track.get('streamable', False):
            # Output track info in JSON format similar to spotify.sh
            track_info = {
                'id': str(track['id']),
                'name': track['title'],
                'artist': track['user']['username'],
                'album': 'SoundCloud',  # SoundCloud doesn't have albums
                'album_art': track.get('artwork_url', 'null'),
                'url': track['permalink_url'],
                'duration': track.get('duration', 0),
                'service': 'soundcloud'
            }

            # Replace artwork URL size if available
            if track_info['album_art'] and track_info['album_art'] != 'null':
                # Replace t500x500 with t500x500 (largest available)
                track_info['album_art'] = track_info['album_art'].replace('large', 't500x500')

            print(json.dumps(track_info))
            track_count += 1
        else:
            print(f"INFO: Skipping non-streamable track: {track['title']}", file=sys.stderr)

    print(f"INFO: Output {track_count} streamable tracks", file=sys.stderr)
    return 0

def test_api_access():
    """Test SoundCloud API access"""
    token_data = load_soundcloud_secrets()
    if not token_data:
        return 1

    access_token = token_data['access_token']
    user_data = make_api_request("https://api.soundcloud.com/me", access_token)

    if user_data:
        print(f"✅ API access successful! Authenticated as: {user_data.get('username', 'Unknown')}")
        return 0
    else:
        print("❌ API access failed")
        return 1

def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print(f"  {sys.argv[0]} <soundcloud_playlist_url>  - Get playlist tracks")
        print(f"  {sys.argv[0]} test                       - Test API access")
        return 1

    if sys.argv[1] == 'test':
        return test_api_access()

    playlist_url = sys.argv[1]
    return get_soundcloud_playlist_tracks(playlist_url)

if __name__ == "__main__":
    sys.exit(main())