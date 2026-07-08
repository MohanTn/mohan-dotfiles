---
name: feature
description: Run the feature-team pipeline (scout, planner, implementer, reviewer, verifier custom agents) for a named goal, with plan-approval and ship-approval checkpoints. Use when the user says "feature", asks to build a feature end to end, or wants the full plan-build-review workflow.
---

Run the feature-team pipeline (see "Feature team: dynamic sub-agent workflow" in `~/.copilot/copilot-instructions.md`) for the goal the user named.

You are the coordinator. The phases run in the custom agents under `~/.copilot/agents`, delegated as subagents, not inline in this session; your job is orchestration, relaying substance, and holding the two checkpoints.

1. Restate the goal in one sentence. If the goal is too thin to scope at all, ask now, once, before delegating anything.
2. If the task is genuinely small (single file, obvious change), say so, offer to do it inline instead, and wait; the pipeline earns its overhead only on multi-file work.
3. Delegate to the **scout** agent with the goal. Relay the substance of its FINDINGS to the user in two or three sentences, not the whole block.
4. Delegate to the **planner** agent with the goal plus the full FINDINGS block (plus the `arch-<slug>.html` document if one is APPROVED for this feature). Present the PLAN: the steps, the test plan, and every open question with its recommended default.
5. **Checkpoint 1:** get explicit approval via ask_user (approve as the recommended first option, adjust as the second). Nothing is built before it. Fold any adjustments back through the planner, giving it its previous PLAN plus the requested changes.
6. Delegate to the **implementer** agent with the approved PLAN verbatim. Relay BUILT with the real test output.
7. Delegate to the **reviewer** and **verifier** agents in parallel on the result.
8. While REVIEW has findings or VERDICT fails: send the findings back to the implementer (continue the same task where the runtime allows; otherwise include its previous BUILT block with the findings so no context is lost), then re-run only the gate that failed. Cap the loop at 3 rounds; if still failing, stop and present the situation honestly, including what remains broken.
9. **Checkpoint 2:** present the outcome in charter style: what works now, the test and verification evidence, known gaps. Commits, version bumps, and publishes wait for the user's go.
