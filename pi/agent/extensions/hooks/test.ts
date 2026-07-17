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

import { extractText, findUncheckedGoal, toClaudeToolName, type MessageEntryLike } from "./lib.js";

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

// ---- findUncheckedGoal ----

function userEntry(text: string): MessageEntryLike {
  return { type: "message", message: { role: "user", content: text } };
}

function assistantEntry(text: string): MessageEntryLike {
  return { type: "message", message: { role: "assistant", content: [{ type: "text", text }] } };
}

{
  const desc = "no GOAL: stated → no unchecked goal";
  const got = findUncheckedGoal([userEntry("hi"), assistantEntry("Sure, on it.")]);
  got === null ? ok(desc) : no(desc, `expected null, got ${JSON.stringify(got)}`);
}

{
  const desc = "GOAL: stated, no GOAL_CHECK: anywhere → flagged unchecked";
  const got = findUncheckedGoal([userEntry("do the thing"), assistantEntry("GOAL: do the thing\n\nworking...")]);
  got === "do the thing" ? ok(desc) : no(desc, `expected "do the thing", got ${JSON.stringify(got)}`);
}

{
  const desc = "GOAL: and GOAL_CHECK: in the same assistant message → satisfied";
  const got = findUncheckedGoal([
    userEntry("do the thing"),
    assistantEntry("GOAL: do the thing\n\nDone.\n\nGOAL_CHECK: ACHIEVED"),
  ]);
  got === null ? ok(desc) : no(desc, `expected null, got ${JSON.stringify(got)}`);
}

{
  // Regression for the turn_end bug: GOAL: is stated in the first LLM
  // response of the turn, several tool-calling rounds follow with no
  // GOAL_CHECK:, and only the final assistant message states it. A
  // per-message check (the old turn_end behavior) would flag every
  // intermediate round; the fix must aggregate all assistant entries since
  // the last user entry and only flag if GOAL_CHECK: never appears at all.
  const desc = "GOAL_CHECK: arrives several assistant turns later → satisfied, not flagged mid-loop";
  const got = findUncheckedGoal([
    userEntry("do the thing"),
    assistantEntry("GOAL: do the thing"),
    assistantEntry("Reading files..."),
    assistantEntry("Editing..."),
    assistantEntry("Done.\n\nGOAL_CHECK: ACHIEVED"),
  ]);
  got === null ? ok(desc) : no(desc, `expected null, got ${JSON.stringify(got)}`);
}

{
  const desc = "goal from a previous user turn doesn't leak into the next turn's check";
  const got = findUncheckedGoal([
    userEntry("first task"),
    assistantEntry("GOAL: first task\n\nGOAL_CHECK: ACHIEVED"),
    userEntry("second task"),
    assistantEntry("Sure, on it (no GOAL: restated)."),
  ]);
  got === null ? ok(desc) : no(desc, `expected null, got ${JSON.stringify(got)}`);
}

// ---- Extension module shape ----

// The extension must export a default function (ExtensionAPI → void).
// We can't call it without a real ExtensionAPI, but we can verify it loads
// and is callable.
async function main() {
  const mod = await import("./index.js");
  if (typeof mod.default === "function") {
    ok("index.ts exports a default function");
  } else {
    no("index.ts exports a default function", `got ${typeof mod.default}`);
  }

  // ---- Result ----

  console.log(`\n---\n${pass} passed, ${fail} failed`);
  process.exitCode = fail > 0 ? 1 : 0;
}

main();
