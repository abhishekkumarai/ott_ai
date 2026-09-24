# Reel — a video chatbot

Ask about a topic, and a free YouTube video plays inside the chat overlay, with related videos in a side panel.
Control playback by typing, speaking or using the keyboard:

| Say / type | Effect |
|---|---|
| `forward`, `forward 25 sec`, `skip ahead a minute` | jump ahead (25 s default) and **keep playing** |
| `back 10`, `rewind` | jump back |
| `pause` / `play` | pause / resume |
| `next` | play the top recommendation |
| `stop` | close the video, back to chat (“Stopped at m:ss”) |

Keys while the command box is empty: `→` / `←` seek, `Esc` stops.

No paid services. Chat understanding runs on local **Ollama**; search is Postgres full-text + **pgvector** embeddings (`nomic-embed-text`); the YouTube Data API (free quota) is only a fallback, and its results are cached into the catalog.

## Layout

```
backend/   FastAPI · SQLAlchemy (async) · Alembic · argon2 + JWT · slowapi
web/       nginx image: landing page + admin page (HTML/Tailwind v4/vanilla JS), player.html bridge
app/       Flutter (web, Android, Windows) with shadcn_ui
```

`web/player/player.html` hosts the YouTube IFrame API. Flutter web embeds it in a same-origin iframe (postMessage);
Android/Windows load the same page in a WebView (`flutter_inappwebview`).

## Run it

Prerequisites on the host: Postgres 16 with `pgvector`, Ollama with `llama3.2:3b`, `qwen3.5:4b`, `llama3.1`, `nomic-embed-text`.

```bash
python backend/scripts/make_env.py      # .env from the machine DATABASE_URL + /ott_ai_db (the system var is not modified)
# one-time: CREATE DATABASE ott_ai_db;  (extensions are created by the migration)
docker compose up -d --build            # http://localhost:8088  (OTT_WEB_PORT to change)
docker compose exec api python -m app.cli seed                    # load seed/catalog.json (48 curated videos)
docker compose exec api python -m app.cli create-admin you@example.com   # admin page: /admin/
```

Routes: `/` landing · `/app/` Flutter app · `/admin/` catalog admin · `/api/*` API.

### Native builds

```bash
cd app
flutter build apk      # emulator reaches the host at 10.0.2.2:8088 by default
flutter build windows  # uses http://localhost:8088
# a real phone: adb reverse tcp:8088 tcp:8088, or --dart-define=API_BASE=https://your-host
```

Android only allows cleartext HTTP to `10.0.2.2`/`localhost`; use HTTPS for anything else.

## Develop / test

```bash
cd backend && python -m venv .venv && .venv/Scripts/pip install -r requirements-dev.txt
.venv/Scripts/alembic upgrade head
.venv/Scripts/python -m pytest              # uses the separate ott_ai_db_test database
.venv/Scripts/bandit -r app && .venv/Scripts/pip-audit -r requirements.txt
cd ../app && flutter analyze && flutter test
cd ../web && npm ci && npm run build        # Tailwind CSS
python -m seed.build_catalog                # (backend/) rebuild catalog.json from the API (~2.5k quota units)
```

## Security notes

- Passwords: argon2id; generic login errors; lockout after 5 failures; rate limits in nginx and FastAPI.
- Sessions: 15-min JWT access token held in memory; rotating refresh token (hashed in DB, reuse revokes the family) —
  HttpOnly/Secure/SameSite=Strict cookie on web, OS secure storage on native.
- All input validated (Pydantic, 500-char messages, 11-char video-id regex everywhere, 16 KB body cap).
  LLM output is treated as untrusted plain text. Admin endpoints require `is_admin`.
- nginx: strict CSP, `frame-ancestors 'self'`, nosniff, Referrer/Permissions-Policy, no dotfiles, API not published.
  Containers run non-root, read-only, all capabilities dropped.
- Secrets live only in `.env` (git-ignored). The YouTube key is restricted to the YouTube Data API and never reaches clients.
- The app refuses to start unless the resolved database name is `ott_ai_db`
  (guards against the machine-wide `DATABASE_URL`, which has no database name).
