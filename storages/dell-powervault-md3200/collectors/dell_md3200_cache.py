#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import time

CACHE_ROOT = "/var/lib/zabbix/md3200-cache"


def safe_component(value):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value or "unset")


def cache_path(mode, ip_a, ip_b):
    key = "%s__%s" % (safe_component(ip_a), safe_component(ip_b))
    return os.path.join(CACHE_ROOT, key, "%s.json" % mode)


def failure(mode, message, age=-1):
    return {
        "version": "1.1.0-cache",
        "mode": mode,
        "available": 0,
        "return_code": 1,
        "duration_ms": 0,
        "collected_at": 0,
        "cache_age": age,
        "cache_stale": 1,
        "errors": message,
        "errors_count": 1,
    }


def main():
    parser = argparse.ArgumentParser(description="Read cached Dell MD3200 JSON")
    parser.add_argument("mode", choices=("health", "inventory", "performance"))
    parser.add_argument("ip_a")
    parser.add_argument("ip_b")
    parser.add_argument("max_age", nargs="?", type=int, default=600)
    args = parser.parse_args()

    path = cache_path(args.mode, args.ip_a, args.ip_b)
    now = int(time.time())

    try:
        stat = os.stat(path)
        age = max(0, now - int(stat.st_mtime))
    except FileNotFoundError:
        print(json.dumps(failure(args.mode, "Cache not initialized: %s" % path), ensure_ascii=False, separators=(",", ":")))
        return 0
    except Exception as exc:
        print(json.dumps(failure(args.mode, "Cannot stat cache: %s" % exc), ensure_ascii=False, separators=(",", ":")))
        return 0

    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception as exc:
        print(json.dumps(failure(args.mode, "Cannot read cache: %s" % exc, age), ensure_ascii=False, separators=(",", ":")))
        return 0

    data["cache_age"] = age
    data["cache_stale"] = 1 if age > max(1, args.max_age) else 0
    if data["cache_stale"]:
        previous = str(data.get("errors", "")).strip()
        stale = "Cache stale: %s seconds (limit %s)" % (age, args.max_age)
        data["errors"] = (previous + " | " + stale).strip(" |")
        data["errors_count"] = int(data.get("errors_count", 0) or 0) + 1
        data["available"] = 0
    print(json.dumps(data, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
