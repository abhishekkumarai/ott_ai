# Build context: repository root (needs app/ and web/).

# 1) Flutter web build: the official stable SDK (no maintained image ships 3.47 yet)
FROM debian:bookworm-slim AS flutter
ARG FLUTTER_VERSION=3.47.5
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C /opt \
 && git config --global --add safe.directory /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /build/app
COPY app/pubspec.yaml app/pubspec.lock ./
COPY app/third_party ./third_party
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release --base-href /app/ --no-web-resources-cdn

# 2) Tailwind build for the landing + admin pages
FROM node:24-alpine AS css
WORKDIR /build/web
COPY web/package.json web/pnpm-lock.yaml web/pnpm-workspace.yaml ./
RUN corepack enable && pnpm install --frozen-lockfile
COPY web/src ./src
COPY web/landing ./landing
COPY web/admin ./admin
RUN pnpm run build

# 3) Static server (non-root, port 8080)
FROM nginxinc/nginx-unprivileged:alpine
COPY web/nginx.conf /etc/nginx/conf.d/default.conf
COPY web/proxy_api.conf /etc/nginx/proxy_api.conf
COPY web/landing /usr/share/nginx/html/landing
COPY web/admin /usr/share/nginx/html/admin
COPY web/player /usr/share/nginx/html/player
COPY web/fonts /usr/share/nginx/html/fonts
COPY web/favicon.svg /usr/share/nginx/html/favicon.svg
COPY --from=css /build/web/dist/assets /usr/share/nginx/html/assets
COPY --from=flutter /build/app/build/web /usr/share/nginx/html/app
EXPOSE 8080
