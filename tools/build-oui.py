#!/usr/bin/env python3
"""Condenses the IEEE registry CSVs into the compact table the app embeds.

Output format, one record per line:

    <prefix hex><TAB><vendor>

The prefix length carries the block size: 6 hex digits is a 24-bit MA-L
assignment, 7 is a 28-bit MA-M, 9 is a 36-bit MA-S. Lookups try the longest
prefix first, because a MA-M or MA-S assignment sits inside a shared MA-L block
and the smaller block is the accurate answer.
"""
import csv, re, sys, datetime

NOISE = re.compile(r"[\s,.]+$")
EXCLUDED_PREFIXES = {
    "8C20F1",
    "9C69B42",
    "AC84FA",
    "B03DC2",
    "C4D7DC",
    "F4D0A7",
}


def clean(name: str) -> str:
    name = " ".join(name.split())          # collapse embedded newlines
    name = NOISE.sub("", name)
    return name[:58]


def load(path, expected_width):
    out = {}
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            prefix = (row.get("Assignment") or "").strip().upper()
            name = clean(row.get("Organization Name") or "")
            if len(prefix) != expected_width or not name:
                continue
            if prefix in EXCLUDED_PREFIXES:
                continue
            if name.lower() in {"private", "ieee registration authority"}:
                continue
            out[prefix] = name
    return out


def main():
    mal, mam, mas, dest = sys.argv[1:5]
    tables = [(load(mal, 6), "MA-L"), (load(mam, 7), "MA-M"), (load(mas, 9), "MA-S")]

    records = []
    for table, _ in tables:
        records.extend(table.items())
    records.sort()

    today = datetime.date.today().isoformat()
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(f"# IEEE MAC address block registry\n")
        fh.write(f"# source: standards-oui.ieee.org (MA-L, MA-M, MA-S)\n")
        fh.write(f"# retrieved: {today}\n")
        fh.write(f"# records: {len(records)}\n")
        for prefix, name in records:
            fh.write(f"{prefix}\t{name}\n")

    for table, label in tables:
        print(f"    {label}: {len(table)}")
    print(f"    total: {len(records)} -> {dest}")


if __name__ == "__main__":
    main()
