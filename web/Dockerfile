# Build context: repository root (needs app/ and web/).

# 1) Flutter web build
FROM ghcr.io/cirruslabs/flutter:3.44.0 AS flutter
WORKDIR /build/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release --base-href /app/ --no-web-resources-cdn

# 2) Tailwind build for the landing + admin pages
FROM node:24-alpine AS css
WORKDIR /build/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/src ./src
COPY web/landing ./landing
COPY web/admin ./admin
RUN npm run build

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
