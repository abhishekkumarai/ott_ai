"""Generate the project .env from the machine-wide DATABASE_URL.

The system DATABASE_URL has credentials but no database name, so we append
`ott_ai_db`. The system variable itself is never modified.
Existing values for other keys (e.g. OTT_YOUTUBE_API_KEY) are preserved.
"""

import os
import secrets
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

DB_NAME = "ott_ai_db"
ROOT = Path(__file__).resolve().parents[2]
ENV_PATH = ROOT / ".env"


def build_url(raw: str, host: str) -> str:
    parts = urlsplit(raw)
    netloc = parts.netloc
    creds, _, hostport = netloc.rpartition("@")
    port = hostport.rsplit(":", 1)[1] if ":" in hostport else "5432"
    netloc = f"{creds}@{host}:{port}" if creds else f"{host}:{port}"
    return urlunsplit(("postgresql+asyncpg", netloc, f"/{DB_NAME}", "", ""))


def read_existing() -> dict[str, str]:
    if not ENV_PATH.exists():
        return {}
    out = {}
    for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def main() -> None:
    raw = os.environ.get("DATABASE_URL")
    if not raw:
        sys.exit("DATABASE_URL is not set in the environment")
    env = read_existing()
    env["OTT_DATABASE_URL"] = build_url(raw, "localhost")
    env["OTT_DOCKER_DATABASE_URL"] = build_url(raw, "host.docker.internal")
    env.setdefault("OTT_ENV", "dev")
    env.setdefault("OTT_JWT_SECRET", secrets.token_urlsafe(48))
    env.setdefault("OTT_YOUTUBE_API_KEY", "")
    env.setdefault("OTT_OLLAMA_URL", "http://localhost:11434")
    env.setdefault("OTT_DOCKER_OLLAMA_URL", "http://host.docker.internal:11434")
    ENV_PATH.write_text("".join(f"{k}={v}\n" for k, v in env.items()), encoding="utf-8")
    print(f"wrote {ENV_PATH} (database: {DB_NAME})")


if __name__ == "__main__":
    main()
