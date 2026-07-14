---
name: token-efficiency
description: "Audit and optimize token consumption in Claude Code configs: agent prompts, slash commands, hook injection scripts, and skill files. Use when reviewing config for redundancy, narrative bloat, or per-turn hook costs."
---

# token-efficiency: Audit and optimize token consumption in Claude Code configs

Apply evidence-based token-reduction techniques to Claude Code prompt files, hook injection scripts, skill files, and slash-command instructions. Identify waste without sacrificing clarity or functionality.

## Scope

This skill targets:
- Agent prompt files (`claude/agents/*.md`)
- Slash-command prompts (`claude/commands/*.md`)
- Skill files (`claude/skills/<x>/SKILL.md`)
- Hook scripts that inject context into every turn or session (`claude/hooks/*.sh`)
- Config JSON files loaded at startup (not injected into model context)

**Out of scope:** Code logic, test content, runtime behavior. Only text that enters the model's context window.

## Decision tree: Is this optimization safe?

### Safe to cut (high confidence)

1. **Redundant block repeats within a single file** — same prose/examples appearing twice in the same prompt.
   - Example: "JSON Output Format" section followed by a worked example with the same schema block.
   - Fix: keep one canonical version, point to it from the other location.
   - Risk: none if the pointer is clear.

2. **Verbose preamble/explanation** — conversational narrative that restates requirements already stated more concisely elsewhere.
   - Example: "This command generates feature-specific architecture... which merges into a pre-built HTML template. This two-stage approach..." (narrative) vs. "Generate feature architecture as structured JSON (injected into HTML template by a deterministic script)." (directive).
   - Fix: state the essential directive in one sentence, cut the narrative.
   - Risk: none if the shortened version still answers "what does this do?"

3. **Redundant phrasing in step lists** — explanation text duplicated across numbered steps.
   - Example: Each section check in Self-retrospection preamble + list items both explaining the same check.
   - Fix: list the checklist; cut the preamble that paraphrases it.
   - Risk: none if the checklist items are clear on their own.

4. **Hook output prose independent of parsing logic** — instructional text surrounding regex/grep patterns.
   - Example: Hook injects "State your working goal for this turn as a single line: GOAL: <one-sentence objective>" but only the literal string "GOAL:" is parsed by downstream hooks.
   - Fix: shorten prose ("State this turn's goal: GOAL: ...") but keep the regex-matched token verbatim.
   - Risk: none if you verify downstream tools still match the token.

### Risky / Don't cut (low confidence)

1. **Completeness constraints or acceptance criteria** — prose in "MANDATORY" sections, contracts, gates.
   - Don't shorten these; they define what "done" means.

2. **Few-shot examples in prompts** — full worked examples the model learns from.
   - Cut only if you replace them with a clear reference ("per the schema in Section X above") and verify the model still generates correct output.

3. **Section-by-section guidance for repetitive, open-ended content** (e.g., "Section 2 must have Mermaid flowchart, functional requirements table, non-functional requirements table").
   - These are dense but necessary; model needs the full specification.

4. **State/metadata parsing logic or regex patterns** — hooks, test files, scripts that depend on exact string matching.
   - Never edit to save tokens; verify hook tests still pass.

## Methodology: find and audit waste

### Step 1: Map the text cost per invocation

For each file:
- **Agent prompts** (`claude/agents/scout.md`, `implementer.md`, etc.): loaded once per feature-team run. Infrequent but high-context.
- **Skills** (`claude/skills/<x>/SKILL.md`): loaded when the skill is invoked or discovered at startup, depending on the skill.
- **Slash-command prompts** (`claude/commands/arch.md`): loaded on every `/arch` invocation. Frequent for that command.
- **Hooks** (`claude/hooks/user-prompt-submit.sh`, `claude/hooks/session-start.sh`): injected on every turn (per-turn hooks) or once per session (startup hooks). Recurring cost across all projects.

### Step 2: Search for candidate bloat

Grep for patterns:
- Redundant block: `grep -n "^##" file.md | uniq -d` or manually scan for section titles and check for repeated content blocks.
- Verbose preamble: look for narrative paragraphs (lines starting with story-like language: "This command...", "You are...") followed by directive bullets that say the same thing.
- Hook redundancy: search hook scripts for repeated prose in multiple files; same injected text across Claude hooks.
- Explanatory overhead: `wc -w` sections and compare dense (bullet list) vs. narrative (paragraph) versions of the same idea.

### Step 3: Verify safety before cutting

For each candidate:
1. **Redundancy test:** Does a shorter version still convey the essential information? Can it be replaced with a reference ("per the schema above")?
2. **Parsing test:** For hooks, does `grep`, `sed`, or regex logic depend on this exact wording? (Check `claude/hooks/test-hook.sh`.)
3. **Necessity test:** Is this a "MANDATORY" section or acceptance criterion? Keep it intact.
4. **Port test:** If you cut something in `claude/commands/arch.md`, the same cut must land in `copilot/skills/arch/SKILL.md` to keep ports in sync.

### Step 4: Apply and verify

1. Make the edit.
2. Run `claude/hooks/test-hook.sh selftest` if hooks changed.
3. Run `claude/hooks/test-hook.sh list` to confirm HOOK_INFO still matches.
4. Run `nix flake check --impure` if in this repo.
5. Spot-check by running the command/agent once with real input and verify output is still correct.
6. Measure: `wc -w` before/after and report savings in tokens (assume ~1 token per 1.3 words).

## Patterns seen in mohan-dotfiles

### JSON schema deduplication (safe, moderate savings)

**Pattern:** A prompt file specifies a JSON output shape in an "Output Format" section, then shows the same schema again as a worked example in an "Implementation" or "Example" section.

**Example:** `claude/commands/arch.md` lines 113-143 (schema definition) + lines 184-204 (schema in Mode A example).

**Fix:** Keep the canonical definition in "Output Format." In examples, replace the full skeleton with a pointer: "Assemble the JSON structure per the schema in 'JSON Output Format' above, populated with this feature's real content."

**Savings:** ~30-50 words per file (schema block is typically dense).

**Verification:** None required beyond reading the file; the schema is not executed, only read by the model.

### Hook output trimming (safe, per-turn cost)

**Pattern:** Hook scripts inject context into every substantive turn across all projects (e.g., `claude/hooks/user-prompt-submit.sh`). Trimming saves tokens on every single turn.

**Example:** Original "State your working goal for this turn as a single line: GOAL: <one-sentence objective>..." → trimmed "State this turn's goal: GOAL: <one-sentence objective>".

**Fix:** Identify the literal token being parsed downstream (`^GOAL:`, `GOAL_CHECK:`), keep it verbatim, trim the surrounding prose.

**Savings:** ~67 chars per turn (~17 tokens), multiplied by number of turns per session, across all projects.

**Verification:** Run `claude/hooks/test-hook.sh selftest` to confirm parsing still works.

### Preamble condensing (safe, moderate savings)

**Pattern:** Command or agent prompt begins with conversational narrative explaining what it does, followed by bullet points that say the same thing more concisely.

**Example:** Original 4-line preamble + explanation vs. one-sentence directive: "Generate feature architecture as structured JSON (injected into HTML template by a deterministic script, not regenerated each pass)."

**Fix:** Replace narrative with a single clear directive sentence.

**Savings:** ~150-300 words per file.

**Verification:** Run the command/agent once and verify output quality hasn't degraded.

## Red flags: Don't optimize these

- **"MANDATORY" sections** (completeness contracts, acceptance criteria): keep full.
- **Checklist-style requirements** (every section 0-10 must have X, Y, Z): dense but non-negotiable.
- **Mermaid/syntax requirements** in code prompts: cut at your peril (models need explicit syntax guidance).
- **Test assertions:** never edit test text to match a shortened prompt; instead, update the prompt *then* update tests to match.

## Example: full audit of `arch.md`

### Candidate 1: Preamble (lines 1-5)

**Before:**
```
# arch: Feature architecture template via JSON → HTML injection

You are the Senior Solution Architect...working under the Fable charter...
This command generates feature-specific architecture...which merges...
This two-stage approach eliminates...and cuts token consumption by ~75%...
```

**After:**
```
# arch: Feature architecture template via JSON → HTML injection

Generate feature architecture as structured JSON (injected into HTML template by a deterministic script, not regenerated each pass).
```

**Safe?** Yes. The essential directive is: generate JSON, it gets injected, no regeneration. Rest is narrative. ✅

---

### Candidate 2: "Before generating" section (lines 30-34)

**Before:**
```
- Glance at the repo for real stack details, existing API/endpoint style, data layer, React component conventions, naming patterns. Reuse them.
- Do NOT do web research. Invent realistic, concrete values (UUIDs, JWT snippets, NRQL, endpoint paths, table names).
- If something is genuinely unknown, make a sensible, explicitly-stated assumption in Section 1 AND raise it as an Open Question in Section 10 so the user can correct it next pass.
```

**After:**
```
- Research repo stack, API patterns, conventions; reuse real names and styles.
- Invent realistic concrete values (UUIDs, JWT snippets, paths, table names). Never do web research.
- Unknown values: state as an assumption in Section 1, raise as an Open Question in Section 10.
```

**Safe?** Yes. Same requirements, tighter phrasing. ✅

---

### Candidate 3: Duplicate JSON schema (lines 117-143 + 184-204)

**Before:** Full schema shown twice (30 lines each).

**After:** Lines 184-204 become: "Assemble the JSON structure per the schema in 'JSON Output Format' above, populated with this feature's real content."

**Safe?** Yes, with verification. Model needs to understand the shape; pointing to a definition 60 lines up works if the definition is clear. Verify by running the command once and checking output is valid. ✅

---

### Candidate 4: "Self-retrospection" preamble (lines 162-170)

**Before:**
```
Re-read the entire generated file end-to-end:
- **Completeness:** every section 0–10 filled; no banned placeholder strings.
- **Ambiguity sweep:** find vague phrases...
- **Open-ended features:** any capability without inputs...
- ...
Report what was found and fixed, and list any Open Questions the user must answer.
```

**After:**
```
Before saving, verify:
- Completeness: every section 0–10 filled; no TBD/placeholder strings.
- No vague phrases; ambiguities are precise Open Questions in Section 10.
- Names consistent across sections; version matches revision log.
- Mermaid syntax valid for each diagram type.

Report findings and the Open Questions the user must resolve.
```

**Safe?** Yes. Tighter checklist, same requirements. ✅

## Final checklist

Before shipping any token-reduction edit:

- [ ] Identified the specific waste (redundancy, narrative, verbose prose).
- [ ] Verified it's safe to cut (not a constraint, not parsed logic, not few-shot example).
- [ ] Applied the same cut to all ports (`claude/commands/<x>.md` → `copilot/skills/<x>/SKILL.md`).
- [ ] Ran test suites (`claude/hooks/test-hook.sh selftest` etc.); all pass.
- [ ] Spot-checked the command/agent with real input; output quality unchanged.
- [ ] Measured word reduction and noted in PR/commit.
