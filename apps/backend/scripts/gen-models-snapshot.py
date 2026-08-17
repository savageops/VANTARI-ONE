#!/usr/bin/env python3
"""Regenerate the vendored models.dev snapshot subset.

Reads .refs/models-dev/api.json (the MIT-licensed models.dev registry,
refresh with: curl -sL https://models.dev/api.json -o .refs/models-dev/api.json)
and emits apps/backend/src/core/providers/models_snapshot.json containing
only the providers VANTARI ships profiles for, with the minimal field set
the snapshot owner consumes: context/output limits plus tool_call and
reasoning capability flags.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / ".refs" / "models-dev" / "api.json"
TARGET = ROOT / "apps" / "backend" / "src" / "core" / "providers" / "models_snapshot.json"

KEEP_PROVIDERS = [
    "openai",
    "anthropic",
    "openrouter",
    "zai",
    "opencode",
    "deepseek",
    "groq",
    "mistral",
    "xai",
    "google",
]


def main() -> None:
    data = json.loads(SOURCE.read_text())
    out = {}
    for pid in KEEP_PROVIDERS:
        provider = data.get(pid)
        if not provider:
            continue
        models = {}
        for mid, model in (provider.get("models") or {}).items():
            limit = model.get("limit") or {}
            models[mid] = {
                "c": limit.get("context"),
                "o": limit.get("output"),
                "t": bool(model.get("tool_call")),
                "r": bool(model.get("reasoning")),
            }
        out[pid] = {"n": provider.get("name", pid), "m": models}

    TARGET.write_text(json.dumps(out, separators=(",", ":")))
    total = sum(len(v["m"]) for v in out.values())
    print(f"snapshot: {len(out)} providers, {total} models, {TARGET.stat().st_size // 1024} KB -> {TARGET}")


if __name__ == "__main__":
    main()
