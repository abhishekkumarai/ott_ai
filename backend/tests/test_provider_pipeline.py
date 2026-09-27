import ssl
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from app.videos.provider_pipeline import (
    ProviderHealthStatus,
    ProviderRegistry,
    StreamProviderConfig,
    audit_provider_health,
)


@pytest.mark.asyncio
async def test_audit_provider_health_youtube():
    cfg = StreamProviderConfig(
        id="youtube",
        name="YouTube Catalog",
        category="youtube",
        base_url="https://www.youtube-nocookie.com",
        embed_pattern="https://www.youtube-nocookie.com/embed/{id}",
        search_type="catalog",
    )
    res = await audit_provider_health(cfg)
    assert res.status == ProviderHealthStatus.HEALTHY
    assert res.embed_allowed is True
    assert res.ssl_valid is True
    assert res.anti_bot_detected is False


@pytest.mark.asyncio
async def test_audit_provider_health_mock_healthy():
    cfg = StreamProviderConfig(
        id="vidy",
        name="Vidy Multi-Stream",
        category="movies_tv",
        base_url="https://vidy.st",
        embed_pattern="https://vidy.st/embed/{media_type}/{id}",
        search_type="tmdb",
    )

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.headers = {"content-type": "text/html"}
    mock_resp.text = "<html><body>Vidy Stream</body></html>"

    client = AsyncMock()
    client.get = AsyncMock(return_value=mock_resp)

    res = await audit_provider_health(cfg, client=client)
    assert res.status == ProviderHealthStatus.HEALTHY
    assert res.http_status == 200
    assert res.embed_allowed is True
    assert res.anti_bot_detected is False


@pytest.mark.asyncio
async def test_audit_provider_health_mock_xfo_deny():
    cfg = StreamProviderConfig(
        id="cinejoy",
        name="Cinejoy",
        category="movies_tv",
        base_url="https://cinejoy.pk",
        embed_pattern="https://cinejoy.pk/embed/{id}",
        search_type="tmdb",
    )

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.headers = {"x-frame-options": "DENY"}
    mock_resp.text = "<html><body>Cinejoy Home</body></html>"

    client = AsyncMock()
    client.get = AsyncMock(return_value=mock_resp)

    res = await audit_provider_health(cfg, client=client)
    assert res.status == ProviderHealthStatus.DEGRADED
    assert res.embed_allowed is False
    assert "DENY" in res.x_frame_options


@pytest.mark.asyncio
async def test_audit_provider_health_mock_cloudflare_challenge():
    cfg = StreamProviderConfig(
        id="popcorn",
        name="PopcornMovies",
        category="movies_tv",
        base_url="https://popcornmovies.ac",
        embed_pattern="https://popcornmovies.ac/embed/{id}",
        search_type="tmdb",
    )

    mock_resp = MagicMock()
    mock_resp.status_code = 403
    mock_resp.headers = {"cf-mitigated": "challenge"}
    mock_resp.text = "<html><title>Just a moment... Cloudflare challenge-platform</title></html>"

    client = AsyncMock()
    client.get = AsyncMock(return_value=mock_resp)

    res = await audit_provider_health(cfg, client=client)
    assert res.status == ProviderHealthStatus.DOWN
    assert res.embed_allowed is False
    assert res.anti_bot_detected is True


@pytest.mark.asyncio
async def test_audit_provider_health_mock_ssl_error():
    cfg = StreamProviderConfig(
        id="anicine",
        name="AniCine",
        category="anime",
        base_url="https://anicine.xyz",
        embed_pattern="https://anicine.xyz/embed/{id}",
        search_type="anilist",
    )

    client = AsyncMock()
    client.get = AsyncMock(side_effect=ssl.SSLCertVerificationError("Hostname mismatch"))

    res = await audit_provider_health(cfg, client=client)
    assert res.status == ProviderHealthStatus.DOWN
    assert res.ssl_valid is False
    assert res.embed_allowed is False
    assert "SSL" in res.error


@pytest.mark.asyncio
async def test_provider_registry_pipeline_execution():
    catalog = [
        StreamProviderConfig(
            id="youtube",
            name="YouTube Catalog",
            category="youtube",
            base_url="https://www.youtube-nocookie.com",
            embed_pattern="https://www.youtube-nocookie.com/embed/{id}",
            search_type="catalog",
        ),
        StreamProviderConfig(
            id="vidy",
            name="Vidy Multi-Stream",
            category="movies_tv",
            base_url="https://vidy.st",
            embed_pattern="https://vidy.st/embed/{media_type}/{id}",
            search_type="tmdb",
        ),
        StreamProviderConfig(
            id="bad_site",
            name="Bad Stream",
            category="movies_tv",
            base_url="https://baddomain999.invalid",
            embed_pattern="https://baddomain999.invalid/embed/{id}",
            search_type="tmdb",
        ),
    ]

    registry = ProviderRegistry(catalog=catalog)
    assert len(registry.get_all()) == 3

    # Mock client
    mock_resp_vidy = MagicMock()
    mock_resp_vidy.status_code = 200
    mock_resp_vidy.headers = {}
    mock_resp_vidy.text = "OK"

    async def mock_get(url, **kwargs):
        if "vidy.st" in str(url):
            return mock_resp_vidy
        raise httpx.ConnectError("DNS resolution failed")

    with patch("httpx.AsyncClient.get", side_effect=mock_get):
        results = await registry.run_pipeline(max_concurrency=2)
        assert len(results) == 3

        verified = registry.get_verified_providers()
        # YouTube and Vidy are healthy; bad_site is DOWN and excluded
        verified_ids = [p.id for p in verified]
        assert "youtube" in verified_ids
        assert "vidy" in verified_ids
        assert "bad_site" not in verified_ids


@pytest.mark.asyncio
async def test_providers_api_endpoint(client):
    reg = await client.post("/api/auth/register", json={"email": "provtest@test.com", "password": "Password123!"})
    token = reg.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    resp = await client.get("/api/videos/providers", headers=headers)
    assert resp.status_code == 200
    providers = resp.json()
    assert len(providers) >= 2
    ids = [p["id"] for p in providers]
    assert "youtube" in ids
    assert "vidy" in ids
    # All returned providers must be healthy and embed_allowed
    assert all(p["status"] == "healthy" for p in providers)
    assert all(p["embed_allowed"] is True for p in providers)

