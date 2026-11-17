"""phone_location: the owner's last iPhone location fix from the HermesConnect app.

The app sends a fix in the background through the HermesConnect gate (``ssh <host> location``).
The gate stores the newest fix in ``$HOME/.hermes/hermesconnect/location.json`` (mode 0600):

    {"schemaVersion": 1, "lat": 37.3349, "lon": -122.009, "accuracy_m": 12.5,
     "timestamp": "2026-11-16T12:00:00.000Z", "speed": 1.5, "course": 90.0,
     "received_at": "2026-11-16T12:00:03.120Z", "source": "hermesconnect"}

The app sends a fix only when the owner moves (about 500 m) or arrives at a place, so a valid fix
older than STALE_MINUTES means "not moved" (issue #51). The tool returns it with its real age and
accuracy. Only if the fix is missing or not valid does the tool call the findmy plugin
(``findmy_location``) in this process, when that plugin is installed. The phone gets no
command channel: this plugin only reads the file. It never logs coordinates.
"""
from __future__ import annotations

import importlib.util
import json
import math
import os
import re
import stat
from datetime import datetime, timezone
from typing import Any, Optional, Tuple

from tools.registry import tool_error, tool_result

TOOLSET = "phone_location"
STALE_MINUTES = 30
MAX_FILE_BYTES = 65536
FUTURE_SLACK_MINUTES = 5
# A fix from before HermesConnect existed is not valid. Any later valid fix counts, however old.
EARLIEST_FIX = datetime(2025, 1, 1, tzinfo=timezone.utc)

SETUP_HINT = (
    "Ask the owner to turn on location sharing in the HermesConnect app on their iPhone "
    "and to allow location access 'Always'."
)

SCHEMA = {
    "name": "phone_location",
    "description": (
        "Get the owner's current location from their iPhone (the HermesConnect app): latitude, "
        "longitude, accuracy, when it was located, how many minutes ago, and an Apple Maps link. "
        "Use it when the owner asks about places near them, distance, directions, travel time, or "
        "weather where they are. If the phone fix is missing or not valid, the tool uses Find My "
        "(findmy_location) when it can. If 'not_moved' is true, no newer fix came from the phone, so the "
        "owner most likely did not move: use the location, and say how old it is and how exact it is "
        "(accuracy_m). If 'stale' is true, say how old the location is. "
        "Do not repeat exact coordinates unless the owner asks for them."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

_ISO_RE = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})")


def _location_path() -> str:
    # The gate anchors its files at $HOME/.hermes, independent of HERMES_HOME.
    return os.path.join(os.path.expanduser("~"), ".hermes", "hermesconnect", "location.json")


def _findmy_paths() -> list:
    """Places where the findmy plugin can be installed, first match wins."""
    candidates = [os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "findmy")]
    if os.environ.get("HERMES_HOME"):
        candidates.append(os.path.join(os.environ["HERMES_HOME"], "plugins", "findmy"))
    candidates.append(os.path.join(os.path.expanduser("~"), ".hermes", "plugins", "findmy"))
    paths = []
    for folder in candidates:
        path = os.path.join(os.path.realpath(folder), "__init__.py")
        if path not in paths:
            paths.append(path)
    return paths


def _finite(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _parse_time(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or len(value) > 40:
        return None
    match = _ISO_RE.fullmatch(value.strip())
    if not match:
        return None
    zone = "+00:00" if match.group(3) == "Z" else match.group(3)
    fraction = (match.group(2) or "")[:7]
    if fraction:
        fraction = (fraction + "000000")[:7]
    try:
        return datetime.fromisoformat(match.group(1) + fraction + zone).astimezone(timezone.utc)
    except (ValueError, OverflowError):  # OverflowError: year 1 or 9999 moved to UTC.
        return None


def _read_fix(path: str, now: datetime) -> Tuple[Optional[dict], str]:
    """Return (fix, "") or (None, reason). The reason never contains file content."""
    try:
        # O_NONBLOCK: a FIFO at this path must not block the tool.
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return None, "no phone location has arrived yet"
    except OSError:
        return None, "the phone location file cannot be read"
    try:
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("not a regular file")
            raw = stream.read(MAX_FILE_BYTES + 1)
        if len(raw) > MAX_FILE_BYTES:
            raise ValueError("too large")
        data = json.loads(raw.decode("utf-8"), parse_constant=lambda name: float("nan"))
    except (OSError, ValueError, UnicodeDecodeError, RecursionError):
        return None, "the phone location file is not valid"
    if not isinstance(data, dict):
        return None, "the phone location file is not valid"
    lat, lon, accuracy = data.get("lat"), data.get("lon"), data.get("accuracy_m")
    when = _parse_time(data.get("timestamp"))
    if (not _finite(lat) or not -90 <= lat <= 90 or not _finite(lon) or not -180 <= lon <= 180
            or not _finite(accuracy) or accuracy < 0 or when is None or when < EARLIEST_FIX):
        return None, "the phone location file is not valid"
    if (when - now).total_seconds() > FUTURE_SLACK_MINUTES * 60:
        return None, "the phone location time is in the future (clock skew)"
    speed, course = data.get("speed"), data.get("course")
    return {
        "lat": float(lat),
        "lon": float(lon),
        "accuracy_m": float(accuracy),
        "when": when,
        "speed": float(speed) if _finite(speed) and speed >= 0 else None,
        "course": float(course) if _finite(course) and 0 <= course <= 360 else None,
    }, ""


def _maps_link(lat: float, lon: float) -> str:
    return f"https://maps.apple.com/?ll={lat:.6f},{lon:.6f}"


def _phone_result(fix: dict, now: datetime, note: Optional[str] = None) -> dict:
    age = max(0.0, (now - fix["when"]).total_seconds() / 60)
    result = {
        "source": "hermesconnect",
        "latitude": round(fix["lat"], 6),
        "longitude": round(fix["lon"], 6),
        "accuracy_m": round(fix["accuracy_m"]),
        "located_at": fix["when"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        "minutes_ago": round(age, 1),
        "stale": age > STALE_MINUTES,
        "apple_maps": _maps_link(fix["lat"], fix["lon"]),
    }
    if fix["speed"] is not None:
        result["speed_mps"] = round(fix["speed"], 1)
    if fix["course"] is not None:
        result["course_deg"] = round(fix["course"])
    if age > STALE_MINUTES:
        result["not_moved"] = True
        if note is None:
            note = (f"No newer fix came from the phone. This location is {round(age)} minutes old, "
                    f"accurate to about {round(fix['accuracy_m'])} m. The phone sends a new fix when the "
                    "owner moves about 500 m or arrives at a place, so the owner most likely did not move.")
    if note:
        result["note"] = note
    return result


def _findmy() -> Tuple[Optional[dict], str]:
    """Call the findmy plugin handler in this process. Return (data, "") or (None, reason).

    The handler runs only when the plugin's ``_available()`` returns True: the real
    handler starts ``doppler`` and ``node``, which must not run when Find My is not set up.
    """
    path = next((p for p in _findmy_paths() if os.path.isfile(p)), None)
    if path is None:
        return None, "Find My is not installed"
    try:
        spec = importlib.util.spec_from_file_location("_phone_location_findmy", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)  # type: ignore[union-attr]
    except Exception as exc:  # never include addresses, credentials or coordinates
        return None, f"Find My failed ({type(exc).__name__})"
    available = getattr(module, "_available", None)
    try:
        ready = callable(available) and available() is True
    except Exception:
        ready = False
    if not ready:
        return None, "Find My is not set up"
    try:
        data = json.loads(module.handle({}))
    except Exception as exc:  # never include addresses, credentials or coordinates
        return None, f"Find My failed ({type(exc).__name__})"
    if not isinstance(data, dict):
        return None, "Find My returned no location"
    if "error" in data:
        return None, "Find My: " + str(data["error"])[:200]
    if not _finite(data.get("latitude")) or not _finite(data.get("longitude")):
        return None, "Find My returned no location"
    return data, ""


def handle(args: dict, **kw: Any) -> str:
    """Tool entry point. It never raises: the Hermes gateway must not see an exception."""
    try:
        return _handle()
    except Exception as exc:  # never include file content or coordinates
        return tool_error(f"phone_location failed ({type(exc).__name__}). Try again in a minute.")


def _handle() -> str:
    now = datetime.now(timezone.utc)
    fix, problem = _read_fix(_location_path(), now)
    if fix is not None:
        # Any valid fix wins over Find My. An old fix means "not moved" (issue #51).
        return tool_result(_phone_result(fix, now))

    found, findmy_problem = _findmy()
    if found is not None:
        result = dict(found)
        result["source"] = "findmy"
        findmy_age = found.get("minutes_ago")
        if _finite(findmy_age):
            result["stale"] = findmy_age > STALE_MINUTES
        result["phone_fix"] = "missing: " + problem
        return tool_result(result)
    return tool_error(f"No current location: {problem}. {findmy_problem}. {SETUP_HINT}")


def register(ctx: Any) -> None:
    ctx.register_tool(name="phone_location", toolset=TOOLSET, schema=SCHEMA, handler=handle, emoji="📍")
