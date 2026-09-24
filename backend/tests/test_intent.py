import pytest

from app.chat.intent import Command, parse_command


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("forward 25 sec", Command("seek", 25)),
        ("Forward", Command("seek", 25)),
        ("move forward 25 seconds", Command("seek", 25)),
        ("go forward by 10s", Command("seek", 10)),
        ("skip ahead twenty five seconds", Command("seek", 25)),
        ("skip ahead twenty-five seconds", Command("seek", 25)),
        ("forward 2 minutes", Command("seek", 120)),
        ("jump 30 seconds ahead", Command("seek", 30)),
        ("forward a minute", Command("seek", 60)),
        ("please forward 25 sec more", Command("seek", 25)),
        ("fast forward", Command("seek", 25)),
        ("ahead 25", Command("seek", 25)),
        ("go back 10", Command("seek", -10)),
        ("rewind", Command("seek", -25)),
        ("back 1 minute", Command("seek", -60)),
        ("stop", Command("stop")),
        ("Stop!", Command("stop")),
        ("stop the video", Command("stop")),
        ("close", Command("stop")),
        ("back to chat", Command("stop")),
        ("pause", Command("pause")),
        ("pause the video.", Command("pause")),
        ("resume", Command("play")),
        ("play", Command("play")),
        ("continue", Command("play")),
        ("next", Command("next")),
        ("next video", Command("next")),
        ("play the next one", Command("next")),
    ],
)
def test_commands(text, expected):
    assert parse_command(text) == expected


@pytest.mark.parametrize(
    "text",
    [
        "how do I stop procrastinating",
        "show me a video about sourdough bread",
        "play some jazz music",
        "what is quantum computing",
        "forward thinking leadership talk for managers and founders",
        "",
        "   ",
    ],
)
def test_not_commands(text):
    assert parse_command(text) is None
