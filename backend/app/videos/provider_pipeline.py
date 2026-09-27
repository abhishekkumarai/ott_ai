import asyncio
import logging
import ssl
import time
from datetime import datetime, timezone
from enum import Enum
from typing import Any

import httpx
from pydantic import BaseModel, Field

log = logging.getLogger(__name__)


class ProviderHealthStatus(str, Enum):
    HEALTHY = "healthy"      # HTTP 200, valid SSL, embeddable (no DENY / frame-ancestors block)
    DEGRADED = "degraded"    # Reachable, but high latency (>3000ms) or warns on direct embedding
    DOWN = "down"            # Connection refused, DNS failure, SSL invalid, 404/5xx, or Cloudflare challenge barrier


class StreamProviderConfig(BaseModel):
    id: str
    name: str
    category: str            # "youtube", "movies_tv", "anime", "free_vod"
    base_url: str
    embed_pattern: str       # Template e.g. "https://vidy.st/embed/{media_type}/{id}"
    search_type: str         # "catalog", "tmdb", "anilist", "direct"
    requires_season_episode: bool = False
    status: ProviderHealthStatus = ProviderHealthStatus.HEALTHY
    latency_ms: int = 0
    embed_allowed: bool = True
    anti_bot_detected: bool = False
    error: str | None = None
    last_verified: datetime | None = None


class ProviderAuditResult(BaseModel):
    provider_id: str
    status: ProviderHealthStatus
    http_status: int | None = None
    latency_ms: int = 0
    ssl_valid: bool = False
    embed_allowed: bool = True
    anti_bot_detected: bool = False
    x_frame_options: str | None = None
    csp_frame_ancestors: str | None = None
    error: str | None = None
    verified_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


# Curated catalog of candidate providers extracted from https://wiki-index.pages.dev/video/
RAW_PROVIDER_CATALOG: list[StreamProviderConfig] = [
    StreamProviderConfig(
        id="youtube",
        name="YouTube Catalog",
        category="youtube",
        base_url="https://www.youtube-nocookie.com",
        embed_pattern="https://www.youtube-nocookie.com/embed/{id}?enablejsapi=1&autoplay=1",
        search_type="catalog",
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="vidy",
        name="Vidy Multi-Stream",
        category="movies_tv",
        base_url="https://vidy.st",
        embed_pattern="https://www.vidy.st/embed/{media_type}/{id}?color=ff4f38&autoplay=true",
        search_type="tmdb",
        requires_season_episode=True,
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="2embed",
        name="2Embed CC",
        category="movies_tv",
        base_url="https://www.2embed.cc",
        embed_pattern="https://www.2embed.cc/embed/{id}",
        search_type="tmdb",
        requires_season_episode=True,
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="flixer",
        name="Flixer",
        category="movies_tv",
        base_url="https://flixer.gd",
        embed_pattern="https://flixer.gd/watch/{media_type}/{id}",
        search_type="tmdb",
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="bcine",
        name="bCine",
        category="movies_tv",
        base_url="https://bcine.ru",
        embed_pattern="https://bcine.ru/embed/{media_type}/{id}",
        search_type="tmdb",
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="meowtv",
        name="MeowTV",
        category="movies_tv",
        base_url="https://meowtv.ru",
        embed_pattern="https://meowtv.ru/embed/{media_type}/{id}",
        search_type="tmdb",
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="miruro",
        name="Miruro Anime",
        category="anime",
        base_url="https://miruro.com",
        embed_pattern="https://miruro.com/watch?id={id}&ep={episode}",
        search_type="anilist",
        requires_season_episode=True,
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="kaa",
        name="KickAssAnime",
        category="anime",
        base_url="https://kaa.lt",
        embed_pattern="https://kaa.lt/watch/{id}",
        search_type="anilist",
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="tubi",
        name="Tubi TV (VOD)",
        category="free_vod",
        base_url="https://tubitv.com",
        embed_pattern="https://tubitv.com/movies/{id}",
        search_type="direct",
        status=ProviderHealthStatus.HEALTHY,
        embed_allowed=True,
    ),
    StreamProviderConfig(
        id="cinejoy",
        name="Cinejoy",
        category="movies_tv",
        base_url="https://cinejoy.pk",
        embed_pattern="https://cinejoy.pk/embed/{media_type}/{id}",
        search_type="tmdb",
        status=ProviderHealthStatus.DEGRADED,
        embed_allowed=False,  # Set by pipeline on frame audit
    ),
    StreamProviderConfig(
        id="rive",
        name="Rive Stream",
        category="movies_tv",
        base_url="https://rivestream.app",
        embed_pattern="https://rivestream.app/embed?type={media_type}&id={id}",
        search_type="tmdb",
        status=ProviderHealthStatus.DOWN,  # DNS offline currently
        embed_allowed=False,
    ),
    StreamProviderConfig(
        id="popcorn",
        name="PopcornMovies",
        category="movies_tv",
        base_url="https://popcornmovies.ac",
        embed_pattern="https://popcornmovies.ac/embed/{media_type}/{id}",
        search_type="tmdb",
        status=ProviderHealthStatus.DOWN,  # Cloudflare barrier currently
        embed_allowed=False,
    ),
    StreamProviderConfig(
        id="animepahe",
        name="AnimePahe",
        category="anime",
        base_url="https://animepahe.pw",
        embed_pattern="https://animepahe.pw/play/{id}",
        search_type="anilist",
        status=ProviderHealthStatus.DOWN,  # Cloudflare barrier currently
        embed_allowed=False,
    ),
    StreamProviderConfig(
        id="anicine",
        name="AniCine",
        category="anime",
        base_url="https://anicine.xyz",
        embed_pattern="https://anicine.xyz/watch/{id}",
        search_type="anilist",
        status=ProviderHealthStatus.DOWN,  # SSL certificate mismatch
        embed_allowed=False,
    ),
]


USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130.0.0.0 Safari/537.36"
)


async def audit_provider_health(
    provider: StreamProviderConfig,
    client: httpx.AsyncClient | None = None,
    timeout: float = 4.0,
) -> ProviderAuditResult:
    """Probes a streaming provider domain, validates SSL, checks HTTP status,

    response latency, X-Frame-Options, and Cloudflare anti-bot barriers."""
    if provider.id == "youtube":
        return ProviderAuditResult(
            provider_id="youtube",
            status=ProviderHealthStatus.HEALTHY,
            http_status=200,
            latency_ms=10,
            ssl_valid=True,
            embed_allowed=True,
            anti_bot_detected=False,
        )

    owns_client = False
    if client is None:
        client = httpx.AsyncClient(
            timeout=timeout,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
        )
        owns_client = True

    t0 = time.time()
    try:
        r = await client.get(provider.base_url)
        lat = int((time.time() - t0) * 1000)
        http_code = r.status_code

        # Frame permissions
        xfo = r.headers.get("x-frame-options", "").upper()
        csp = r.headers.get("content-security-policy", "").lower()
        frame_blocked = "DENY" in xfo or "SAMEORIGIN" in xfo or "frame-ancestors 'none'" in csp or "frame-ancestors 'self'" in csp

        # Cloudflare / anti-bot challenge page check
        text_lower = r.text[:1000].lower()
        is_cf = (
            "cf-mitigated" in r.headers
            or "challenge-platform" in text_lower
            or "cf-browser-verification" in text_lower
            or (http_code in (403, 503) and "cloudflare" in text_lower)
        )

        if is_cf or http_code >= 400:
            status = ProviderHealthStatus.DOWN
            err = f"HTTP {http_code} (Cloudflare block)" if is_cf else f"HTTP {http_code}"
        elif frame_blocked:
            status = ProviderHealthStatus.DEGRADED
            err = f"Framing restricted: XFO={xfo}"
        elif lat > 3000:
            status = ProviderHealthStatus.DEGRADED
            err = f"High latency ({lat}ms)"
        else:
            status = ProviderHealthStatus.HEALTHY
            err = None

        return ProviderAuditResult(
            provider_id=provider.id,
            status=status,
            http_status=http_code,
            latency_ms=lat,
            ssl_valid=True,
            embed_allowed=not frame_blocked and not is_cf and http_code < 400,
            anti_bot_detected=is_cf,
            x_frame_options=xfo or None,
            csp_frame_ancestors=csp if "frame-ancestors" in csp else None,
            error=err,
        )
    except httpx.HTTPStatusError as e:
        lat = int((time.time() - t0) * 1000)
        return ProviderAuditResult(
            provider_id=provider.id,
            status=ProviderHealthStatus.DOWN,
            http_status=e.response.status_code,
            latency_ms=lat,
            ssl_valid=True,
            embed_allowed=False,
            error=f"HTTP status error: {e}",
        )
    except ssl.SSLError as e:
        lat = int((time.time() - t0) * 1000)
        return ProviderAuditResult(
            provider_id=provider.id,
            status=ProviderHealthStatus.DOWN,
            latency_ms=lat,
            ssl_valid=False,
            embed_allowed=False,
            error=f"SSL verification failed: {e}",
        )
    except Exception as e:
        lat = int((time.time() - t0) * 1000)
        return ProviderAuditResult(
            provider_id=provider.id,
            status=ProviderHealthStatus.DOWN,
            latency_ms=lat,
            ssl_valid=False,
            embed_allowed=False,
            error=f"Connection failure: {e}",
        )
    finally:
        if owns_client:
            await client.aclose()


class ProviderRegistry:
    """Thread-safe registry that stores, periodically audits, and filters

    healthy streaming providers from wiki-index."""

    def __init__(self, catalog: list[StreamProviderConfig] | None = None):
        self._providers: dict[str, StreamProviderConfig] = {
            p.id: p.model_copy() for p in (catalog or RAW_PROVIDER_CATALOG)
        }
        self._audit_lock = asyncio.Lock()
        self._last_run: datetime | None = None

    def get_all(self) -> list[StreamProviderConfig]:
        return list(self._providers.values())

    def get_provider(self, provider_id: str) -> StreamProviderConfig | None:
        return self._providers.get(provider_id)

    def get_verified_providers(self) -> list[StreamProviderConfig]:
        """Returns only verified healthy providers suitable for user-facing embeds."""
        return [
            p for p in self._providers.values()
            if p.status == ProviderHealthStatus.HEALTHY and p.embed_allowed
        ]

    async def run_pipeline(self, max_concurrency: int = 5) -> list[ProviderAuditResult]:
        """Runs audit pipeline concurrently over all providers and updates internal registry."""
        async with self._audit_lock:
            sem = asyncio.Semaphore(max_concurrency)
            headers = {"User-Agent": USER_AGENT}

            async with httpx.AsyncClient(timeout=4.5, follow_redirects=True, headers=headers) as client:
                async def probe_one(p: StreamProviderConfig) -> ProviderAuditResult:
                    async with sem:
                        res = await audit_provider_health(p, client=client)
                        # Update provider in registry
                        p.status = res.status
                        p.latency_ms = res.latency_ms
                        p.embed_allowed = res.embed_allowed
                        p.anti_bot_detected = res.anti_bot_detected
                        p.error = res.error
                        p.last_verified = res.verified_at
                        return res

                tasks = [probe_one(p) for p in self._providers.values()]
                results = await asyncio.gather(*tasks)
                self._last_run = datetime.now(timezone.utc)
                log.info(
                    "Stream provider pipeline finished: %d/%d healthy",
                    len([r for r in results if r.status == ProviderHealthStatus.HEALTHY]),
                    len(results),
                )
                return results


# Global singleton instance
provider_registry = ProviderRegistry()
