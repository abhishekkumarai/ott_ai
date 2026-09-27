# Requirements: Multi-Source Video Engine (Vidy Integration & Source Dropdown)

**Status:** Planned · **Jira Epic:** [OTTAI-28](https://emailabhishek2.atlassian.net/browse/OTTAI-28) · **Target Release:** Multi-Source v1.0
**Stories:**
- [OTTAI-29](https://emailabhishek2.atlassian.net/browse/OTTAI-29): Unified Multi-Provider Player Bridge (YouTube + Vidy)
- [OTTAI-30](https://emailabhishek2.atlassian.net/browse/OTTAI-30): Data Models & Multi-Source Media Abstraction (Backend & Flutter)
- [OTTAI-31](https://emailabhishek2.atlassian.net/browse/OTTAI-31): Vidy Media Search & Metadata Resolution (TMDB & AniList APIs)
- [OTTAI-32](https://emailabhishek2.atlassian.net/browse/OTTAI-32): UI Source Dropdown & Provider State Management (Flutter)
- [OTTAI-33](https://emailabhishek2.atlassian.net/browse/OTTAI-33): Media Card & Recommended Rail Adaptation for Vidy Content
- [OTTAI-34](https://emailabhishek2.atlassian.net/browse/OTTAI-34): End-to-End Verification & Regression Testing

---

## 1. Executive Summary & Goal

OTT-AI currently retrieves and controls free YouTube educational/technical videos using PostgreSQL full-text search, pgvector semantic search (`nomic-embed-text`), and local Ollama LLMs.

This specification introduces support for **Vidy** ([https://www.vidy.st/#playground](https://www.vidy.st/#playground)) as an alternative media provider. Vidy is a free embeddable video player capable of streaming Movies and TV series via TMDB IDs, and Anime via AniList IDs.

### Primary Constraint: Non-Disturbance & Backward Compatibility
- **Zero regression on existing YouTube features:** The default mode remains YouTube. All existing catalog items, pgvector embeddings, regex intent commands (`forward 25 sec`, `loop`, `mute`), per-chat saves, and golden tests must remain 100% operational.
- **Provider Isolation:** YouTube and Vidy pipelines are separated via a clean provider abstraction.

---

## 2. System Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                        User Interfaces (Flutter)                       │
├────────────────────────────────────────────────────────────────────────┤
│  Top Bar / Status Line: [ Source Dropdown: YouTube ▾ | Vidy ▾ ]         │
│  Chat Area & Mini-Player / Recommended Rail                             │
│   • VideoCard adapts: 16:9 for YouTube, 2:3 poster for Movies/Anime    │
│   • Recommended Rail: YouTube recommendations vs TMDB/AniList related  │
├────────────────────────────────────────────────────────────────────────┤
│                     Unified Player Bridge (player.html)                │
├────────────────────────────────────────────────────────────────────────┤
│  Same-origin iframe bridge (web/player/player.html & player.js)        │
│   • Slot A: YouTube IFrame API (<div id="yt"></div>)                   │
│   • Slot B: Vidy Embed Player (https://vidy.st/movie|tv|anime/...)     │
│   • postMessage Event Normalizer: Vidy PLAYER_EVENT -> ott-player event │
├────────────────────────────────────────────────────────────────────────┤
│                           FastAPI Backend                              │
├────────────────────────────────────────────────────────────────────────┤
│  POST /api/conversations/{id}/messages (source: "youtube" | "vidy")    │
│   • If "youtube": Catalog FTS + pgvector + YouTube API fallback        │
│   • If "vidy": TMDB API (Movies/TV) + AniList GraphQL API (Anime)      │
│   • Intent Engine: Regex commands work across both providers           │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Specifications by Story

### OTTAI-29: Unified Multi-Provider Player Bridge
- **Location:** `web/player/player.html`, `web/player/player.js`
- **Mechanism:**
  - `player.html` mounts two slots: `#yt` and `#vidy-container`.
  - In `player.js`, the `load(id, start, provider)` command checks provider:
    - If `provider === 'vidy'` (or id matches `vidy:movie:...`, `vidy:tv:...`, `vidy:anime:...`):
      1. Hide `#yt`, pause YouTube player.
      2. Set `#vidy-container` iframe source to `https://vidy.st/{route}?color=FF5A3D&autoplay=true&progress={start}&nextEpisode=true&episodeSelector=true`.
      3. Attributes: `allow="encrypted-media; autoplay *; fullscreen *"`.
      4. Listen to `window.addEventListener('message')` for `PLAYER_EVENT`:
         - `timeupdate` -> `emit('time', { t: payload.currentTime, d: payload.duration, playing: true })`
         - `play` -> `emit('state', { playing: true })`
         - `pause` -> `emit('state', { playing: false })`
         - `ended` -> `emit('ended', state())`
    - If `provider === 'youtube'`:
      1. Hide `#vidy-container`, show `#yt`.
      2. Call existing `player.loadVideoById({ videoId: id, startSeconds: start })`.
- **Result:** Neither Flutter Web (`PlayerViewWeb`) nor Native WebView (`PlayerViewNative`) require rewriting; the same-origin transport bridge handles both seamlessly.

### OTTAI-30: Data Models & Multi-Source Media Abstraction
- **Backend Schema:**
  - Keep `videos` table intact for YouTube catalog (protects existing `ck_videos_youtube_id` constraint).
  - Add optional `media_items` table or structured JSONB in `messages.media_items` for dynamic Vidy results containing:
    - `id`: string (e.g. `vidy:movie:315162`, `vidy:tv:1396:1:1`, `vidy:anime:21:1`)
    - `provider`: `"youtube" | "vidy"`
    - `media_type`: `"video" | "movie" | "tv" | "anime"`
    - `title`: string
    - `overview`: string
    - `poster_url`: string
    - `duration_s`: integer
    - `season`: int (optional)
    - `episode`: int (optional)
- **Flutter Model (`app/lib/chat/models.dart`):**
  - Generalize `Video` or create `MediaItem` with a factory that safely handles both YouTube and Vidy formats.
  - Video identifier validator relaxes only when provider is `vidy`.

### OTTAI-31: Vidy Media Search & Metadata Resolution (TMDB & AniList)
- **Entertainment Entity Resolution:**
  - **Movies & TV:** Free TMDB API (`/search/movie`, `/search/tv`, `/movie/{id}/recommendations`).
  - **Anime:** Public AniList GraphQL API (`https://graphql.anilist.co`, 100% free, no API key required).
- **Ollama Prompt Tuning:**
  - When `source === 'vidy'`, LLM system prompt directs the model to extract movie/show titles, year, and target season/episode rather than a YouTube search query.

### OTTAI-32: UI Source Dropdown & Provider State Management (Flutter)
- **UI Component:**
  - Implemented with `shadcn_ui` (`ShadSelect` or `ShadPopover` styled with Coral `#FF5A3D` tokens).
  - Placed on the composer status line next to the model picker:
    `[ 🎬 Source: YouTube ▾ ] [ 🤖 Model: llama3.2:3b ▾ ] [ ctx 1.2k / 4k ]`
  - Dropdown items:
    1. **YouTube** (Default: Free educational & technical content)
    2. **Vidy — Movies** (TMDB Movies)
    3. **Vidy — TV Series** (TMDB TV Shows & Episodes)
    4. **Vidy — Anime** (AniList Anime)
- **State:**
  - Stored in `ChatState.activeSource`.
  - Persisted in user preferences (`preferences.dart`).

### OTTAI-33: Media Card & Recommended Rail Adaptation
- **VideoCard:**
  - Adapts aspect ratio: standard 16:9 for YouTube; 2:3 poster card for Movies/Anime.
  - Shows provider badge: `YouTube` (Coral), `TMDB` (Emerald), `AniList` (Sky).
  - Includes episode selector trigger for TV series / Anime.
- **Recommended Rail:**
  - In Vidy mode, shows TMDB/AniList recommended items with similarity scores.

### OTTAI-34: End-to-End Verification & Regression Testing
- **Test Matrix:**
  - Run full existing test suites: `pytest`, `flutter test`, golden snapshot tests.
  - Test switching between sources in the same chat or across chats.
  - Test dockable mini-player and theater mode transitions with Vidy iframe.
