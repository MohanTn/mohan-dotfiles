// Shared helper for the hooks extension: shells out to the existing
// claude/hooks/*.sh (and *.py) scripts instead of reimplementing their logic
// in TypeScript, the same reuse-via-payload-translation pattern copilot/hooks
// already uses for the Bash-based port. Keeps one authored copy of each
// gate's logic (edit no-op guard, loop breaker, digest generation, the
// import/type-check/build chain, the goal-check policy) shared across all
// three tools — Pi must not reimplement its own policy on top of these.
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const CLAUDE_HOOKS_HOME = join(homedir(), ".claude", "hooks");

export interface ClaudeHookResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

function interpreterFor(script: string): string {
  return script.endsWith(".py") ? "python3" : "bash";
}

export function runClaudeHook(script: string, payload: object): ClaudeHookResult {
  const result = spawnSync(interpreterFor(script), [join(CLAUDE_HOOKS_HOME, script)], {
    input: JSON.stringify(payload),
    encoding: "utf8",
  });
  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

export function toClaudeToolName(piToolName: string): string {
  switch (piToolName.toLowerCase()) {
    case "edit":
      return "Edit";
    case "write":
      return "Write";
    case "bash":
      return "Bash";
    default:
      return piToolName;
  }
}

export interface MessageEntryLike {
  type: string;
  message?: unknown;
}

function entryRole(e: MessageEntryLike): string | undefined {
  return (e.message as { role?: string } | undefined)?.role;
}

// Serializes Pi's in-memory session entries into a Claude Code-shaped JSONL
// transcript file ({type:"user"|"assistant", message:{role, content}}) so
// pre-tool-use-goal-capture.sh and stop-goal-check.sh can read it unmodified,
// the same role this plays for session-end-audit.sh. Only user/assistant
// message entries are emitted — tool calls etc. don't affect the goal scan
// and both scripts only correlate lines by relative order, not exact count.
// Caller owns the returned path and should unlink it once done.
export function entriesToClaudeTranscript(entries: MessageEntryLike[]): string {
  const lines: string[] = [];
  for (const e of entries) {
    if (e.type !== "message") continue;
    const role = entryRole(e);
    if (role === "user") {
      lines.push(JSON.stringify({ type: "user", message: { role: "user", content: extractText(e.message) } }));
    } else if (role === "assistant") {
      lines.push(
        JSON.stringify({
          type: "assistant",
          message: { role: "assistant", content: [{ type: "text", text: extractText(e.message) }] },
        }),
      );
    }
  }
  const file = join(tmpdir(), `pi-hooks-transcript-${randomUUID()}.jsonl`);
  writeFileSync(file, lines.join("\n") + "\n");
  return file;
}

export function extractText(message: unknown): string {
  if (!message || typeof message !== "object") return "";
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter(
        (c): c is { type: string; text?: string } =>
          !!c && typeof c === "object" && (c as { type?: string }).type === "text",
      )
      .map((c) => c.text ?? "")
      .join("\n");
  }
  return "";
}
