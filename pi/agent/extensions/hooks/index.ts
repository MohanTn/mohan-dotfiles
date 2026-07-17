// TypeScript port of claude/hooks for the Pi coding agent. Gates whose logic
// doesn't depend on Pi's tool-input shape (loop breaker, digest generation,
// the post-edit import/type-check/build/sonar-lite chain, session cleanup)
// shell out to the existing claude/hooks/*.sh scripts via lib.ts's
// runClaudeHook, the same reuse pattern copilot/hooks uses. Two gates are
// reimplemented natively instead of shelled out, because Pi's tool/event
// shapes don't map onto Claude's closely enough to translate faithfully:
//
// - edit no-op guard: Pi's edit tool takes `{path, edits: [{oldText,
//   newText}]}` (an array, for multi-edit-in-one-call), not Claude's single
//   `{file_path, old_string, new_string}`. Re-checked directly against
//   Pi's own type defs (dist/core/tools/edit.d.ts) rather than assumed.
// - goal-capture/goal-check: Pi's turn_end event hands over the assistant's
//   actual message text, so there's no need to re-parse a JSONL transcript
//   file the way pre-tool-use-goal-capture.sh and stop-goal-check.sh do for
//   Claude Code.
//
// Known gap: Claude Code's Stop hook can block the turn from ending (exit 2)
// until a GOAL_CHECK: line appears. Pi's documented extension API has no
// confirmed way to force a turn to continue from turn_end, so the check
// below only warns via ctx.ui.notify — it does not gate completion. Revisit
// if Pi adds a blocking return value for turn_end.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { extractText, runClaudeHook, toClaudeToolName } from "./lib.js";

interface EditInput {
  path: string;
  edits: Array<{ oldText: string; newText: string }>;
}

interface WriteInput {
  path: string;
  content: string;
}

export default function (pi: ExtensionAPI) {
  let sessionId = crypto.randomUUID();
  let digest = "";
  let digestInjected = false;
  let capturedGoal: string | null = null;

  pi.on("session_start", async (event, ctx) => {
    sessionId = crypto.randomUUID();
    digestInjected = false;
    capturedGoal = null;

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
      const noop = input.edits?.some((e) => e.oldText === e.newText);
      if (noop) {
        return { block: true, reason: "oldText and newText are identical — this edit is a no-op." };
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
    if (gate.exitCode !== 2) return;

    return {
      content: [...event.content, { type: "text", text: gate.stderr.trim() }],
      details: event.details,
      isError: true,
    };
  });

  // Native goal-capture + goal-check (see the module-level comment on why
  // this isn't shelled out, and its enforcement gap vs. the Claude version).
  pi.on("turn_end", async (event, ctx) => {
    const text = extractText(event.message);

    const goalMatch = text.match(/^GOAL:\s*(.+)$/m);
    if (goalMatch) {
      capturedGoal = goalMatch[1].trim();
      return;
    }

    if (!capturedGoal) return;

    if (/GOAL_CHECK:/.test(text)) {
      capturedGoal = null;
      return;
    }

    ctx.ui?.notify?.(
      `Goal stated earlier ("${capturedGoal}") was never checked off with GOAL_CHECK: this turn.`,
      "warning",
    );
  });

  pi.on("session_shutdown", async () => {
    runClaudeHook("session-end-cleanup.sh", {});
  });
}
