# Rippy

Spotify playlist sync tool that downloads tracks, converts them to AIFF with embedded artwork, and bypasses Cloudflare protection.

## Quick Start

1. **Setup credentials:**
```bash
# Create secrets file
echo 'spotify_client_id = "your_client_id"' > secrets.toml
echo 'spotify_client_secret = "your_client_secret"' >> secrets.toml
```

2. **Create playlist file:**
```bash
# Create playlists.txt with your Spotify URLs
cat > playlists.txt << 'EOF'
# My playlists
https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M
https://open.spotify.com/playlist/37i9dQZF1DX0XUsuxWHRQd
EOF
```

3. **Run sync:**
```bash
bash scripts/rippy_multi.sh \
  --playlist-file playlists.txt \
  --output-dir /path/to/music \
  --sync-interval 300 \
  --download-interval 30
```

## Features

- ✅ **Bypasses Cloudflare** - Uses selenium-stealth when needed
- ✅ **AIFF conversion** - Ready for CDJs with embedded artwork
- ✅ **Multiple sources** - Tries Qobuz → Tidal → SoundCloud
- ✅ **Auto-sync** - Monitors playlists for changes
- ✅ **Private playlists** - Works with your Spotify credentials
- ✅ **Simple output** - All logging to terminal, Ctrl+C to stop

## Single Playlist

```bash
export SPOTIFY_CLIENT_ID="your_id" && \
export SPOTIFY_CLIENT_SECRET="your_secret" && \
bash scripts/rip.sh "https://open.spotify.com/track/TRACK_ID" "/output/dir"
```



