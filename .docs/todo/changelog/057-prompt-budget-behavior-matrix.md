---
type: changelog
id: 057-prompt-budget-behavior-matrix
status: completed
---

# 057 — Prompt budget and behavior matrix

Move 66 is source-complete. `ContextPolicy.prompt_budget_tokens` defaults to
`8192`, is loaded through the existing context configuration owner, and bounds
the assembled provider-facing system prompt with the shared char/4 estimate.
The builder fails with `PromptBudgetExceeded` before provider dispatch instead
of silently dropping prompt layers. Native provider tool schemas remain the
separate model-facing API and are not duplicated into the string budget.

Prompt tests cover all four modes and named terse/detailed, solo/orchestrated,
conservative/aggressive, and low/high-cadence profiles across root, recon, and
orchestrator tool routes. The same prompt builder and definition-owned tool
routes are used; no executor behavior branch or prompt-side registry was added.

Proof: Debug `19/19` build steps and `2,154/2,154` tests passed; source
ReleaseFast `9/9`; source SHA-256
`CA61A2DD503C0A5A70850AB12A809DE43F471B3ED86FF46DF439A50F8B89BC0D`.
Installed promotion remains deferred. Move 68 carries the separate exact,
estimated, and unknown token-accounting boundary through existing turn events;
this prompt-budget receipt remains unchanged.
