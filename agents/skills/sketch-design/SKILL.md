---
name: sketch-design
description: Co-author a system-design sketch on an .excalidraw canvas through the sketch-learn MCP server — drop in a pre-built template or build a custom board, draft what the repo can ground, let the human fill the rest, review it in rounds until every box is green, then implement strictly from it. Every read and write goes through the MCP tools (get_summary, get_element, search_text, update_element, add_elements, get_template, commit), never through the file itself. Use when the user describes a feature they want designed before it is built, says "design doc", "sketch design", "system design", or asks to review, annotate, or implement an existing .excalidraw sketch.
---

# sketch-design: design on an .excalidraw canvas, via MCP only

The design lives on an **.excalidraw file** the human edits in the browser and you edit through MCP
tools. Every tool is addressed by absolute `file_path` — there are no page names and no database. You
draft, the human decides, you review in rounds, and only when the whole board is green do you write
code from it.

## Prime directive: the file is not yours to touch

**Never** use Read, Write, Edit, `cat`, `jq`, or a shell redirect on an `.excalidraw` file — not to
peek, not to "just fix one label".

Two things clobber a direct write: the MCP server holds the whole scene in an in-memory cache and the
next `commit` overwrites whatever you wrote behind its back, and the frontend holds the same scene and
autosaves over it. Every read and every write goes through the tools below. If a tool cannot express
the change, say so and ask — do not reach for the file.

## Getting the file path

Every call needs an **absolute** path ending in `.excalidraw`.

- The user named a file → use it, expanded to absolute.
- The user named a feature but no file → propose `<repo>/data/pages/<slug>.excalidraw` (slug =
  lowercase, spaces to hyphens: `"OTP login"` → `otp-login`) and say the path you picked.
- Ambiguous or several candidates → ask. Do not guess and create a stray file.

Note the sketch-learn frontend's Load list only shows pages that were saved *from* the frontend. A
file you create through MCP opens fine in excalidraw.com or the desktop app, and the frontend can open
it once the human saves it under a name there.

## Token discipline (this is why the tools exist)

A design canvas is thousands of tokens of Excalidraw geometry and a few hundred tokens of content.

1. **`get_summary` first, every single time.** One `{ id, type, text, bbox }` row per element. That is
   usually all you need to decide what to do next.
2. **`get_element` only when you need the full JSON** of one element you are about to patch in a way
   that depends on its current styling. Reading text does not need it — `get_summary` has the text.
3. **`get_elements_by_type(file_path, "text")`** when you want the written content and nothing else.
4. **Patch, never rewrite.** `update_element` takes a JSON patch of just the keys that change.
5. **Never re-read what you just wrote.** The write tools echo the result back; trust it.
6. **One `commit` per batch**, at the end. Not after every patch.

## Tools

| Tool | Use |
|---|---|
| `get_summary(file_path)` | The default read. Every element as `{ id, type, text, bbox }`. |
| `get_element(file_path, element_id)` | Full JSON of one element. Rare. |
| `get_elements_by_type(file_path, type)` | `{ id, text, x, y }` for one type — `text`, `rectangle`, `arrow`, … |
| `search_text(file_path, pattern)` | Case-insensitive regex over element text. How you find `@AI:` notes and locate a section by its label. |
| `update_element(file_path, element_id, patch)` | Shallow-merge a patch onto one element. `id` and `type` are not patchable. |
| `add_elements(file_path, elements)` | Append partial elements; defaults and ids are filled in for you. |
| `get_template(file_path, feature)` | Drop a pre-built system design onto the canvas. Writes to disk immediately. |
| `commit(file_path)` | Flush every pending patch to disk. **Nothing you changed is durable until this runs.** |

Pre-built features for `get_template`: `e-commerce`, `social-media`, `iot-dashboard`,
`task-management`, `ride-hailing`. Each lands a title plus four labelled section boxes on a
two-column grid.

## Status is the state machine

There is no status field — status is the section rectangle's `backgroundColor`, set with
`update_element`, so the human sees progress at a glance in the browser:

| Colour | Patch | Meaning |
|---|---|---|
| Grey | `{ "backgroundColor": "#f1f3f5" }` | `empty` — untouched scaffold. Nobody has said anything yet. |
| Blue | `{ "backgroundColor": "#e7f5ff" }` | `draft` — content exists, yours or theirs, not yet agreed. Templates land here. |
| Orange | `{ "backgroundColor": "#fff4e6" }` | `review` — **you are blocked on the human.** Always pair with a specific question. |
| Green | `{ "backgroundColor": "#ebfbee" }` | `done` — agreed, specific, implementable. |

Never mark a box green to be agreeable. Orange is the useful colour — it is how the human knows where
to look.

## Writing into a section

A section is a rectangle plus a text element near its top-left. Its body text is a separate text
element inside the same bbox.

- **Find it**: `search_text(file_path, "<label>")` gives the label element's id; `get_summary` gives
  every element's bbox, so the body is the text element whose bbox falls inside the rectangle's.
- **Change existing body text**: `update_element(..., { "text": "..." })`.
- **Add body text where there is none**: `add_elements` with
  `{ "type": "text", "text": "...", "x": <box.x + 16>, "y": <box.y + 56>, "width": <box.width - 32> }`.
- **Leave a question for the human**: a red note beside the box —
  `{ "type": "text", "text": "💬 <specific question>", "strokeColor": "#e03131", "x": <box.x>, "y": <box.y + box.height + 8> }`.
- **Remove an element**: there is no delete tool. `update_element(..., { "isDeleted": true })` — Excalidraw
  filters those out on load.

Excalidraw does not wrap text for you. Keep a line under ~40 characters at the default font size, and
break longer content into `\n`-separated lines that fit the box width.

---

## Mode A — Create the board (user describes a feature)

1. Settle the file path (see above) and state it.
2. **Pick the starting board:**
   - The feature matches a pre-built one → `get_template(file_path, "<feature>")`. Fastest path, and it
     writes to disk immediately.
   - It does not → build a custom board with `add_elements`: a title text at `(40, 40)`, then one
     rectangle per section on a two-column grid — `320x180`, origin `(40, 120)`, `60` gaps — each with
     its label text at `(box.x + 16, box.y + 16)`. Sensible default sections when the work has no
     obvious shape: Problem, Goals, Non-goals, Design, Data model, API, Flows, Edge cases, Test plan,
     Open questions.
3. **Read the repo, then draft what you can actually ground.** For every section you can fill from real
   code — existing file paths, real class and table names, conventions this codebase already uses —
   add the body text and paint the box **blue**.
4. Sections that genuinely need a human decision: state the question plainly in the box, paint it
   **orange**, and add a red 💬 note with the options and your recommendation.
5. Leave a box **grey** only when you have nothing honest to say about it.
6. `commit(file_path)`.
7. Report: the file path, which boxes are green/orange/grey, and the specific questions. Tell the user
   to open the canvas and fill in the orange ones.

**Ground everything.** A section invented from generic best practice is worse than an empty one,
because it looks decided. If you did not read the code a claim rests on, do not make the claim.

## Mode B — Review round (user filled things in and wants another pass)

Expect several of these. Each one should visibly move boxes toward green.

1. `get_summary(file_path)`.
2. `search_text(file_path, "@AI")` — the human leaves instructions for you as ordinary text on the
   canvas (`@AI: tighten this section`). Act on each one, then clear it with
   `update_element(..., { "isDeleted": true })` so it does not come back next round.
3. Compare against your last pass. Read further only where the text actually changed, plus anything
   still grey or orange.
4. For each section, decide honestly:
   - Specific, grounded, implementable → paint it **green**, text unchanged if it is already right. Do
     not reword someone's prose to feel useful.
   - Nearly there and you can close the gap from the repo → extend the text, keep it **blue**, and say
     what you added.
   - Vague in a way only the human can resolve → sharpen it into a **specific** question, paint it
     **orange**, and add a red 💬 note beside that box.
5. Cross-check the board — this is where the value is: a goal with no test in the test plan, an API
   with no error cases in edge cases, a file manifest missing something the design clearly requires, a
   decision that contradicts the design. Raise each as a 💬 note.
6. Close the loop on open questions: anything the human answered moves into the decisions/design text
   with its reasoning, and out of the questions box.
7. `commit(file_path)`.
8. Report: counts by colour, what you changed, and the shortest list of what still blocks green.

## Mode C — Implement (user says build it)

1. `get_summary(file_path)`.
2. **Gate.** If any box is not green, or the open-questions box still holds an unresolved item, stop
   and list exactly what is open. Do not implement past an open question — that is the whole point of
   the board.
3. `get_elements_by_type(file_path, "text")` to pull the full written design in one cheap call.
4. Build in the order the design's file manifest gives. The board is the spec: do not add abstractions
   it does not ask for, and do not quietly drop things it does ask for.
5. If the code contradicts the design once you are in it — the design is impossible, or plainly wrong —
   **stop, say so, repaint that box orange with the problem written in it, and `commit`.** Never
   silently deviate. The board must stay the truth of what was built.
6. Write the tests the test plan names, and run them.

---

## Notes

- The MCP server launches `server` and `frontend` itself, so the canvas is already running. Point the
  user at the `[frontend]` URL in the log rather than starting anything yourself.
- Forgetting `commit` is the one failure mode that loses work silently. If a round ends without a
  write tool being called, no commit is needed — otherwise always commit before reporting.
- Diagrams beat prose in the design and flows sections. `add_elements` draws real boxes and arrows next
  to a section; use them instead of describing the shape in words.
- One design per file. If the feature splits, make a second file and cross-reference by path.
