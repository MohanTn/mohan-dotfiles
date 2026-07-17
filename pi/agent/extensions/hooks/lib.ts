// Shared helper for the hooks extension: shells out to the existing
// claude/hooks/*.sh scripts instead of reimplementing their logic in
// TypeScript, the same reuse-via-payload-translation pattern copilot/hooks
// already uses for the Bash-based port. Keeps one authored copy of each
// gate's logic (edit no-op guard, loop breaker, digest generation, the
// import/type-check/build chain) shared across all three tools.
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const CLAUDE_HOOKS_HOME = join(homedir(), ".claude", "hooks");

export interface ClaudeHookResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export function runClaudeHook(script: string, payload: object): ClaudeHookResult {
  const result = spawnSync("bash", [join(CLAUDE_HOOKS_HOME, script)], {
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

// Scans session entries after the most recent user message for an unchecked
// GOAL: — same scope pre-tool-use-goal-capture.sh and stop-goal-check.sh use
// against the Claude Code JSONL transcript. Must be evaluated once per
// user-facing turn (e.g. on agent_settled), not per turn_end: a single user
// prompt can span many turn_end events while the LLM keeps calling tools, and
// only the assistant text accumulated across ALL of them (not any one message)
// determines whether GOAL_CHECK: was ever stated.
export function findUncheckedGoal(entries: MessageEntryLike[]): string | null {
  let lastUserIdx = -1;
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].type === "message" && entryRole(entries[i]) === "user") lastUserIdx = i;
  }
  if (lastUserIdx === -1) return null;

  const assistantText = entries
    .slice(lastUserIdx + 1)
    .filter((e) => e.type === "message" && entryRole(e) === "assistant")
    .map((e) => extractText(e.message))
    .join("\n");

  const goalMatch = assistantText.match(/^GOAL:\s*(.+)$/m);
  if (!goalMatch || /GOAL_CHECK:/.test(assistantText)) return null;

  return goalMatch[1].trim();
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
