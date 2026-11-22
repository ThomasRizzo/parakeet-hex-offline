#!/usr/bin/env python3
"""Print the GGUF artifacts a Hex source tree pins, as JSON.

Usage: hex_pins.py <hex-source-dir>

Reads `pub const NAME: GgufArtifact = GgufArtifact { ... }` blocks from
src/transcription/*.rs, so the release workflow can check that the Parakeet
pin it mirrors is the one this Hex version downloads, and learn the other
files Hex fetches at runtime (the Silero VAD speech detector).
"""
import json
import pathlib
import re
import sys

BLOCK = re.compile(
    r"(?:pub(?:\([a-z]+\))?\s+)?const\s+([A-Z0-9_]+)\s*:\s*GgufArtifact\s*=\s*GgufArtifact\s*\{(.*?)\};",
    re.S,
)
FIELD = re.compile(r'(\w+)\s*:\s*("(?:[^"\\]|\\.)*"|[0-9_]+)\s*,')


def main() -> None:
    root = pathlib.Path(sys.argv[1])
    found = {}
    for path in sorted((root / "src" / "transcription").glob("*.rs")):
        for name, body in BLOCK.findall(path.read_text(encoding="utf-8")):
            fields = {}
            for key, raw in FIELD.findall(body):
                fields[key] = json.loads(raw) if raw.startswith('"') else int(raw.replace("_", ""))
            fields["source"] = str(path.relative_to(root))
            found[name] = fields
    if not found:
        sys.exit("no GgufArtifact constants found")
    json.dump(found, sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
