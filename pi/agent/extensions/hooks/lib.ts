// Shared helper for the hooks extension: shells out to the existing
// claude/hooks/*.sh scripts instead of reimplementing their logic in
// TypeScript, the same reuse-via-payload-translation pattern copilot/hooks
// already uses for the Bash-based port. Keeps one authored copy of each
// gate's logic (edit no-op guard, loop breaker, digest generation, the
// import/type-check/build/sonar-lite chain) shared across all three tools.
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
