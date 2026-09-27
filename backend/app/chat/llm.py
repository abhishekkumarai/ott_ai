"""Open-ended messages -> {topic, reply} via a local Ollama model.

LLM output is untrusted: it is length-limited, used only as a search string and as
plain text in the chat, never as HTML or as instructions to anything else.
"""

from dataclasses import dataclass, field

from app import ollama

SYSTEM = (
    "You are the assistant inside a video chat app. The user asks about a topic; you "
    "extract a short YouTube search query (2-6 words) for it and write a one or two "
    "sentence friendly reply introducing the videos you are about to show. Do not list "
    "videos or URLs yourself. If the message is small talk with no topic, set topic to an "
    "empty string and just reply briefly, suggesting they ask for a video on a topic. "
    "In highlights, copy up to three short key phrases (2-6 words) exactly as they "
    "appear in your reply."
)

SCHEMA = {
    "type": "object",
    "properties": {
        "topic": {"type": "string"},
        "reply": {"type": "string"},
        "highlights": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["topic", "reply"],
}


# Only this many recent messages are sent with each request (the app says so).
HISTORY_WINDOW = 6
NUM_PREDICT = 200
# Keep the prompt plus the reply under this share of the context window; beyond it,
# Ollama would silently cut the oldest tokens itself.
CONTEXT_GUARD = 0.9


@dataclass
class Understanding:
    topic: str
    reply: str
    used_llm: bool
    highlights: list[str] = field(default_factory=list)
    prompt_tokens: int = 0
    output_tokens: int = 0
    trimmed: bool = False


def _clean(s: object, limit: int) -> str:
    return " ".join(str(s or "").split())[:limit]


def estimate_tokens(messages: list[dict]) -> int:
    """Rough prompt size: ~4 characters per token plus per-message chat framing.
    Used only for the guard and the app's context meter; usage totals come from
    Ollama's own counts."""
    return sum(len(m["content"]) // 4 + 5 for m in messages) + 3


def fit_history(
    history: list[dict], message: str | None, ctx: int, num_predict: int = NUM_PREDICT
) -> tuple[list[dict], bool]:
    """The last HISTORY_WINDOW messages, dropping the oldest first while the prompt
    (system + history + [message]) and the reply would exceed CONTEXT_GUARD of [ctx].
    Returns the kept history and whether anything had to be dropped."""
    kept = list(history[-HISTORY_WINDOW:])
    fixed = [{"role": "system", "content": SYSTEM}]
    if message is not None:
        fixed.append({"role": "user", "content": message})
    budget = int(ctx * CONTEXT_GUARD) - num_predict
    trimmed = False
    while kept and estimate_tokens(fixed + kept) > budget:
        kept.pop(0)
        trimmed = True
    return kept, trimmed


def next_context(history: list[dict], ctx: int) -> tuple[int, bool]:
    """Estimated prompt tokens the next request starts from (before the new message)."""
    kept, trimmed = fit_history(history, None, ctx)
    return estimate_tokens([{"role": "system", "content": SYSTEM}, *kept]), trimmed


async def understand(message: str, model: str, history: list[dict], ctx: int) -> Understanding:
    kept, trimmed = fit_history(history, message, ctx)
    msgs = [{"role": "system", "content": SYSTEM}, *kept, {"role": "user", "content": message}]
    res = await ollama.chat_json(model, msgs, SCHEMA, num_predict=NUM_PREDICT, num_ctx=ctx)
    if res is None:
        return Understanding(
            topic=message[:200], reply="Here's what I found.", used_llm=False, trimmed=trimmed
        )
    data = res.data
    reply = _clean(data.get("reply"), 600) or "Here's what I found."
    return Understanding(
        topic=_clean(data.get("topic"), 120),
        reply=reply,
        used_llm=True,
        highlights=_highlights(data.get("highlights"), reply),
        prompt_tokens=res.prompt_tokens,
        output_tokens=res.output_tokens,
        trimmed=trimmed,
    )


def _highlights(raw: object, reply: str) -> list[str]:
    """Only phrases that really occur in the reply (the app styles them, nothing more)."""
    out: list[str] = []
    for h in raw if isinstance(raw, list) else []:
        phrase = _clean(h, 60)
        if len(phrase) >= 3 and phrase.lower() in reply.lower() and phrase not in out:
            out.append(phrase)
    return out[:3]
