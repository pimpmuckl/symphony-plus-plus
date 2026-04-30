# Source Anchors

This package is intentionally written as an implementation plan, not as a claim that the upstream code already contains Symphony++ features.

Verified reference points on 2026-04-30:

- OpenAI Symphony repository: https://github.com/openai/symphony
- Symphony service specification: https://github.com/openai/symphony/blob/main/SPEC.md
- Symphony Elixir reference implementation README: https://github.com/openai/symphony/blob/main/elixir/README.md
- Codex Agent Skills documentation: https://developers.openai.com/codex/skills
- Codex MCP documentation: https://developers.openai.com/codex/mcp
- Codex Hooks documentation: https://developers.openai.com/codex/hooks
- Codex customization guidance, especially Skills + MCP: https://developers.openai.com/codex/concepts/customization

Design assumptions derived from those sources:

1. Upstream Symphony is an orchestration substrate for isolated agent implementation runs.
2. Upstream Symphony keeps workflow behavior in a repository-owned `WORKFLOW.md`.
3. The current reference implementation is Elixir-based and can be run from `symphony/elixir` with `mise` and `mix` commands.
4. Codex Skills are the correct place to encode repeatable agent workflow instructions.
5. MCP is the correct place to expose external state, tools, and resources to Codex.
6. Hooks are useful lifecycle guardrails, but Symphony++ still treats server-side permission checks as the authority.
