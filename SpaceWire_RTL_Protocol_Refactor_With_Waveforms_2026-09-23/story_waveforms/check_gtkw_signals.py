#!/usr/bin/env python3
"""Fail when a GTKWave preset references a signal absent from its VCD."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SCOPE_RE = re.compile(r"^\$scope\s+\S+\s+(\S+)\s+\$end$")
VAR_RE = re.compile(r"^\$var\s+\S+\s+\d+\s+\S+\s+(.+?)\s+\$end$")


def vcd_signals(path: Path) -> set[str]:
    scopes: list[str] = []
    signals: set[str] = set()
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            line = raw.strip()
            match = SCOPE_RE.match(line)
            if match:
                scopes.append(match.group(1))
                continue
            if line == "$upscope $end":
                if scopes:
                    scopes.pop()
                continue
            match = VAR_RE.match(line)
            if match:
                # VCD writes vectors as "name [msb:lsb]" while GTKWave save
                # files use "name[msb:lsb]".
                reference = re.sub(r"\s+(\[[^]]+\])$", r"\1", match.group(1))
                signals.add(".".join((*scopes, reference)))
            if line == "$enddefinitions $end":
                break
    return signals


def gtkw_signals(path: Path) -> list[str]:
    result: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line[0] in "[*@-":
            continue
        result.append(line)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vcd", type=Path)
    parser.add_argument("gtkw", type=Path, nargs="+")
    args = parser.parse_args()

    known = vcd_signals(args.vcd)
    failed = False
    for preset in args.gtkw:
        requested = gtkw_signals(preset)
        missing = [signal for signal in requested if signal not in known]
        if missing:
            failed = True
            print(f"FAIL {preset.name}: {len(missing)} missing signal(s)")
            for signal in missing:
                print(f"  {signal}")
        else:
            print(f"PASS {preset.name}: {len(requested)} signal(s) found")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
