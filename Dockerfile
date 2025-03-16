# Dockerfile
FROM alpine:latest
RUN apk add --no-cache bash curl ffmpeg jq sed grep
WORKDIR /app
COPY . .
RUN chmod +x scripts/*.sh
ENTRYPOINT ["bash", "scripts/rippy.sh"]