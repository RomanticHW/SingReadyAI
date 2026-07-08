#!/usr/bin/env python3
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/SingReadyAISharedKit/Resources/Fixtures/fixtures_ktv_catalog.json"

REQUIRED_FIELDS = {
    "id": str,
    "title": str,
    "artist": str,
    "language": str,
    "era": str,
    "genre": str,
    "moodTags": list,
    "sceneTags": list,
    "difficulty": int,
    "vocalRangeLowMidi": int,
    "vocalRangeHighMidi": int,
    "energy": (int, float),
    "singAlongScore": (int, float),
    "ktvAvailability": (int, float),
    "duetFriendly": bool,
    "rapDensity": (int, float),
    "highNoteRisk": (int, float),
    "aliases": list,
    "similarSongIds": list,
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def assert_score(track_id: str, field: str, value: float) -> None:
    if not 0 <= float(value) <= 1:
        fail(f"{track_id}.{field} must be between 0 and 1")


def main() -> None:
    if not CATALOG.exists():
        fail(f"missing catalog: {CATALOG}")

    try:
        tracks = json.loads(CATALOG.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"catalog JSON parse failed: {exc}")

    if not isinstance(tracks, list):
        fail("catalog root must be an array")
    if len(tracks) < 180:
        fail(f"catalog must contain at least 180 tracks, found {len(tracks)}")

    seen_ids = set()
    for index, track in enumerate(tracks):
        if not isinstance(track, dict):
            fail(f"track at index {index} must be an object")
        for field, expected_type in REQUIRED_FIELDS.items():
            if field not in track:
                fail(f"track at index {index} missing field: {field}")
            if not isinstance(track[field], expected_type):
                fail(f"{track.get('id', index)}.{field} has invalid type")

        track_id = track["id"]
        if not track_id.strip():
            fail(f"track at index {index} has blank id")
        if track_id in seen_ids:
            fail(f"duplicate track id: {track_id}")
        seen_ids.add(track_id)

        for text_field in ("title", "artist", "language", "era", "genre"):
            if not track[text_field].strip():
                fail(f"{track_id}.{text_field} must not be blank")
        if not 1 <= track["difficulty"] <= 5:
            fail(f"{track_id}.difficulty must be 1...5")
        if not 35 <= track["vocalRangeLowMidi"] <= track["vocalRangeHighMidi"] <= 90:
            fail(f"{track_id} vocal range must be valid MIDI range")
        for score_field in ("energy", "singAlongScore", "ktvAvailability", "rapDensity", "highNoteRisk"):
            assert_score(track_id, score_field, track[score_field])
        if not track["moodTags"]:
            fail(f"{track_id}.moodTags must not be empty")
        if not track["sceneTags"]:
            fail(f"{track_id}.sceneTags must not be empty")

    print(f"Catalog OK: {len(tracks)} tracks")


if __name__ == "__main__":
    main()
