A Spotify playlist rip tool

### Setup

1. Create `.env` file

```
SPOTIFY_CLIENT_ID=your_client_id_here
SPOTIFY_CLIENT_SECRET=your_client_secret_here
SPOTIFY_PLAYLIST_URL=https://open.spotify.com/playlist/your_playlist_id
OUTPUT_DIR=/path/to/your/output/folder
```

2. Run docker compose

```
docker-compose up -d
```

### Manual

```
chmod +x scripts/*.sh
bash scripts/rippy.sh https://open.spotify.com/playlist/your_playlist_id /path/to/output/folder
```



