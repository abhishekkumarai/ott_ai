# Changes

## 2026-10-04

### Features

- **OTTAI-49: Real title search for the movie and TV aggregators** (`da044e5`)
  - Vidy, 2embed, Flixer, Rive, Popcorn, Cinejoy and the other movie/TV sources now look up the title you type on TMDB. Before, they returned a small built-in list.
  - The query is cleaned up first. For example, "watch dune 2021 movie" becomes the title "dune" with the year 2021.
  - Movie-only sources search movies and TV sources search shows. The rest search both.
  - Results are ranked by how well the title matches, and the year breaks ties. "Match %" now shows that title match, not the TMDB rating.
  - Results are cached for 10 minutes.
  - TV seasons and episodes load for any show TMDB finds.
  - Configuration: `OTT_TMDB_API_KEY` or `OTT_TMDB_READ_TOKEN`. The plain names `TMDB_API_KEY` and `TMDB_READ_ACCESS_TOKEN` are also accepted. Both are passed through by `docker-compose.yml`, and the backend logs at startup whether TMDB is on.
- **OTTAI-50: Ollama health check and new model dropdown** (`1e79452`)
  - Settings has an "Ollama health" check that shows whether Ollama is healthy, degraded or unreachable. It also shows the version, the response time, the installed models and whether the embedding model is present.
  - The model picker in the chat input is now a dropdown. It lists each model's context size and notes that new chats start with the model set in Settings.
- **OTTAI-42: Search quality improvements** (`921b1bf`)
  - Stricter semantic matching for catalog hits.
  - The search can match words in titles.
  - A fallback that matches any of the words when no video matches all of them.
  - Short keyword queries are kept as the search topic.
  - The YouTube search no longer fails on results that are channels or playlists.

### Bug fixes

- **OTTAI-49:** Movie and TV sources kept showing the same default titles. The TMDB key was never read, and the fallback list matched common words like "movie".
- **OTTAI-56:** The top search box ignored the selected source and always searched YouTube.
- **OTTAI-51 (security):** Removed the public `/api/health/ollama` route. It showed the Ollama address, version and model list to anyone, with no sign-in or rate limit.
- **OTTAI-52:** One catalog search query could fail and break every other database query in the same request.
- **OTTAI-53:** YouTube quota and API-key errors were silently treated as "no results". They are logged again.
- **OTTAI-54:** `_` and `%` in search text acted as wildcards in the title match.
- **OTTAI-55:** Small talk such as "thanks", "ok" or "hi there" started a video search.

### Tests

- Backend: 136 passed.
  - New: `backend/tests/test_title_search.py`. TMDB calls are faked, and the real TMDB is switched off for all tests.
  - New: catalog search tests in `backend/tests/test_retrieval_quality.py`, run against Postgres.
- Flutter: 85 passed.
  - New: `app/test/settings_and_models_test.dart`.
  - Golden images updated for the new dropdown.

### Known issue

From the current development network, about half of all connections to `api.themoviedb.org` are reset partway through setup. curl sees the same thing, which suggests the internet provider is filtering it. The backend retries each TMDB call up to 3 times. Using a VPN or a different network avoids the problem.
