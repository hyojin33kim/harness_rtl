#!/usr/bin/env python3
"""Extract reproducible cycle-level baseline metrics from tb_spw_story VCD."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


TRACKED = {
    "tb_spw_story.rst_n",
    "tb_spw_story.story_phase",
    "tb_spw_story.link_state",
    "tb_spw_story.u_obs.obs_net_tx_accept_evt",
    "tb_spw_story.u_obs.obs_net_rx_accept_evt",
    "tb_spw_story.u_obs.obs_tx_char_evt",
    "tb_spw_story.u_obs.obs_rx_char_evt",
    "tb_spw_story.u_obs.obs_flow_blocked",
}


def parse_vcd(path: Path) -> dict[str, list[tuple[int, str]]]:
    scopes: list[str] = []
    code_to_names: dict[str, list[str]] = defaultdict(list)
    events: dict[str, list[tuple[int, str]]] = defaultdict(list)
    now = 0
    in_header = True

    with path.open(encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            line = raw.strip()
            if in_header:
                if line.startswith("$scope"):
                    scopes.append(line.split()[2])
                elif line.startswith("$upscope"):
                    scopes.pop()
                elif line.startswith("$var"):
                    fields = line.split()
                    code, leaf = fields[3], fields[4]
                    name = ".".join([*scopes, leaf])
                    if name in TRACKED:
                        code_to_names[code].append(name)
                elif line == "$enddefinitions $end":
                    in_header = False
                continue

            if not line:
                continue
            if line.startswith("#"):
                now = int(line[1:])
            elif line[0] in "01xz":
                value, code = line[0], line[1:]
                for name in code_to_names.get(code, []):
                    events[name].append((now, value))
            elif line[0] in "br":
                value, code = line[1:].split(maxsplit=1)
                for name in code_to_names.get(code, []):
                    events[name].append((now, value))

    return events


def first_time(events: dict[str, list[tuple[int, str]]], name: str, value: str,
               after: int = -1) -> int:
    for timestamp, observed in events[name]:
        if timestamp > after and observed == value:
            return timestamp
    raise ValueError(f"missing {name}={value} after {after}")


def rising_times(events: dict[str, list[tuple[int, str]]], name: str,
                 start: int, stop: int) -> list[int]:
    result: list[int] = []
    previous = "x"
    for timestamp, value in events[name]:
        if start <= timestamp < stop and value == "1" and previous != "1":
            result.append(timestamp)
        previous = value
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("vcd", type=Path)
    args = parser.parse_args()
    events = parse_vcd(args.vcd)

    reset_release = first_time(events, "tb_spw_story.rst_n", "1")
    first_run = first_time(events, "tb_spw_story.link_state", "101", reset_release)
    flow_start = first_time(events, "tb_spw_story.story_phase", "10")
    error_start = first_time(events, "tb_spw_story.story_phase", "11")
    reconnect_start = first_time(events, "tb_spw_story.story_phase", "100")
    second_run = first_time(events, "tb_spw_story.link_state", "101", reconnect_start)

    net_tx = rising_times(events, "tb_spw_story.u_obs.obs_net_tx_accept_evt", flow_start, error_start)
    net_rx = rising_times(events, "tb_spw_story.u_obs.obs_net_rx_accept_evt", flow_start, error_start)
    tx_chars = rising_times(events, "tb_spw_story.u_obs.obs_tx_char_evt", flow_start, error_start)
    rx_chars = rising_times(events, "tb_spw_story.u_obs.obs_rx_char_evt", flow_start, error_start)
    blocked = rising_times(events, "tb_spw_story.u_obs.obs_flow_blocked", flow_start, error_start)

    # tb_spw_story uses `timescale 1ns/1ps and always #5 clk = ~clk.
    clock_ps = 10_000
    metrics = {
        "source_vcd": str(args.vcd),
        "timescale_ps": 1,
        "clock_period_ps": clock_ps,
        "reset_release_to_first_run": {
            "cycles": (first_run - reset_release) // clock_ps,
            "time_ns": (first_run - reset_release) / 1_000,
        },
        "reconnect_phase_to_second_run": {
            "cycles": (second_run - reconnect_start) / clock_ps,
            "time_ns": (second_run - reconnect_start) / 1_000,
        },
        "flow_window": {
            "cycles": (error_start - flow_start) // clock_ps,
            "net_tx_accept_count": len(net_tx),
            "net_rx_accept_count": len(net_rx),
            "tx_character_commit_count": len(tx_chars),
            "rx_character_event_count": len(rx_chars),
            "flow_block_episode_count": len(blocked),
        },
        "net_tx_accept_intervals_cycles": [
            (right - left) // clock_ps for left, right in zip(net_tx, net_tx[1:])
        ],
        "net_rx_accept_intervals_cycles": [
            (right - left) // clock_ps for left, right in zip(net_rx, net_rx[1:])
        ],
        "ordinal_net_tx_to_net_rx_accept_delta_cycles": [
            (rx_time - tx_time) // clock_ps
            for tx_time, rx_time in zip(net_tx, net_rx)
        ],
    }
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
