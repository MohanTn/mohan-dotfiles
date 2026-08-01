---
name: resolve-ai-notes
description: Resolve every "@AI" instruction left on a sketch-learn canvas page. A human leaves a note like "@AI tighten this section" as ordinary text anywhere on the page; this skill finds each one via the sketch-learn MCP server, edits the section it points at, clears the note, and loops until none remain. Use when the user says "check/resolve/address the @AI comments/notes on page X", "review page X for @AI notes and update it", or names this skill directly.
---

# resolve-ai-notes: close every @AI note on a sketch-learn page, end to end

A human never asks the app itself to change a diagram — they write `@AI: ...` as a plain text element on
the canvas, in or near the part they want changed, and hand the page name to the attached agent. This
skill is the loop that turns that into a finished, note-free page.

## Prime directive: MCP tools only, never the file

`data/pages/*.excalidraw` is the MCP server's storage. Never `Read`/`Edit`/`cat`/`jq`/shell-redirect it —
the frontend has the same page open and autosaves, so a direct write gets silently clobbered or clobbers
what the human just typed. Every read and write below goes through an MCP tool.

## Tools

| Tool | Use |
|---|---|
| `find_ai_notes` | The worklist. Scans the named page's text elements for `/@ai\b/i` and returns each match's `elementId`, `text`, `x`, `y`. Cheap — no geometry. **Call this first, and again after every fix, until it returns empty.** |
| `get_page` | Full elements (with `x`/`y`, and `customData.sl` when the page is a design doc). Needed once per pass to find what a note is *about* — nothing in `find_ai_notes`'s output tells you that on its own. |
| `get_section` / `set_section` | If the note's element carries `customData.sl.key`, this page is a `create_design_doc` board — read/replace that section's text directly, keep its `status`. Prefer this over `edit_element` whenever `sl.key` is present. |
| `edit_element` | For a freeform page (no `sl` tag): update the text/box the note is actually pointing at. |
| `delete_element` / `edit_element` | Clear the note itself once handled — delete it, or edit it to state what was done, per the human's apparent preference (see below). |

## Loop

1. `find_ai_notes(name)`. Empty list → done, report and stop.
2. If this is the first pass, `get_page(name)` once to get positions/`customData` for every element; reuse
   it for the whole pass instead of re-fetching.
3. For each note, work out what it is actually about:
   - **Design-doc page** (the note's element has `customData.sl.key`, or the page's `get_page_outline`
     lists sections): that key is the section. `get_section(name, key)` for full context if the preview
     isn't enough, make the change, `set_section(name, key, text, status)`.
   - **Freeform page** (no `sl` tags, e.g. a plain explainer diagram): the note is prose glued onto or
     near one box. From the `get_page` snapshot, find the element(s) whose position it sits inside or
     right after (same rectangle, or the nearest heading/body text above it in reading order) — that is
     the target. `edit_element` that target's `text`.
4. Make the actual content change the note asks for. Ground it in the real repo (file paths, tool names,
   behavior) the same way `sketch-design` grounds design sections — do not invent detail the note didn't
   ask for and the code doesn't support.
5. Clear the note: strip the `@AI: ...` clause from the element's text with `edit_element` (keep the rest
   of the text if the note was inline, like `"...edit_element ... @AI: add missing tool and description"`
   → drop only the `@AI:` clause), or `delete_element` if the whole element was nothing but the note.
6. Go to 1. A note can spawn another note (human or agent leaves a follow-up) — the loop, not a fixed
   count, is what decides when this is finished.

## Stopping short of the loop

If a note is genuinely ambiguous — it names a change only the human can decide (a design tradeoff, a
missing preference) — do not guess. Leave that one note in place, `add_comment` next to it asking the
specific question, and report it as blocked rather than looping forever on it. Resolve every other note
in the pass first.

## Report

One line per note resolved (element id or section key → what changed), plus any left blocked and why.
Do not claim "done" while `find_ai_notes` still returns matches — check it after the last edit, not just
after the last one you intended to make.
