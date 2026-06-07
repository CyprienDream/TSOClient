#!/usr/bin/env python3
"""
TSO log parser — extracts structured data from Xcode console output.

Usage:
    python3 parse_logs.py [logs.md]          # full report
    python3 parse_logs.py [logs.md] --type 61   # filter to one call type
    python3 parse_logs.py [logs.md] --classes   # just print all __class names
"""

from __future__ import annotations

import re
import sys
import json
from collections import defaultdict, Counter
from typing import Optional


# ── 1. Reassemble multi-line log entries ────────────────────────────────────
#
# Each logical event starts with a line containing "[JS] ".
# Subsequent lines without "[JS] " are JSON continuation of the previous event.
# System noise (WebContent, GPU process, etc.) is discarded.

def _is_js_line(line: str) -> bool:
    return line.startswith("[JS] ")

def _is_noise(line: str) -> bool:
    noise_prefixes = (
        "GPU process", "Networking process", "WebContent[",
        "Invalidation", "Handle connection", "Encountered",
    )
    return any(line.startswith(p) for p in noise_prefixes)

def reassemble_entries(raw_lines: list[str]) -> list[str]:
    """Return list of complete log entry strings (multi-line JSON joined)."""
    entries = []
    current = None
    for line in raw_lines:
        line = line.rstrip("\n")
        if _is_noise(line):
            continue
        if _is_js_line(line):
            if current is not None:
                entries.append(current)
            current = line[len("[JS] "):]   # strip [JS] prefix
        elif current is not None:
            # Continuation line — append to current entry
            current += "\n" + line
    if current is not None:
        entries.append(current)
    return entries


# ── 2. Parse each entry into a structured dict ───────────────────────────────

# Patterns for single-line entries
_RE_OUT_URL   = re.compile(r'^\[AMF3:out:url\] (XHR )?POST (.+)$')
_RE_OUT_CALL  = re.compile(
    r'^\[AMF3:out:(?P<chan>\w+)\] callType=(?P<callType>\d+)'
    r' zoneID=(?P<zoneID>\S+)'
    r' actionType=(?P<actionType>\S+)'
    r' actionGrid=(?P<actionGrid>\S+)'
    r' data=(?P<data>.*)',
    re.DOTALL,
)
_RE_ACK       = re.compile(
    r'^\[AMF3:(?P<chan>\w+)\] ack type=(?P<type>\d+)'
    r' errorCode=(?P<errorCode>\d+)'
    r' full=(?P<json>\{.*)',
    re.DOTALL,
)
_RE_TIMING    = re.compile(
    r'^\[AMF3:spec:timing\] uid=(?P<uid>\S+) ct=(?P<ct>\d+)'
    r' bonus=(?P<bonus>\d+) serverClock=(?P<serverClock>\d+)$'
)
_RE_SPECIALISTS = re.compile(r'^\[AMF3:\w+\] specialists=(\d+) level=(\d+)$')
_RE_AUTH      = re.compile(r'^\[AMF3:auth\] ctx updated zoneID=(\S+) DSId=(\S+)$')
_RE_REALM_URL = re.compile(r'^\[AMF3:url\] realm updated: (.+)$')
_RE_CAPTURE_ERR = re.compile(r'^\[AMF3:out\] capture error: (.+)$')
_RE_PARSE_ERR = re.compile(r'^\[AMF3:\w+\] parse error .+$')


def _try_json(s: str) -> object:
    """Parse JSON, returning the object or the raw string on failure."""
    try:
        return json.loads(s)
    except Exception:
        # Truncated JSON is common — return what we have
        return s.strip()


def _collect_classes(obj, seen: set):
    """Recursively collect all __class values from a decoded JSON object."""
    if isinstance(obj, dict):
        cls = obj.get("__class")
        if cls:
            seen.add(cls)
        for v in obj.values():
            _collect_classes(v, seen)
    elif isinstance(obj, list):
        for item in obj:
            _collect_classes(item, seen)


def parse_entry(text: str) -> Optional[dict]:
    """Return a parsed event dict or None for unrecognised/empty entries."""
    text = text.strip()
    if not text:
        return None

    m = _RE_OUT_URL.match(text)
    if m:
        return {"kind": "out_url", "url": m.group(2).strip()}

    m = _RE_CAPTURE_ERR.match(text)
    if m:
        return {"kind": "capture_error", "error": m.group(1)}

    if _RE_PARSE_ERR.match(text):
        return {"kind": "parse_error", "raw": text}

    m = _RE_TIMING.match(text)
    if m:
        return {"kind": "timing", **m.groupdict()}

    m = _RE_SPECIALISTS.match(text)
    if m:
        return {"kind": "specialists_summary", "count": int(m.group(1)), "level": int(m.group(2))}

    m = _RE_AUTH.match(text)
    if m:
        return {"kind": "auth", "zoneID": m.group(1), "DSId": m.group(2)}

    m = _RE_REALM_URL.match(text)
    if m:
        return {"kind": "realm_url", "url": m.group(1).strip()}

    m = _RE_OUT_CALL.match(text)
    if m:
        data_raw = m.group("data").strip()
        data_obj = _try_json(data_raw) if data_raw and data_raw != "null" else None
        classes: set[str] = set()
        if isinstance(data_obj, dict):
            _collect_classes(data_obj, classes)
        return {
            "kind": "out_call",
            "channel": m.group("chan"),
            "callType": int(m.group("callType")),
            "zoneID": m.group("zoneID"),
            "actionType": m.group("actionType"),
            "actionGrid": m.group("actionGrid"),
            "data": data_obj,
            "classes": sorted(classes),
        }

    m = _RE_ACK.match(text)
    if m:
        ack_type = int(m.group("type"))
        error_code = int(m.group("errorCode"))
        json_obj = _try_json(m.group("json"))
        classes: set[str] = set()
        if isinstance(json_obj, dict):
            _collect_classes(json_obj, classes)
        return {
            "kind": "ack",
            "channel": m.group("chan"),
            "type": ack_type,
            "errorCode": error_code,
            "data": json_obj,
            "classes": sorted(classes),
        }

    if text.startswith("[TSO]") or text.startswith("[UnityProbe]") or text.startswith("[AMF3:rpc]"):
        return {"kind": "info", "raw": text}

    return {"kind": "unknown", "raw": text}


# ── 3. Build a report ────────────────────────────────────────────────────────

def _data_class(event: dict) -> str:
    """Return the innermost data __class from an ack, or '(null)'."""
    obj = event.get("data")
    if not isinstance(obj, dict):
        return "(null)"
    action_result = obj.get("data", {})
    if isinstance(action_result, dict):
        inner = action_result.get("data")
        if isinstance(inner, dict):
            return inner.get("__class") or "(null)"
    return "(null)"


def report(events: list, filter_type: Optional[int] = None,
           classes_only: bool = False):

    # ── All unique __class values ────────────────────────────────────────
    all_classes: set[str] = set()
    for e in events:
        for cls in e.get("classes", []):
            if cls:
                all_classes.add(cls)

    if classes_only:
        print("=== All __class values seen ===")
        for c in sorted(all_classes):
            print(" ", c)
        return

    # ── URL endpoints ────────────────────────────────────────────────────
    url_counts: Counter = Counter()
    capture_errors: Counter = Counter()
    for e in events:
        if e["kind"] == "out_url":
            # Normalise: strip query params, keep domain + path stem
            url = re.sub(r'\?.*$', '', e["url"])
            url_counts[url] += 1
        elif e["kind"] == "capture_error":
            capture_errors[e["error"]] += 1

    print("=== POST URL endpoints ===")
    for url, n in url_counts.most_common():
        print(f"  {n:4d}x  {url}")

    if capture_errors:
        print("\n=== Outbound capture errors (non-AMF bodies) ===")
        for err, n in capture_errors.most_common():
            print(f"  {n:4d}x  {err}")

    # ── Outbound calls ───────────────────────────────────────────────────
    out_calls = [e for e in events if e["kind"] == "out_call"]
    if filter_type is not None:
        out_calls = [e for e in out_calls if e["callType"] == filter_type]

    call_type_groups: dict[int, list[dict]] = defaultdict(list)
    for e in out_calls:
        call_type_groups[e["callType"]].append(e)

    print("\n=== Outbound call types ===")
    print(f"  {'callType':>10}  {'count':>5}  {'actionTypes':30}  data class")
    print("  " + "-" * 80)
    for ct, group in sorted(call_type_groups.items()):
        action_types = sorted({e["actionType"] for e in group})
        data_classes = sorted({
            e["data"].get("__class", "(none)")
            for e in group
            if isinstance(e.get("data"), dict)
        } | {"(null)" for e in group if not isinstance(e.get("data"), dict)})
        print(f"  {ct:>10}  {len(group):>5}  {', '.join(action_types):30}  {', '.join(data_classes)}")

    # ── Inbound acks ─────────────────────────────────────────────────────
    acks = [e for e in events if e["kind"] == "ack"]
    if filter_type is not None:
        acks = [e for e in acks if e["type"] == filter_type]

    ack_groups: dict[int, list[dict]] = defaultdict(list)
    for e in acks:
        ack_groups[e["type"]].append(e)

    print("\n=== Inbound ack types ===")
    print(f"  {'type':>10}  {'count':>5}  {'errorCodes':20}  innermost data class")
    print("  " + "-" * 80)
    for t, group in sorted(ack_groups.items()):
        error_codes = sorted({str(e["errorCode"]) for e in group})
        data_classes = sorted({_data_class(e) for e in group})
        print(f"  {t:>10}  {len(group):>5}  {', '.join(error_codes):20}  {', '.join(data_classes)}")

    # ── Detailed view for each filtered / interesting call type ──────────
    interesting = {61}  # buff opcode; add more as discovered
    if filter_type is not None:
        interesting = {filter_type}

    for ct in sorted(interesting & set(call_type_groups.keys())):
        print(f"\n=== Detail: outbound callType={ct} ===")
        for i, e in enumerate(call_type_groups[ct], 1):
            print(f"  [{i}] actionType={e['actionType']}  actionGrid={e['actionGrid']}")
            if isinstance(e.get("data"), dict):
                print(f"       data class : {e['data'].get('__class', '?')}")
                for k, v in e["data"].items():
                    if k != "__class":
                        print(f"         {k}: {v}")

    for t in sorted(interesting & set(ack_groups.keys())):
        print(f"\n=== Detail: inbound ack type={t} ===")
        for i, e in enumerate(ack_groups[t], 1):
            print(f"  [{i}] errorCode={e['errorCode']}")
            obj = e.get("data")
            if isinstance(obj, dict):
                action_result = obj.get("data", {})
                inner = action_result.get("data") if isinstance(action_result, dict) else None
                if isinstance(inner, dict):
                    print(f"       inner class: {inner.get('__class', '?')}")
                    for k, v in inner.items():
                        if k != "__class":
                            if isinstance(v, dict):
                                print(f"         {k}: {{__class: {v.get('__class', '?')}, ...}}")
                            else:
                                print(f"         {k}: {v}")

    # ── All __class values ───────────────────────────────────────────────
    print(f"\n=== All __class values seen ({len(all_classes)} unique) ===")
    for c in sorted(all_classes):
        print(" ", c)


# ── 4. Entry point ───────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]

    log_file = "logs.md"
    filter_type = None
    classes_only = False

    i = 0
    while i < len(args):
        if args[i] == "--type" and i + 1 < len(args):
            filter_type = int(args[i + 1])
            i += 2
        elif args[i] == "--classes":
            classes_only = True
            i += 1
        elif not args[i].startswith("--"):
            log_file = args[i]
            i += 1
        else:
            i += 1

    with open(log_file, encoding="utf-8", errors="replace") as f:
        raw = f.readlines()

    entries = reassemble_entries(raw)
    events = [e for raw_e in entries for e in [parse_entry(raw_e)] if e is not None]

    report(events, filter_type=filter_type, classes_only=classes_only)


if __name__ == "__main__":
    main()
