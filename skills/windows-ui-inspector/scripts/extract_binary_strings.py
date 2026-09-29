import json
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract_binary_strings.py <executable> <output-json>", file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    data = source.read_bytes()
    ascii_values = [v.decode("latin1", "replace") for v in re.findall(rb"[ -~]{5,}", data)]
    utf16_values = [v.decode("utf-16le", "replace") for v in re.findall(rb"(?:[ -~\x80-\xff]\x00){5,}", data)]
    keywords = (
        ".hex", ".bin", ".cfg", ".ini", ".json", ".xml", ".yaml", ".yml",
        "flash", "eeprom", "firmware", "device", "program", "commandline",
        "registry", "software\\", "http://", "https://",
    )
    clues: list[str] = []
    for value in ascii_values + utf16_values:
        cleaned = value.strip()
        if cleaned and any(k in cleaned.lower() for k in keywords) and cleaned not in clues:
            clues.append(cleaned)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(clues[:1000], ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
