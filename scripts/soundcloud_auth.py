#!/usr/bin/env python3

import os
import sys
import json
import time
import webbrowser
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
import requests
import threading

# SoundCloud OAuth Configuration
REDIRECT_URI = "http://localhost:9876/callback"
SCOPE = "non-expiring"  # Required for API access

def load_soundcloud_credentials():
    """Load SoundCloud OAuth app credentials from .env file"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    env_file = os.path.join(root_dir, '.env')

    soundcloud_client_id = os.getenv('SOUNDCLOUD_CLIENT_ID')
    soundcloud_client_secret = os.getenv('SOUNDCLOUD_CLIENT_SECRET')

    # Try to load from .env file if not in environment
    if not soundcloud_client_id or not soundcloud_client_secret:
        if os.path.exists(env_file):
            with open(env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('SOUNDCLOUD_CLIENT_ID='):
                        soundcloud_client_id = line.split('=', 1)[1].strip('"\'')
                    elif line.startswith('SOUNDCLOUD_CLIENT_SECRET='):
                        soundcloud_client_secret = line.split('=', 1)[1].strip('"\'')

    if not soundcloud_client_id or not soundcloud_client_secret:
        print("ERROR: SoundCloud OAuth credentials not found!")
        print("Please add to .env file:")
        print("  SOUNDCLOUD_CLIENT_ID=your_soundcloud_client_id")
        print("  SOUNDCLOUD_CLIENT_SECRET=your_soundcloud_client_secret")
        print()
        print("Get these from https://developers.soundcloud.com/")
        return None, None

    return soundcloud_client_id, soundcloud_client_secret

class CallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/callback'):
            # Parse the callback URL for the authorization code
            url_parts = urllib.parse.urlparse(self.path)
            params = urllib.parse.parse_qs(url_parts.query)

            if 'code' in params:
                self.server.auth_code = params['code'][0]
                self.send_response(200)
                self.send_header('Content-type', 'text/html')
                self.end_headers()
                self.wfile.write(b'''
                <html>
                    <body>
                        <h1>Authorization Successful!</h1>
                        <p>You can close this window and return to the terminal.</p>
                        <script>setTimeout(function(){ window.close(); }, 3000);</script>
                    </body>
                </html>
                ''')
            elif 'error' in params:
                self.server.auth_error = params['error'][0]
                self.send_response(400)
                self.send_header('Content-type', 'text/html')
                self.end_headers()
                self.wfile.write(f'''
                <html>
                    <body>
                        <h1>Authorization Failed</h1>
                        <p>Error: {params['error'][0]}</p>
                        <p>You can close this window and return to the terminal.</p>
                    </body>
                </html>
                '''.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Suppress HTTP server logs
        pass

def start_callback_server():
    """Start the callback server to catch the OAuth redirect"""
    server = HTTPServer(('localhost', 9876), CallbackHandler)
    server.auth_code = None
    server.auth_error = None
    server.timeout = 300  # 5 minutes timeout

    print("Started callback server on http://localhost:9876")

    # Run server in a separate thread
    server_thread = threading.Thread(target=server.handle_request)
    server_thread.daemon = True
    server_thread.start()

    return server

def get_authorization_url(client_id):
    """Generate the SoundCloud authorization URL"""
    params = {
        'client_id': client_id,
        'redirect_uri': REDIRECT_URI,
        'scope': SCOPE,
        'response_type': 'code',
        'state': 'rippy_auth_' + str(int(time.time()))
    }

    base_url = "https://soundcloud.com/connect"
    return f"{base_url}?{urllib.parse.urlencode(params)}"

def exchange_code_for_token(auth_code, client_id, client_secret):
    """Exchange authorization code for access token and refresh token"""
    token_url = "https://api.soundcloud.com/oauth2/token"

    data = {
        'client_id': client_id,
        'client_secret': client_secret,
        'redirect_uri': REDIRECT_URI,
        'grant_type': 'authorization_code',
        'code': auth_code
    }

    print("Exchanging authorization code for tokens...")
    response = requests.post(token_url, data=data)

    if response.status_code == 200:
        return response.json()
    else:
        print(f"Error exchanging code: {response.status_code}")
        print(f"Response: {response.text}")
        return None

def save_tokens(tokens, client_id, client_secret):
    """Save tokens to separate token file"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    token_file = os.path.join(root_dir, '.soundcloud_tokens')

    # Create token data
    token_data = {
        'client_id': client_id,
        'client_secret': client_secret,
        'access_token': tokens['access_token'],
        'expires_in': tokens.get('expires_in', 3600),
        'created_at': int(time.time())
    }

    if 'refresh_token' in tokens:
        token_data['refresh_token'] = tokens['refresh_token']

    # Write to JSON file
    with open(token_file, 'w') as f:
        json.dump(token_data, f, indent=2)

    # Make file readable only by owner for security
    os.chmod(token_file, 0o600)

    print(f"Tokens saved to {token_file}")
    print("Note: This file is ignored by git to prevent accidental commits")

def test_api_access(access_token):
    """Test if the access token works"""
    headers = {'Authorization': f'OAuth {access_token}'}
    response = requests.get('https://api.soundcloud.com/me', headers=headers)

    if response.status_code == 200:
        user_data = response.json()
        print(f"✅ API access successful! Authenticated as: {user_data.get('username', 'Unknown')}")
        return True
    else:
        print(f"❌ API access failed: {response.status_code}")
        print(f"Response: {response.text}")
        return False

def main():
    print("SoundCloud OAuth Authorization Setup")
    print("=" * 40)
    print()

    # Load credentials
    client_id, client_secret = load_soundcloud_credentials()
    if not client_id or not client_secret:
        return 1

    # Start callback server
    server = start_callback_server()

    # Generate and open authorization URL
    auth_url = get_authorization_url(client_id)
    print(f"Opening browser to authorize SoundCloud access...")
    print(f"If the browser doesn't open automatically, visit:")
    print(f"  {auth_url}")
    print()

    webbrowser.open(auth_url)

    # Wait for callback
    print("Waiting for authorization... (timeout in 5 minutes)")
    print("Please complete the authorization in your browser.")
    print()

    start_time = time.time()
    while server.auth_code is None and server.auth_error is None:
        if time.time() - start_time > 300:  # 5 minute timeout
            print("❌ Authorization timeout. Please try again.")
            return 1
        time.sleep(1)

    if server.auth_error:
        print(f"❌ Authorization failed: {server.auth_error}")
        return 1

    print("✅ Authorization successful!")

    # Exchange code for tokens
    tokens = exchange_code_for_token(server.auth_code, client_id, client_secret)
    if not tokens:
        print("❌ Failed to get access tokens")
        return 1

    print("✅ Access tokens obtained!")

    # Test API access
    if not test_api_access(tokens['access_token']):
        return 1

    # Save tokens
    save_tokens(tokens, client_id, client_secret)

    print()
    print("🎉 SoundCloud authorization complete!")
    print("You can now use SoundCloud playlists with rippy.")
    print()
    print("Token details:")
    print(f"  Access Token: {tokens['access_token'][:20]}...")
    if 'refresh_token' in tokens:
        print(f"  Refresh Token: {tokens['refresh_token'][:20]}...")
    print(f"  Expires in: {tokens.get('expires_in', 'Unknown')} seconds")

    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n❌ Authorization cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        sys.exit(1)