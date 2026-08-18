import json

manifest = json.load(open(".ai-memory/manifest.json"))


def match(text):
    """Mirror of ai_memory_match_route: a 'diagram' key wins for every prompt,
    otherwise fall back to the legacy keyword routes."""
    if manifest.get("diagram"):
        return manifest["diagram"]
    t = text.lower()
    routes = [r for r in manifest.get("routes", [])
              if any(kw.lower() in t for kw in r["keywords"])]
    routes.sort(key=lambda r: r.get("priority", 0), reverse=True)
    return routes[0]["file"] if routes else ""


assert match("please format this markdown file") == "diagrams/system.mmd"
assert match("why is nix flake check failing") == "diagrams/system.mmd"
print("route logic OK (one diagram per repo, injected on every prompt)")
