/**
 * Dev tools the agent needs full filesystem/network reach for (git remotes,
 * python venvs/site-packages, rg/fd searching outside the allow-listed
 * writable dirs) run outside the OS-level sandbox entirely instead of
 * loosening its read/write/network rules for every command.
 *
 * Kept dependency-free (no imports from "@anthropic-ai/sandbox-runtime" or
 * "@earendil-works/pi-coding-agent") so it can be unit tested without the pi
 * runtime present, see test.ts.
 */
export const TRUSTED_COMMANDS = new Set(["git", "rg", "fd", "fdfind", "python3", "python"]);

// Only bypass the sandbox for a single plain invocation, not a chain -
// otherwise "git log; rm -rf ~" would ride the exemption on the strength of
// its first word. Anything with shell control chars (chaining, redirection,
// substitution) still goes through the sandbox.
const SHELL_CONTROL_CHARS = /[;&|`$<>]/;

export function isTrustedCommand(command: string): boolean {
	const trimmed = command.trim();
	if (!trimmed || SHELL_CONTROL_CHARS.test(trimmed)) return false;
	const firstToken = trimmed.split(/\s+/)[0];
	const bin = firstToken.split("/").pop() ?? firstToken;
	return TRUSTED_COMMANDS.has(bin);
}
