# Rippy

Multi-platform playlist sync tool that downloads tracks from Spotify and SoundCloud, converts them to AIFF with embedded artwork, and bypasses Cloudflare protection.

## Quick Start

1. **Setup credentials:**
```bash
# Option 1: Create .env file (recommended)
cp .env.example .env
# Edit .env with your credentials

# Option 2: Export environment variables
export SPOTIFY_CLIENT_ID="your_spotify_client_id"
export SPOTIFY_CLIENT_SECRET="your_spotify_client_secret"
```

2. **For SoundCloud playlists (one-time setup):**
```bash
python3 scripts/soundcloud_auth.py
# Complete OAuth in browser
```

3. **Create playlist file:**
```bash
# Create playlists.txt with your URLs
cat > playlists.txt << 'EOF'
# Spotify playlists
https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M

# SoundCloud playlists (after OAuth)
https://soundcloud.com/user/sets/playlist-name
EOF
```

4. **Run sync:**
```bash
bash scripts/rippy_multi.sh \
  --playlist-file playlists.txt \
  --output-dir /path/to/music \
  --sync-interval 300 \
  --download-interval 30
```

## Features

- ✅ **Multi-platform** - Spotify and SoundCloud playlists
- ✅ **Bypasses Cloudflare** - Uses selenium-stealth when needed
- ✅ **AIFF conversion** - Ready for CDJs with embedded artwork
- ✅ **Multiple sources** - Tries Qobuz → Tidal → SoundCloud for Spotify tracks
- ✅ **Direct download** - SoundCloud tracks via authenticated API
- ✅ **Auto-sync** - Monitors playlists for changes
- ✅ **Secure tokens** - OAuth tokens stored safely, ignored by git
- ✅ **Simple output** - All logging to terminal, Ctrl+C to stop

## Credentials

**Three ways to provide Spotify credentials:**

1. **`.env` file (recommended):**
```bash
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
```

2. **Environment variables:**
```bash
export SPOTIFY_CLIENT_ID="your_client_id"
export SPOTIFY_CLIENT_SECRET="your_client_secret"
```

3. **Command line:**
```bash
bash scripts/rippy_multi.sh --client-id your_id --client-secret your_secret ...
```

**SoundCloud:** One-time OAuth via `python3 scripts/soundcloud_auth.py`

## Single Track Download

```bash
# Spotify track
bash scripts/rip.sh "https://open.spotify.com/track/TRACK_ID" "/output/dir"

# SoundCloud track (after OAuth)
python3 scripts/soundcloud_download.py "https://soundcloud.com/user/track" "/output/dir"
```



