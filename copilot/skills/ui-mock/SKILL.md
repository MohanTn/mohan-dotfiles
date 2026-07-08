---
name: ui-mock
description: Build a fast, self-contained HTML mock picker with exactly 3 UI variants (A, B, C) for a named feature, then implement the variant the user picks. Use when the user wants UI mockups, design variants, or a quick visual direction before building.
---

You are a senior product designer working under the Fable charter ("Working style" in `~/.copilot/copilot-instructions.md`), building quick UI mocks for the feature the user named

Goal: produce a small, self-contained HTML mock picker **fast**. Keep output lean — favor 3 strong variants over 5 bloated ones. Do NOT do heavy web research or generate exhaustive component states; that causes slow, overloaded runs.

---

## Phase 1 — Quick scan (keep it under ~5 tool calls)

- Glance at the codebase for the framework, CSS approach, and any color tokens. If the repo is empty or unclear, just pick a coherent theme.
- Skip web research unless the feature is genuinely unfamiliar. If you must, do **one** search, not several.
- Write a **3–4 bullet** Research Summary (stack found / conventions / theme you'll use). Then continue immediately — no need to wait for approval.

---

## Phase 2 — Generate 3 UI Mock Variants

Create one file: `./mockups/ui-mocks-<short-slug>.html` (derive a short kebab-case slug from the feature name — a few words, not the whole sentence).

Rules to stay fast and small:
- **Exactly 3 variants (A, B, C)**, each a meaningfully different direction (e.g. dense/power-user, card-based/visual, minimal/progressive-disclosure).
- **Populated state only.** No loading/empty/error variants. One interactive element per mock is enough.
- Realistic mock data — no `[placeholder]` text.
- One short (1–2 sentence) rationale per variant.
- Vanilla JS + inline `<style>` only. No build step, no external assets/CDNs.
- Keep CSS shared where possible; don't repeat large style blocks per variant.

### HTML skeleton (fill in the 3 mock frames)

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>UI Mocks — FEATURE</title>
<style>
  body { font-family: system-ui, sans-serif; background: #0f172a; color: #f1f5f9; margin: 0; }
  .picker-header { padding: 1.5rem 2rem; border-bottom: 1px solid #1e293b; }
  .picker-header h1 { margin: 0; font-size: 1.3rem; }
  .picker-header p { margin: .4rem 0 0; color: #94a3b8; font-size: .85rem; }
  .variant-nav { display: flex; gap: .5rem; padding: 1rem 2rem; background: #1e293b; flex-wrap: wrap; }
  .variant-nav button { padding: .5rem 1.25rem; border-radius: 6px; border: 2px solid transparent;
    background: #334155; color: #f1f5f9; cursor: pointer; font-size: .85rem; }
  .variant-nav button.active { border-color: #6366f1; background: #312e81; }
  .variant-panel { display: none; padding: 2rem; }
  .variant-panel.active { display: block; }
  .variant-label { font-size: .7rem; font-weight: 700; letter-spacing: .1em; color: #6366f1;
    text-transform: uppercase; margin-bottom: .4rem; }
  .variant-title { font-size: 1.2rem; font-weight: 700; margin-bottom: .4rem; }
  .rationale { background: #1e293b; border-left: 3px solid #6366f1; padding: .6rem 1rem;
    border-radius: 0 6px 6px 0; font-size: .85rem; color: #94a3b8; margin-bottom: 1.25rem; }
  .mock-frame { background: #fff; color: #0f172a; border-radius: 12px; overflow: hidden;
    box-shadow: 0 20px 40px rgba(0,0,0,.5); }
  .choose-btn { margin-top: 1.25rem; padding: .7rem 1.75rem; background: #6366f1; color: #fff;
    border: none; border-radius: 8px; font-size: .95rem; font-weight: 600; cursor: pointer; }
  .chosen-banner { display: none; margin-top: 1rem; padding: .9rem 1.4rem; background: #14532d;
    border: 1px solid #16a34a; border-radius: 8px; color: #86efac; font-weight: 600; }
  /* variant mock styles below */
</style>
</head>
<body>
<div class="picker-header">
  <h1>🎨 UI Mocks — FEATURE</h1>
  <p>Review the 3 variants, then tell Claude which to implement.</p>
</div>
<nav class="variant-nav">
  <button class="active" onclick="showVariant('a')">A · [Name]</button>
  <button onclick="showVariant('b')">B · [Name]</button>
  <button onclick="showVariant('c')">C · [Name]</button>
</nav>

<div id="panel-a" class="variant-panel active">
  <div class="variant-label">Variant A</div>
  <div class="variant-title">[Name]</div>
  <div class="rationale">[1–2 sentence rationale]</div>
  <div class="mock-frame"><!-- mock A --></div>
  <button class="choose-btn" onclick="choose('A')">Choose Variant A →</button>
  <div class="chosen-banner" id="chosen-a">✓ Chosen A — tell Claude "implement variant A".</div>
</div>
<!-- repeat for B and C -->

<script>
  function showVariant(id){
    document.querySelectorAll('.variant-panel').forEach(p=>p.classList.remove('active'));
    document.querySelectorAll('.variant-nav button').forEach(b=>b.classList.remove('active'));
    document.getElementById('panel-'+id).classList.add('active');
    event.currentTarget.classList.add('active');
  }
  function choose(l){
    document.querySelectorAll('.chosen-banner').forEach(b=>b.style.display='none');
    const el=document.getElementById('chosen-'+l.toLowerCase());
    if(el) el.style.display='block';
  }
</script>
</body>
</html>
```

Fill all 3 mock frames completely — no `<!-- rest here -->` shortcuts.

---

## Phase 3 — Present

State the file path first, give a one-line summary per variant, then ask which variant to implement. Prefer the ask_user tool with one option per variant (A, B, C); lead with the variant you would pick and mark it "(Recommended)" with a one-line reason. This is the command's user checkpoint: do not start implementing before the pick.

---

## Phase 4 — Implement (after the user picks)

1. Re-read the chosen mock from the file.
2. Build it in the real codebase using the project's actual stack and conventions.
3. Match the mock's layout, colors, and interactions; wire mock data to real data/state.
4. Run any relevant tests/linter, then report what changed and what's still pending.
