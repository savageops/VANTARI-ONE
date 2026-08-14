---
type: changelog
id: installed-input-response-move89
status: complete
date: 2026-08-14
owner: apps/backend/scripts/verify_installed_input_response.ps1
---

# Installed provider-driven input response

Move 89 now has a deterministic installed-path proof for the existing
`ask_user`/`InputBroker`/`input/respond` boundary. The proof uses a disposable
local OpenAI-compatible provider only to return one real tool call; it does not
add a provider fallback or a second question system.

- Installed SHA-256: `85CE5E58BCDDBEBBDD6E04CA4978E8E9A2535CBA2EA50B76016841E3275D1481`.
- Session: `session-1786732334033-c1caa3992e7ae920`.
- Prompt mode: `orchestrate`; this is the default Shift+Tab posture and the
  only root catalog posture that narrows direct task-artifact tools.
- The provider made two completion requests and received the
  `var1.input_response.v1` envelope after `input/respond`.
- The installed event spine persisted `input_requested`, tool lifecycle rows,
  `assistant_response`, and one completed `var1.turn_terminal.v1` row.
- The kernel exited through graceful EOF with exit code `0` and no installed
  process remained.

Evidence: `.docs/research/2026-08-14-roadmap-24-installed-input-response.json`.
