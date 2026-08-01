---
name: sketch-design
description: Co-author a feature design on a sketch-learn canvas through the sketch-learn MCP server — scaffold a fill-in section template, draft what the repo can ground, let the human fill the rest, review it in rounds until every section is green, then implement strictly from it. Every read and write goes through MCP tools, never through the page's JSON file. Use when the user describes a feature they want designed before it is built, says "design doc", "sketch design", or asks to review or implement an existing sketch-learn design page.
---

# sketch-design: design a feature on a sketch-learn canvas, via MCP only

The design lives on a **sketch-learn page** — a canvas of labelled section boxes the human edits in the
browser and you edit through MCP tools. You draft, the human decides, you review in rounds, and only
when the whole board is green do you write code from it.

## Prime directive: the file is not yours to touch

`data/pages/*.json` and `*.excalidraw` files are the MCP server's storage, not documents to edit.

**Never** use Read, Write, Edit, `cat`, `jq`, or a shell redirect on a page file — not to peek, not to
"just fix one label". The frontend holds the same page in memory and autosaves; a direct write is
silently overwritten, or it clobbers what the human just typed. Every read and every write goes
through the tools below. If a tool cannot express the change, say so and ask, do not reach for the file.

## Token discipline (this is why the tools exist)

A design page is ~6k tokens of Excalidraw geometry and ~500 tokens of actual content. `get_page` pulls
all of it. `get_page_outline` pulls the content only, ~93% cheaper.

1. **`get_page_outline` first, every single time.** It returns per section: `key`, `heading`, `status`,
   `chars`, and a 90-char `preview`. That is usually enough to decide what to do next.
2. **`get_section` only for sections you will actually act on.** The outline's `chars` tells you if a
   section changed since you last read it — unchanged means do not re-read.
3. **`get_page` almost never.** Only when you need element ids or geometry (to place a comment, add a
   diagram element, or delete something). Never to read text.
4. **Never re-read what you just wrote.** `set_section` confirms; trust it.
5. One `set_section` per section you actually changed. Do not rewrite a section to change one line.

## Tools

| Tool | Use |
|---|---|
| `list_pages` | Find the page name when the user is vague. |
| `create_design_doc` | Scaffold a new design page. Fails if the name exists — that is a guard, not an error to route around. |
| `get_page_outline` | The default read. Sections, status, size, preview. |
| `get_section` | Full text of one section, by key. |
| `set_section` | Replace one section's text and set its status. **The only way to write design content.** |
| `add_comment` | A red 💬 note on the canvas — use for a question aimed at the human. |
| `add_element` / `delete_element` | Real (non-comment) canvas content, e.g. a diagram beside a section. |
| `edit_element` | Nudge an existing element's text, position, or colour. |
| `save_page_review` | Structured per-section verdicts stored off-canvas. Optional, prefer status colours + comments. |

Default section keys: `problem`, `goals`, `nongoals`, `design`, `datamodel`, `api`, `flows`,
`edgecases`, `testplan`, `questions`, `decisions`, `files`.

## Status is the state machine

`set_section`'s status recolours the box on the canvas, so the human sees progress at a glance:

- `empty` — grey. Untouched scaffold prompt. Nobody has said anything yet.
- `draft` — black. Content exists. Yours or theirs, not yet agreed.
- `review` — orange. **You are blocked on the human here.** Always pair with a specific question.
- `done` — green. Agreed, specific, and implementable.

Never mark `done` to be agreeable. Orange is the useful colour — it is how the human knows where to look.

---

## Mode A — Scaffold (user describes a feature)

1. Derive a slug from the feature name: lowercase, spaces to hyphens (`"OTP login"` → `otp-login`).
2. `create_design_doc(name: "<slug>", title: "<Feature Name>")`.
3. **Read the repo, then draft what you can actually ground.** For every section you can fill from real
   code — existing file paths, real class and table names, the conventions this codebase already uses —
   `set_section(..., status: "draft")`. This is the point: the human should arrive at a board that is
   already half-argued, not twelve empty boxes.
4. Sections that genuinely need a human decision: `set_section` with the question stated plainly and
   `status: "review"`. Put every unresolved choice in `questions` too, one per line, with the options
   and your recommendation.
5. Leave a section `empty` only when you have nothing honest to say about it.
6. Report: page name, which sections are green/orange, and the specific questions. Tell the user to open
   the canvas and fill in the orange ones.

**Ground everything.** A section invented from generic best practice is worse than an empty one, because
it looks decided. If you did not read the code that a claim rests on, do not make the claim.

## Mode B — Review round (user filled things in and wants another pass)

Expect several of these. Each one should visibly move boxes toward green.

1. `get_page_outline`.
2. Read (via `get_section`) only: sections whose `chars` changed since your last pass, plus anything
   still `empty` or `review`.
3. For each, decide honestly:
   - Specific, grounded, implementable → `set_section(..., status: "done")`, text unchanged if it is
     already right. Do not reword someone's prose to feel useful.
   - Nearly there, and you can close the gap from the repo → extend it, `status: "draft"`, and say what
     you added.
   - Vague in a way only the human can resolve → sharpen it into a **specific** question,
     `status: "review"`, and `add_comment` next to that section on the canvas.
4. Cross-check the board, this is where the value is: goals with no test in `testplan`, an API with no
   error cases in `edgecases`, a `files` manifest missing something `design` clearly requires, a
   decision in `decisions` that contradicts `design`. Raise these as comments.
5. Close the loop on `questions` — anything the human answered moves into `decisions` with the reasoning,
   and out of `questions`.
6. Report: counts by status, what you changed, and the shortest list of what still blocks `done`.

## Mode C — Implement (user says build it)

1. `get_page_outline`.
2. **Gate.** If any section is not `done`, or `questions` still holds an unresolved item, stop and list
   exactly what is open. Do not implement past an open question — that is the whole point of the board.
3. `get_section` for `design`, `datamodel`, `api`, `flows`, `edgecases`, `testplan`, `files`. Skip
   `problem`/`goals`/`nongoals` unless something downstream is ambiguous without them.
4. Build in `files` manifest order. The doc is the spec: do not add abstractions it does not ask for, and
   do not quietly drop things it does ask for.
5. If the code contradicts the design once you are in it — the design is impossible, or plainly wrong —
   **stop, say so, and update the affected section via `set_section(status: "review")`.** Never silently
   deviate. The board must stay the truth of what was built.
6. Write the tests `testplan` names, and run them.

---

## Notes

- The MCP server launches `server` and `frontend` itself, so the canvas is already running. Point the
  user at the `[frontend]` URL in the log rather than starting anything yourself.
- `create_design_doc` accepts a custom `sections` array (`{key, heading, hint}`) when the default twelve
  do not fit the work — a spike or a migration may want a different board. Ask before replacing them.
- Diagrams beat prose in `design` and `flows`. Use `add_element` to draw the boxes and arrows on the
  canvas next to the section instead of describing the shape in words.
- One design per page. If the feature splits, make a second page and cross-reference by name.
