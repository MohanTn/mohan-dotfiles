# lean-system-prompt.md goal-protocol eval

Regression eval for the "Goal protocol" section of `../lean-system-prompt.md`:
a substantial reply must open with `GOAL: <sentence>` and close with
`GOAL_CHECK: ACHIEVED` or `GOAL_CHECK: NOT_ACHIEVED — <gap>`; an ack or a
one-line answer must skip both. It exists because that rule is enforced two
ways — a stop hook that *logs* a missing `GOAL_CHECK` at runtime, and the
model actually following the instruction — and this eval only checks the
second: does the model comply with the plain text of the prompt, on a bare
single-turn call with no hook in the loop.

## Run it

```sh
npm install
npm run eval
```

Requires `ANTHROPIC_API_KEY` in the environment — this calls the Anthropic
API directly, not the `claude` CLI (there's no wrapping code to call here, so
there's no adapter to reuse the way pipeline-worker's eval does).

`promptfoo` is pinned to `^0.118.0`: newer releases require Node >=22.22,
which this machine doesn't run — check `node --version` before bumping it.

## Adding a case

Add a `tests:` entry in `promptfooconfig.yaml` with a `userMessage` var and
an assertion on whether `GOAL:`/`GOAL_CHECK:` should appear. Keep cases
clear-cut (obviously substantial vs. obviously a one-liner) — an ambiguous
case makes the assertion a judgment call the eval can't make reliably.
