"""Shared "m:ss" / "h:mm:ss" parsing (chapter lists and loop commands)."""


def stamp_seconds(stamp: str) -> int:
    """'3:40' -> 220, '1:02:03' -> 3723. Callers validate the format first."""
    total = 0
    for part in stamp.split(":"):
        total = total * 60 + int(part)
    return total
