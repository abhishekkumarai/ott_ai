"""Regex grammar for playback commands. Runs before any LLM call, so it is instant.

Returns None when the text is not a playback command (it is then treated as a topic
request). Commands are only recognised in short utterances so that e.g.
"how do I stop procrastinating" is still a topic question.
"""

import re
from dataclasses import dataclass
from typing import Literal

from app.timecode import stamp_seconds

Action = Literal["seek", "pause", "play", "stop", "next", "loop", "unloop", "mute", "unmute", "save"]
DEFAULT_SEEK = 25
MAX_COMMAND_WORDS = 8

_UNITS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
    "nineteen": 19,
}
_TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
         "eighty": 80, "ninety": 90}
_WORD_NUM = "|".join(list(_UNITS) + list(_TENS) + ["a", "an", "half"])

_NUM = rf"(?P<num>\d{{1,4}}(?:\.\d+)?|(?:{_WORD_NUM})(?:[\s-](?:{'|'.join(_UNITS)}))?)"
_UNIT = r"(?P<unit>s|sec|secs|second|seconds|m|min|mins|minute|minutes)?"
_AMOUNT = rf"(?:by\s+)?(?:{_NUM}\s*{_UNIT})?"

_FORWARD = re.compile(
    rf"^(?:(?:please|now|ok|okay)\s+)*(?:go\s+|move\s+|jump\s+|skip\s+|fast\s*)?"
    rf"(?:forward|ahead|skip|ff)(?:\s+ahead)?\s*{_AMOUNT}(?:\s+(?:more|ahead|forward))?$"
)
_FORWARD_ALT = re.compile(rf"^(?:skip|jump|go|move)\s+{_NUM}\s*{_UNIT}\s*(?:ahead|forward)?$")
_BACK = re.compile(
    rf"^(?:(?:please|now|ok|okay)\s+)*(?:go\s+|move\s+|jump\s+|skip\s+)?"
    rf"(?:back|backward|backwards|rewind|reverse)\s*{_AMOUNT}(?:\s+back)?$"
)
_STAMP = r"(\d{1,2}(?::\d{2}){1,2})"
_LOOP_RANGE = re.compile(
    rf"^(?:please\s+)?(?:loop|repeat)\s+(?:from\s+)?{_STAMP}\s+(?:to|till|until|-)\s+{_STAMP}$"
)
_SIMPLE: list[tuple[re.Pattern[str], Action]] = [
    (re.compile(r"^(?:please\s+)?(?:save|bookmark|keep)\s+(?:this|that|it)(?:\s+(?:video|one|lesson))?(?:\s+for\s+later)?$"), "save"),
    (re.compile(r"^(?:please\s+)?(?:stop|end|cancel)\s+(?:the\s+)?(?:loop|looping|repeating|repeat)$|^unloop$"), "unloop"),
    (re.compile(r"^(?:please\s+)?(?:loop|repeat)(?:\s+(?:this|that|it))?(?:\s+(?:part|section|bit|chapter))?$"), "loop"),
    (re.compile(r"^(?:please\s+)?unmute(?:\s+(?:the\s+)?(?:video|it|sound))?$|^sound\s+on$"), "unmute"),
    (re.compile(r"^(?:please\s+)?mute(?:\s+(?:the\s+)?(?:video|it|sound))?$|^sound\s+off$"), "mute"),
    (re.compile(r"^(?:please\s+)?(?:stop|close|exit|quit|end)(?:\s+(?:the\s+)?(?:video|it|playing|playback|watching))?$"), "stop"),
    (re.compile(r"^(?:back\s+to\s+(?:the\s+)?chat|that'?s\s+enough|i'?m\s+done)$"), "stop"),
    (re.compile(r"^(?:please\s+)?(?:pause|hold(?:\s+on)?|wait)(?:\s+(?:the\s+)?(?:video|it))?$"), "pause"),
    (re.compile(r"^(?:please\s+)?(?:play|resume|continue|unpause|go\s+on)(?:\s+(?:the\s+)?(?:video|it|playing))?$"), "play"),
    (re.compile(r"^(?:please\s+)?(?:next|skip)(?:\s+(?:the\s+)?video)?|(?:play\s+)?(?:the\s+)?next\s+(?:one|video)$"), "next"),
]


@dataclass(frozen=True)
class Command:
    action: Action
    seconds: float = 0.0
    # loop range in seconds (None = "this part": the app picks the current chapter)
    start: float | None = None
    end: float | None = None


def _normalize(text: str) -> str:
    t = text.lower().strip()
    t = re.sub(r"[^\w\s'.:-]", " ", t)  # ':' kept for time stamps ("loop 3:40 to 5:10")
    t = re.sub(r"\.(?!\d)|(?<!\d):|:(?!\d)", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def _word_to_number(word: str) -> float:
    word = word.replace("-", " ")
    parts = word.split()
    if parts[0] in ("a", "an"):
        return 1
    if parts[0] == "half":
        return 0.5
    total = 0
    for p in parts:
        total += _TENS.get(p, 0) + _UNITS.get(p, 0)
    return total


def _amount(m: re.Match[str]) -> float:
    num = m.groupdict().get("num")
    unit = m.groupdict().get("unit") or ""
    if not num:
        return DEFAULT_SEEK
    value = float(num) if num[0].isdigit() else _word_to_number(num)
    if unit.startswith("m"):
        value *= 60
    return value


def parse_command(text: str) -> Command | None:
    t = _normalize(text)
    if not t or len(t.split()) > MAX_COMMAND_WORDS:
        return None
    if m := _LOOP_RANGE.fullmatch(t):
        a, b = float(stamp_seconds(m.group(1))), float(stamp_seconds(m.group(2)))
        if b > a:
            return Command("loop", start=a, end=b)
        return None
    for pattern, action in _SIMPLE:
        if pattern.fullmatch(t):
            return Command(action)
    if m := (_FORWARD.fullmatch(t) or _FORWARD_ALT.fullmatch(t)):
        return Command("seek", min(_amount(m), 3600))
    if m := _BACK.fullmatch(t):
        return Command("seek", -min(_amount(m), 3600))
    return None
