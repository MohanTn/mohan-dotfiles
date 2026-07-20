// TypeScript port of claude/hooks for the Pi coding agent. Every gate shells
// out to the existing claude/hooks/*.sh (and *.py) scripts via lib.ts's
// runClaudeHook — the same reuse pattern copilot/hooks uses — so there is one
// authored copy of each gate's logic and policy (edit no-op guard, boilerplate
// mandate, loop breaker, digest generation, context augmentation, the
// import/type-check/build + lint/test chain, the goal-check policy, session
// audit) shared across all three tools. Pi must not reimplement its own
// policy on top of these.
//
// Two spots still need native code, but only to translate Pi's shapes into
// what the scripts expect — not to reimplement their logic:
//
// - edit no-op guard: Pi's edit tool takes `{path, edits: [{oldText,
//   newText}]}` (an array, for multi-edit-in-one-call), not Claude's single
//   `{file_path, old_string, new_string}`. The oldText===newText check itself
//   is trivial and kept inline; boilerplate-guard.sh (the actual policy) is
//   still called once per edit pair via the adapter below.
// - goal-capture/goal-check: Pi's transcript is in-memory session entries,
//   not a JSONL file. entriesToClaudeTranscript() (lib.ts) serializes them
//   into Claude's JSONL shape so pre-tool-use-goal-capture.sh and
//   stop-goal-check.sh can run completely unmodified against a temp file.
//   Evaluated once per user-facing turn on `agent_end`, not `turn_end`: a
//   "turn" in Pi is one LLM response and repeats internally while the LLM
//   keeps calling tools (see the TurnStartEvent/TurnEndEvent vs.
//   AgentStartEvent/AgentEndEvent split in the extension types), so a single
//   user prompt can produce many turn_end events before the agent is
//   actually done. agent_end ("fired when an agent loop ends") fires once —
//   the closest match to Claude Code's Stop hook timing.
//
// Enforcement is advisory-only, matching stop-goal-check.sh's canonical
// policy (see its header comment: forcing a block costs a whole extra AI
// turn for two lines of text, and isn't worth it). Pi does not force a
// follow-up turn or otherwise block on a missing GOAL_CHECK:.
import { randomUUID } from "node:crypto";
import { unlinkSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { entriesToClaudeTranscript, runClaudeHook, toClaudeToolName } from "./lib.js";

interface EditInput {
  path: string;
  edits: Array<{ oldText: string; newText: string }>;
}

interface WriteInput {
  path: string;
  content: string;
}

export default function (pi: ExtensionAPI) {
  let sessionId = randomUUID();
  let digest = "";
  let digestInjected = false;

  pi.on("session_start", async (event, ctx) => {
    sessionId = crypto.randomUUID();
    digestInjected = false;

    const result = runClaudeHook("session-start.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      hook_event_name: "SessionStart",
      source: event.reason,
    });
    digest = result.stdout.trim();
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const parts: string[] = [];
    if (!digestInjected && digest) {
      parts.push(digest);
      digestInjected = true;
    }

    const promptResult = runClaudeHook("user-prompt-submit.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      hook_event_name: "UserPromptSubmit",
      prompt: event.prompt,
    });
    if (promptResult.stdout.trim()) {
      parts.push(promptResult.stdout.trim());
    }

    const augmentResult = runClaudeHook("context-augment.py", {
      session_id: sessionId,
      cwd: ctx.cwd,
      hook_event_name: "UserPromptSubmit",
      prompt: event.prompt,
    });
    if (augmentResult.stdout.trim()) {
      parts.push(augmentResult.stdout.trim());
    }

    const hintResult = runClaudeHook("boilerplate-hint.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      hook_event_name: "UserPromptSubmit",
      prompt: event.prompt,
    });
    if (hintResult.stdout.trim()) {
      parts.push(hintResult.stdout.trim());
    }

    if (parts.length === 0) return;
    return {
      message: {
        customType: "claude-hooks-port",
        content: parts.join("\n\n"),
        display: false,
      },
    };
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "edit") {
      const input = event.input as EditInput;
      for (const e of input.edits ?? []) {
        if (e.oldText === e.newText) {
          return { block: true, reason: "oldText and newText are identical — this edit is a no-op." };
        }
        const guard = runClaudeHook("boilerplate-guard.sh", {
          session_id: sessionId,
          cwd: ctx.cwd,
          tool_name: "Edit",
          tool_input: { file_path: input.path, old_string: e.oldText, new_string: e.newText },
        });
        if (guard.exitCode === 2) {
          return { block: true, reason: guard.stderr.trim() };
        }
      }
    }

    if (event.toolName === "write") {
      const input = event.input as WriteInput;
      const guard = runClaudeHook("pre-tool-use-edit-guard.sh", {
        session_id: sessionId,
        cwd: ctx.cwd,
        tool_name: "Write",
        tool_input: { file_path: input.path, content: input.content },
      });
      if (guard.exitCode === 2) {
        return { block: true, reason: guard.stderr.trim() };
      }
      const boilerplate = runClaudeHook("boilerplate-guard.sh", {
        session_id: sessionId,
        cwd: ctx.cwd,
        tool_name: "Write",
        tool_input: { file_path: input.path, content: input.content },
      });
      if (boilerplate.exitCode === 2) {
        return { block: true, reason: boilerplate.stderr.trim() };
      }
    }

    const loop = runClaudeHook("pre-tool-use-loop-breaker.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      tool_name: toClaudeToolName(event.toolName),
      tool_input: event.input,
    });
    if (loop.exitCode === 2) {
      return { block: true, reason: loop.stderr.trim() };
    }
  });

  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    const filePath = (event.input as { path?: string } | undefined)?.path;
    if (!filePath) return;

    const gate = runClaudeHook("post-tool-use-edit.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      hook_event_name: "PostToolUse",
      tool_name: toClaudeToolName(event.toolName),
      tool_input: { file_path: filePath },
    });
    if (gate.exitCode === 2) {
      return {
        content: [...event.content, { type: "text", text: gate.stderr.trim() }],
        details: event.details,
        isError: true,
      };
    }
  });

  // Adapter for the canonical goal-check gate in claude/hooks (see the
  // module-level comment for why transcript translation is needed and why
  // this runs on agent_end). Advisory-only — never blocks or forces a
  // follow-up turn.
  pi.on("agent_end", async (_event, ctx) => {
    const transcriptFile = entriesToClaudeTranscript(ctx.sessionManager.getEntries());
    try {
      const payload = { session_id: sessionId, cwd: ctx.cwd, transcript_path: transcriptFile };
      runClaudeHook("pre-tool-use-goal-capture.sh", payload);
      runClaudeHook("stop-goal-check.sh", payload);
    } finally {
      try {
        unlinkSync(transcriptFile);
      } catch {
        // best-effort cleanup
      }
    }
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const transcriptFile = entriesToClaudeTranscript(ctx.sessionManager.getEntries());
    try {
      runClaudeHook("session-end-audit.sh", { session_id: sessionId, cwd: ctx.cwd, transcript_path: transcriptFile });
    } finally {
      try {
        unlinkSync(transcriptFile);
      } catch {
        // best-effort cleanup
      }
    }
    runClaudeHook("session-end-cleanup.sh", {});
  });
}
