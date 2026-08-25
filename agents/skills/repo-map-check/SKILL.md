---
name: repo-map-check
description: Check .claude/repo-map.md for cached file inventory before running filesystem queries.
---

# Repo Map Check

Before `ls`/`find`/file-structure queries on tracked dirs, check `.claude/repo-map.md` (e.g. `## agents/skills`) and use its listing instead.

Run filesystem queries only if: repo-map.md lacks the dir, or live state (perms/contents/freshness) is required.
