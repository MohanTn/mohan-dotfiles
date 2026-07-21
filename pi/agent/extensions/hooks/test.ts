/**
 * test.ts — selftest for the pi hooks extension.
 *
 * Tests the pure/logic functions in lib.ts and verifies the extension module
 * shape. The shell-out gates (runClaudeHook) are integration-tested in the
 * existing claude/hooks/test-hook.sh selftest; this file only covers what is
 * unique to or reimplemented in the TypeScript port.
 *
 * Run:
 *   npx tsx /home/mohan/REPO/mohan-dotfiles/pi/agent/extensions/hooks/test.ts
 *
 * Exit code 0 on pass, non-zero on any failure.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { entriesToClaudeTranscript, extractText, toClaudeToolName, type MessageEntryLike } from "./lib.js";

let pass = 0;
let fail = 0;

function ok(desc: string) {
  console.log(`PASS: ${desc}`);
  pass++;
}

function no(desc: string, detail?: string) {
  console.log(`FAIL: ${desc}${detail ? ` — ${detail}` : ""}`);
  fail++;
}

// ---- extractText ----

const extractCases: [unknown, string, string][] = [
  [null, "", "null → empty"],
  [undefined, "", "undefined → empty"],
  [{}, "", "empty object → empty"],
  ["plain string", "", "plain string → empty (not an object)"],
  [{ content: "direct" }, "direct", "object.content string"],
  [
    { content: [{ type: "text", text: "hello" }] },
    "hello",
    "array of text blocks (single)",
  ],
  [
    {
      content: [
        { type: "text", text: "line1" },
        { type: "image", url: "x" },
        { type: "text", text: "line2" },
      ],
    },
    "line1\nline2",
    "array of text blocks (mixed, filters non-text)",
  ],
  [{ content: [] }, "", "empty array → empty"],
  [
    { content: [{ type: "tool_use", id: "x" }] },
    "",
    "array with no text blocks → empty",
  ],
];

for (const [input, want, desc] of extractCases) {
  const got = extractText(input);
  if (got === want) {
    ok(`extractText: ${desc}`);
  } else {
    no(`extractText: ${desc}`, `expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
  }
}

// ---- toClaudeToolName ----

const toolNameCases: [string, string][] = [
  ["edit", "Edit"],
  ["EDIT", "Edit"],
  ["Edit", "Edit"],
  ["write", "Write"],
  ["Write", "Write"],
  ["WRITE", "Write"],
  ["bash", "Bash"],
  ["Bash", "Bash"],
  ["BASH", "Bash"],
  ["read", "read"], // not mapped
  ["unknownTool", "unknownTool"], // not mapped
];

for (const [input, want] of toolNameCases) {
  const got = toClaudeToolName(input);
  if (got === want) {
    ok(`toClaudeToolName: "${input}" → "${want}"`);
  } else {
    no(`toClaudeToolName: "${input}"`, `expected "${want}", got "${got}"`);
  }
}

// ---- entriesToClaudeTranscript ----
// The goal-check policy itself now lives only in claude/hooks/
// pre-tool-use-goal-capture.sh + stop-goal-check.sh, run against this
// translated transcript (see index.ts's agent_end handler) — no goal-scan
// logic is reimplemented here. What's unique to the TS port is the
// translation: session entries -> a Claude-shaped JSONL file those scripts
// can read unmodified.

function userEntry(text: string): MessageEntryLike {
  return { type: "message", message: { role: "user", content: text } };
}

function assistantEntry(text: string): MessageEntryLike {
  return { type: "message", message: { role: "assistant", content: [{ type: "text", text }] } };
}

{
  const desc = "translates user/assistant entries into Claude's {type, message:{role, content}} JSONL shape";
  const file = entriesToClaudeTranscript([userEntry("do the thing"), assistantEntry("GOAL: do the thing")]);
  const lines = readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  unlinkSync(file);
  const wantUser = lines[0]?.type === "user" && lines[0]?.message?.content === "do the thing";
  const wantAssistant =
    lines[1]?.type === "assistant" && lines[1]?.message?.content?.[0]?.text === "GOAL: do the thing";
  wantUser && wantAssistant
    ? ok(desc)
    : no(desc, `got ${JSON.stringify(lines)}`);
}

{
  const desc = "non-message entries (e.g. custom entries) are skipped, not emitted as blank lines";
  const file = entriesToClaudeTranscript([
    userEntry("hi"),
    { type: "thinking_level_change" } as MessageEntryLike,
    assistantEntry("hello"),
  ]);
  const lineCount = readFileSync(file, "utf8").trim().split("\n").length;
  unlinkSync(file);
  lineCount === 2 ? ok(desc) : no(desc, `expected 2 lines, got ${lineCount}`);
}

// ---- Extension handlers ----

// A recording stand-in for ExtensionAPI: the extension only ever calls
// pi.on(event, handler), so capturing those is enough to drive each handler
// directly and assert on what it returns.
type Handler = (event: unknown, ctx: unknown) => Promise<unknown>;

function fakePi(): { api: unknown; handlers: Map<string, Handler> } {
  const handlers = new Map<string, Handler>();
  return { api: { on: (event: string, handler: Handler) => handlers.set(event, handler) }, handlers };
}

async function main() {
  const mod = await import("./index.js");
  if (typeof mod.default === "function") {
    ok("index.ts exports a default function");
  } else {
    no("index.ts exports a default function", `got ${typeof mod.default}`);
    console.log(`\n---\n${pass} passed, ${fail} failed`);
    process.exitCode = 1;
    return;
  }

  const { api, handlers } = fakePi();
  (mod.default as (pi: unknown) => void)(api);

  for (const event of ["session_start", "before_agent_start", "tool_call", "tool_result", "agent_end", "session_compact", "session_shutdown"]) {
    handlers.has(event)
      ? ok(`registers a ${event} handler`)
      : no(`registers a ${event} handler`);
  }

  const ctx = { cwd: tmpdir() };

  // The no-op rule is no longer reimplemented in TypeScript — it comes from
  // pre-tool-use-edit-guard.sh. Asserting on that script's wording
  // ("old_string", not Pi's "oldText") is what proves the shell-out actually
  // happened rather than a local check standing in for it.
  {
    const desc = "tool_call blocks a no-op edit using the shared guard's reason";
    const result = (await handlers.get("tool_call")!(
      { toolName: "edit", input: { path: "/tmp/x.txt", edits: [{ oldText: "a", newText: "a" }] } },
      ctx,
    )) as { block?: boolean; reason?: string } | undefined;
    if (result?.block && result.reason?.includes("old_string")) {
      ok(desc);
    } else {
      no(desc, `got ${JSON.stringify(result)}`);
    }
  }

  {
    const desc = "tool_call allows an ordinary edit";
    const result = await handlers.get("tool_call")!(
      { toolName: "edit", input: { path: "/tmp/notes.md", edits: [{ oldText: "a", newText: "b" }] } },
      ctx,
    );
    result === undefined ? ok(desc) : no(desc, `expected no block, got ${JSON.stringify(result)}`);
  }

  // Compaction carry-forward: session_compact stashes pre-compact.sh's block and
  // the next before_agent_start injects it. Driven off a git repo with an
  // uncommitted change, which is one of the things pre-compact.sh replays.
  {
    const desc = "session_compact carry-forward is injected on the next turn";
    const repo = mkdtempSync(join(tmpdir(), "pi-hooks-compact-"));
    const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { stdio: "ignore" });
    git("init", "-q");
    git("config", "user.email", "selftest@example.com");
    git("config", "user.name", "selftest");
    writeFileSync(join(repo, "a.txt"), "one\n");
    git("add", "a.txt");
    git("commit", "-qm", "baseline");
    writeFileSync(join(repo, "a.txt"), "two\n");

    const repoCtx = { cwd: repo };
    await handlers.get("session_compact")!({ reason: "threshold", willRetry: false }, repoCtx);
    const injected = (await handlers.get("before_agent_start")!({ prompt: "hi" }, repoCtx)) as
      | { message?: { content?: string } }
      | undefined;
    const content = injected?.message?.content ?? "";
    if (content.includes("<carry-forward>") && content.includes("a.txt")) {
      ok(desc);
    } else {
      no(desc, `got ${JSON.stringify(content).slice(0, 200)}`);
    }

    // Flushed, not resent: a second turn must not repeat the same block.
    const second = (await handlers.get("before_agent_start")!({ prompt: "hi again" }, repoCtx)) as
      | { message?: { content?: string } }
      | undefined;
    const secondDesc = "carry-forward is cleared after being injected once";
    (second?.message?.content ?? "").includes("<carry-forward>")
      ? no(secondDesc, "carry-forward was injected twice")
      : ok(secondDesc);
    rmSync(repo, { recursive: true, force: true });
  }

  // ---- Result ----

  console.log(`\n---\n${pass} passed, ${fail} failed`);
  process.exitCode = fail > 0 ? 1 : 0;
}

main();
