// TypeScript port of claude/hooks for the Pi coding agent. Every gate shells
// out to the existing claude/hooks/*.sh (and *.py) scripts via lib.ts's
// runClaudeHook — the same reuse pattern copilot/hooks uses — so there is one
// authored copy of each gate's logic and policy (edit no-op guard, boilerplate
// mandate, secret/credential guardrail, loop breaker, digest generation,
// context augmentation, the import/type-check/build + lint/test chain,
// session audit) shared across all three tools. Pi must not reimplement its
// own policy on top of these.
//
// One spot still needs native code, but only to translate Pi's shapes into
// what the scripts expect — not to reimplement their logic: the edit no-op
// guard (Pi's `edit` tool takes `{path, edits: [{oldText, newText}]}`, an
// array, not Claude's single `{file_path, old_string, new_string}` — verify
// against `dist/core/tools/edit.d.ts` in the installed
// `@earendil-works/pi-coding-agent` package before assuming otherwise).
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

    // Optional per-project persistent memory (see the llm-memory repo):
    // routes this prompt to a diagram in .ai-memory/ via manifest.json.
    // No-op in repos without .ai-memory/manifest.json.
    const memoryResult = runClaudeHook("inject-memory.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      hook_event_name: "UserPromptSubmit",
      prompt: event.prompt,
    });
    if (memoryResult.stdout.trim()) {
      parts.push(memoryResult.stdout.trim());
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
    // Invoke-time guardrail: applies to every tool, independent of toolName,
    // same authored copy as Claude/Copilot (see secret-guard.sh header).
    const secretGuard = runClaudeHook("secret-guard.sh", {
      session_id: sessionId,
      cwd: ctx.cwd,
      tool_name: toClaudeToolName(event.toolName),
      tool_input: event.input,
    });
    if (secretGuard.exitCode === 2) {
      return { block: true, reason: secretGuard.stderr.trim() };
    }

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

    if (event.toolName === "bash") {
      // Allowlist-only shell policy, same authored copy as Claude/Copilot (see
      // bash-allowlist-guard.sh header). First: a command that may not run at
      // all needs no further inspection.
      const allowlist = runClaudeHook("bash-allowlist-guard.sh", {
        session_id: sessionId,
        cwd: ctx.cwd,
        tool_name: "Bash",
        tool_input: event.input,
      });
      if (allowlist.exitCode === 2) {
        return { block: true, reason: allowlist.stderr.trim() };
      }

      // Closes the shell write-around of the boilerplate mandate, same
      // authored copy as Claude/Copilot (see bash-write-guard.sh header).
      const bashGuard = runClaudeHook("bash-write-guard.sh", {
        session_id: sessionId,
        cwd: ctx.cwd,
        tool_name: "Bash",
        tool_input: event.input,
      });
      if (bashGuard.exitCode === 2) {
        return { block: true, reason: bashGuard.stderr.trim() };
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
