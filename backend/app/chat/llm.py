"""Open-ended messages -> {topic, reply} via a local Ollama model.

LLM output is untrusted: it is length-limited, used only as a search string and as
plain text in the chat, never as HTML or as instructions to anything else.
"""

from dataclasses import dataclass

from app import ollama

SYSTEM = (
    "You are the assistant inside a video chat app. The user asks about a topic; you "
    "extract a short YouTube search query (2-6 words) for it and write a one or two "
    "sentence friendly reply introducing the videos you are about to show. Do not list "
    "videos or URLs yourself. If the message is small talk with no topic, set topic to an "
    "empty string and just reply briefly, suggesting they ask for a video on a topic."
)

SCHEMA = {
    "type": "object",
    "properties": {"topic": {"type": "string"}, "reply": {"type": "string"}},
    "required": ["topic", "reply"],
}


@dataclass
class Understanding:
    topic: str
    reply: str
    used_llm: bool


def _clean(s: object, limit: int) -> str:
    return " ".join(str(s or "").split())[:limit]


async def understand(message: str, model: str, history: list[dict]) -> Understanding:
    msgs = [{"role": "system", "content": SYSTEM}, *history[-6:], {"role": "user", "content": message}]
    data = await ollama.chat_json(model, msgs, SCHEMA)
    if not data:
        return Understanding(topic=message[:200], reply="Here's what I found.", used_llm=False)
    return Understanding(
        topic=_clean(data.get("topic"), 120),
        reply=_clean(data.get("reply"), 600) or "Here's what I found.",
        used_llm=True,
    )
