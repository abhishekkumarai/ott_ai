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


@dataclass
class Understanding:
    topic: str
    reply: str
    used_llm: bool
    highlights: list[str] = field(default_factory=list)


def _clean(s: object, limit: int) -> str:
    return " ".join(str(s or "").split())[:limit]


async def understand(message: str, model: str, history: list[dict]) -> Understanding:
    msgs = [{"role": "system", "content": SYSTEM}, *history[-6:], {"role": "user", "content": message}]
    data = await ollama.chat_json(model, msgs, SCHEMA)
    if not data:
        return Understanding(topic=message[:200], reply="Here's what I found.", used_llm=False)
    reply = _clean(data.get("reply"), 600) or "Here's what I found."
    return Understanding(
        topic=_clean(data.get("topic"), 120),
        reply=reply,
        used_llm=True,
        highlights=_highlights(data.get("highlights"), reply),
    )


def _highlights(raw: object, reply: str) -> list[str]:
    """Only phrases that really occur in the reply (the app styles them, nothing more)."""
    out: list[str] = []
    for h in raw if isinstance(raw, list) else []:
        phrase = _clean(h, 60)
        if len(phrase) >= 3 and phrase.lower() in reply.lower() and phrase not in out:
            out.append(phrase)
    return out[:3]
