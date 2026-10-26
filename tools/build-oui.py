#!/usr/bin/env python3
"""Condenses the IEEE registry CSVs into the compact table the app embeds.

Output format, one record per line:

    <prefix hex><TAB><vendor><TAB><country><TAB><registry>

The prefix length carries the block size: 6 hex digits is a 24-bit MA-L
assignment, 7 is a 28-bit MA-M, 9 is a 36-bit MA-S or legacy IAB. Lookups try
the longest prefix first, because a MA-M, MA-S or IAB assignment sits inside a
shared MA-L block and the smaller block is the accurate answer.

The country is the ISO 3166 code the registrant gave in its address, or empty
when the address names none. It says where the registrant is, not where the
device was made.
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


# ISO 3166-1 alpha-2 codes. IEEE addresses end "<region> <country> <postcode>",
# so the code nearest the end wins, which keeps US state abbreviations that
# collide with country codes (CA, MN, GA, ...) from being taken for countries.
COUNTRIES = set("""
AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL
BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV
CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD
GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM
IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK
LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW
MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR
PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS
ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY
UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW
""".split())


def country(address: str) -> str:
    tail = address.replace(",", " ").split()[-3:]
    # A few US registrants put the state after the country ("US MA").
    if "US" in tail:
        return "US"
    for token in reversed(tail):
        if token in COUNTRIES:
            return token
    return ""


def clean(name: str) -> str:
    name = " ".join(name.split())          # collapse embedded newlines
    name = NOISE.sub("", name)
    return name[:58]


def load(path, expected_width, registry):
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
            out[prefix] = (name, country(row.get("Organization Address") or ""), registry)
    return out


def main():
    mal, mam, mas, iab, dest = sys.argv[1:6]
    tables = [(load(mal, 6, "MA-L"), "MA-L"), (load(mam, 7, "MA-M"), "MA-M"),
              (load(iab, 9, "IAB"), "IAB"), (load(mas, 9, "MA-S"), "MA-S")]

    # IAB is the retired predecessor of MA-S and uses the same width; where
    # both name a block, the current MA-S assignment wins.
    merged = {}
    for table, _ in tables:
        merged.update(table)
    records = sorted(merged.items())

    today = datetime.date.today().isoformat()
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(f"# IEEE MAC address block registry\n")
        fh.write(f"# source: standards-oui.ieee.org (MA-L, MA-M, MA-S, IAB)\n")
        fh.write(f"# retrieved: {today}\n")
        fh.write(f"# records: {len(records)}\n")
        for prefix, (name, nation, registry) in records:
            fh.write(f"{prefix}\t{name}\t{nation}\t{registry}\n")

    for table, label in tables:
        print(f"    {label}: {len(table)}")
    located = sum(1 for _, (_, nation, _) in records if nation)
    print(f"    with country: {located}")
    print(f"    total: {len(records)} -> {dest}")


if __name__ == "__main__":
    main()
