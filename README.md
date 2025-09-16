# Rippy

Spotify playlist sync tool

## Setup

```bash
cp playlists.toml.example playlists.toml
chmod +x scripts/*.sh
```

## Credentials

Three ways to provide Spotify credentials:

1. **Environment variables:**
```bash
export SPOTIFY_CLIENT_ID="your_client_id"
export SPOTIFY_CLIENT_SECRET="your_client_secret"
```

2. **Secrets file (for Docker/persistent use):**
```toml
# secrets.toml
spotify_client_id = "your_client_id"
spotify_client_secret = "your_client_secret"
```

3. **Command line arguments:**
```bash
bash scripts/rippy.sh "[spotify-playlist-url]" [output-dir] --client-id [spotify-client-id] --client-secret [spotify-client-secret]
```

## Usage

### Multiple Playlists

```bash
bash scripts/rippy.sh start
bash scripts/rippy.sh stop
bash scripts/rippy.sh status
```

### Single Playlist

```bash
bash scripts/rippy.sh "[spotify-playlist-url]" [output-dir]
bash scripts/rippy.sh "[spotify-playlist-url]" [output-dir] --client-id [spotify-client-id] --client-secret [spotify-client-secret]
```

### Docker

```bash
docker-compose up -d
docker-compose down
```



