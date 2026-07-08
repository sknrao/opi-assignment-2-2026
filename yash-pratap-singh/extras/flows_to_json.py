#!/usr/bin/env python3
"""Parse `ovs-ofctl dump-flows` text output into structured JSON.

ovs-ofctl has no native --format=json flag (as of OVS 3.x), so this script
does the equivalent transformation the OVS `ofparse` tool would do.
"""
import json, re, sys

NUMERIC = {"duration", "n_packets", "n_bytes", "priority", "table", "idle_age", "hard_age", "cookie"}

def parse_flow(line: str) -> dict:
    m = re.search(r"\bactions=(.*)$", line)
    actions = m.group(1).strip() if m else ""
    head = line[:m.start()].strip().rstrip(",") if m else line.strip()

    fields = {}
    match_tokens = []
    for tok in [t.strip() for t in head.split(",") if t.strip()]:
        if "=" in tok:
            k, v = tok.split("=", 1)
            k = k.strip(); v = v.strip().rstrip("s")
            if k in NUMERIC:
                try:
                    fields[k] = float(v) if "." in v else int(v, 0)
                except ValueError:
                    fields[k] = v
            else:
                match_tokens.append(f"{k}={v}")
        else:
            match_tokens.append(tok)

    if match_tokens:
        fields["match"] = ",".join(match_tokens)
    fields["actions"] = actions
    return fields

def main():
    raw = sys.stdin.read().splitlines()
    flows = [parse_flow(l) for l in raw if "cookie=" in l or "duration=" in l]
    json.dump(flows, sys.stdout, indent=2)
    sys.stdout.write("\n")

if __name__ == "__main__":
    main()
