// TypeScript port of claude/hooks for the Pi coding agent. Every gate shells
// out to the existing claude/hooks/*.sh (and *.py) scripts via lib.ts's
// runClaudeHook — the same reuse pattern copilot/hooks uses — so there is one
// authored copy of each gate's logic and policy (edit no-op guard, boilerplate
// mandate, loop breaker, digest generation, context augmentation, the
// import/type-check/build + lint/test chain, the goal-check policy, session
// audit) shared across all three tools. Pi must not reimplement its own
// policy on top of these.
//
// One spot still needs native code, but only to translate Pi's shapes into
// what the scripts expect — not to reimplement their logic:
//
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
  let carryForward = "";

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

    // No boilerplate-hint.sh call here: on Pi the same AGENT-HINT.md is already
    // permanently in the system prompt via ~/.pi/agent/APPEND_SYSTEM.md (see
    // nix/pi.nix), so running the keyword-gated hook as well just paid for the
    // text twice on boilerplate-flavored turns. Claude has no APPEND_SYSTEM
    // equivalent, which is why the hook remains its delivery path.

    // Emitted by session_compact below, flushed into the first turn after a
    // compaction — Pi's compaction handlers have no way to inject a message
    // themselves, so this is the same channel the session digest uses.
    if (carryForward) {
      parts.push(carryForward);
      carryForward = "";
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
      // Pi's edit tool takes `{path, edits: [{oldText, newText}]}` (an array,
      // for multi-edit-in-one-call) rather than Claude's single
      // `{file_path, old_string, new_string}`, so each pair is fed through the
      // shared scripts individually. The no-op check used to be reimplemented
      // inline here; running the real pre-tool-use-edit-guard.sh instead keeps
      // one authored copy of that rule, per this file's opening note.
      for (const e of input.edits ?? []) {
        const noop = runClaudeHook("pre-tool-use-edit-guard.sh", {
          session_id: sessionId,
          cwd: ctx.cwd,
          tool_name: "Edit",
          tool_input: { file_path: input.path, old_string: e.oldText, new_string: e.newText },
        });
        if (noop.exitCode === 2) {
          return { block: true, reason: noop.stderr.trim() };
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

  // Claude Code's PreCompact counterpart. Compaction summarizes the transcript,
  // so the tool history — which files were already changed, what the session was
  // for — is the first thing lost; pre-compact.sh replays exactly that.
  //
  // Runs on session_compact (after) rather than session_before_compact: the
  // "before" handler's result can only cancel or wholly replace the compaction,
  // and its output would be summarized away along with everything else. Neither
  // handler can inject a message, so the block is stashed and flushed by the
  // next before_agent_start. On overflow recovery (`willRetry`) that may land
  // one turn later than Claude's equivalent — degraded, not lost.
  pi.on("session_compact", async (event, ctx) => {
    const result = runClaudeHook("pre-compact.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      hook_event_name: "PreCompact",
      trigger: event.reason === "manual" ? "manual" : "auto",
    });
    if (result.stdout.trim()) {
      carryForward = result.stdout.trim();
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
