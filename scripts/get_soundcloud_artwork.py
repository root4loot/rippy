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
        return token_data
    except:
        return None

def make_api_request(url, access_token, params=None):
    """Make authenticated request to SoundCloud API"""
    headers = {
        'Authorization': f'OAuth {access_token}',
        'Accept': 'application/json'
    }

    response = requests.get(url, headers=headers, params=params)

    if response.status_code != 200:
        return None

    return response.json()

def get_soundcloud_track_artwork(track_url):
    """Get artwork URL for a single SoundCloud track"""
    token_data = load_soundcloud_secrets()
    if not token_data:
        return None

    access_token = token_data['access_token']

    # Resolve the track URL
    resolve_url = "https://api.soundcloud.com/resolve"
    params = {'url': track_url}

    track_data = make_api_request(resolve_url, access_token, params)
    if not track_data:
        return None

    if track_data.get('kind') != 'track':
        return None

    artwork_url = track_data.get('artwork_url')
    if artwork_url:
        # Replace with highest quality version
        artwork_url = artwork_url.replace('large', 't500x500')
        return artwork_url

    return None

def main():
    if len(sys.argv) < 2:
        print("Usage: get_soundcloud_artwork.py <soundcloud_track_url>", file=sys.stderr)
        return 1

    track_url = sys.argv[1]
    artwork_url = get_soundcloud_track_artwork(track_url)

    if artwork_url:
        print(artwork_url)
        return 0
    else:
        return 1

if __name__ == "__main__":
    sys.exit(main())