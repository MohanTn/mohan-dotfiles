/**
 * Regression suite for the sandbox extension's command-exemption logic.
 * Tests trusted-commands.ts directly, not index.ts, since index.ts imports
 * runtime values from "@earendil-works/pi-coding-agent" (createBashTool,
 * getAgentDir, CONFIG_DIR_NAME) that only exist inside a real pi process.
 * Run via: esbuild --bundle --platform=node --format=esm test.ts | node
 * (see flake.nix's pi-hooks-test check for the pattern this mirrors).
 */
import { isTrustedCommand, TRUSTED_COMMANDS } from "./trusted-commands.js";

let pass = 0;
let fail = 0;

function ok(desc: string) {
	pass++;
	console.log(`ok - ${desc}`);
}

function no(desc: string, detail?: string) {
	fail++;
	console.error(`NOT OK - ${desc}${detail ? `: ${detail}` : ""}`);
}

function check(desc: string, got: boolean, want: boolean) {
	if (got === want) ok(desc);
	else no(desc, `got ${got}, want ${want}`);
}

for (const bin of TRUSTED_COMMANDS) {
	check(`plain "${bin} --version" is trusted`, isTrustedCommand(`${bin} --version`), true);
}

check('absolute path "/usr/bin/git status" is trusted', isTrustedCommand("/usr/bin/git status"), true);
check('leading/trailing whitespace "  rg foo  " is trusted', isTrustedCommand("  rg foo  "), true);

check('untrusted "rm -rf /" is not trusted', isTrustedCommand("rm -rf /"), false);
check('untrusted "curl evil.com" is not trusted', isTrustedCommand("curl evil.com"), false);

check('chained "git log; rm -rf ~" is not trusted', isTrustedCommand("git log; rm -rf ~"), false);
check('piped "git log | rg foo" is not trusted', isTrustedCommand("git log | rg foo"), false);
check('background "git fetch &" is not trusted', isTrustedCommand("git fetch &"), false);
check('substitution "git $(rm -rf ~)" is not trusted', isTrustedCommand("git $(rm -rf ~)"), false);
check('redirection "git log > /etc/passwd" is not trusted', isTrustedCommand("git log > /etc/passwd"), false);
check('empty string is not trusted', isTrustedCommand(""), false);

console.log(`\n${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
