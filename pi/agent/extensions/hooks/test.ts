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

import { extractText, toClaudeToolName } from "./lib.js";

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
