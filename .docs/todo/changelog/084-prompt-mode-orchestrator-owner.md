---
type: changelog
id: prompt-mode-orchestrator-owner
status: closed
updated: 2026-08-14
---

# Prompt-mode orchestration owner

`agents.orchestrator_only` is no longer a live configuration policy. Root
orchestration is now derived from the existing session-local `PromptMode`:
Shift+Tab is the fast TUI control, `--prompt-mode` is the CLI control, and
`orchestrate` is the default. The derived execution-context guard remains the
single enforcement point for provider catalog and dispatch allow-list.

`build`, `align`, and `plan` retain the normal root tools. Child profiles remain
unchanged. The validator reads the retired boolean for compatibility but never
applies it; the compiled default and live user config omit it.

Proof: Debug `19/19` / `2,184/2,184`, ReleaseFast `9/9`, source/installed
SHA-256 `59E150343A206A465ACACBB7E3F5466BDD052E4C8F4426C599AFB6D25A24FC8E`,
installed build-mode native tool lifecycle, installed PTY Shift+Tab render,
config validation, and zero final exact-path VANTARI processes.
