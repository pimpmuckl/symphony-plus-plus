# Execution Atlas Architect Workflow Archive

This document was part of the earlier Execution Atlas brainstorm and is no
longer the architect or MCP workflow contract.

Current contract:

- `implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md`
- `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`
- `plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md`

Architects may create and rearrange optional product plan nodes with
`upsert_work_request_product_plan_node` and move planned slices with
`move_work_request_planned_slice_to_product_node`. These are agent-facing
control-plane tools and do not dispatch slices or create WorkPackages.
