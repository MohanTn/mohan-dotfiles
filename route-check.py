import json
import sys

manifest = json.load(open(".ai-memory/manifest.json"))


def match(text):
    t = text.lower()
    routes = [r for r in manifest.get("routes", [])
              if any(kw.lower() in t for kw in r["keywords"])]
    routes.sort(key=lambda r: r.get("priority", 0), reverse=True)
    return routes[0]["file"] if routes else ""


assert match("please format this markdown file") == "", "expected no match"
assert match("why is nix flake check failing") == "diagrams/debug/playbook.mmd"
print("route logic OK (empty on no match, priority pick on match)")
