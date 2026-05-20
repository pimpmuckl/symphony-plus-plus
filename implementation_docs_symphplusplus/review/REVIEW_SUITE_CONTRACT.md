# Review Suite Artifact Contract

Review-suite results are first-class artifacts. They must be attached to a WorkPackage and, when a PR exists, to the current PR head SHA.

For human review expectations and scope boundaries, use
`REVIEWER_CHECKLIST.md`.

## JSON shape

`attach_review_suite_result` records the canonical result shape workers may use
for readiness policies that require `review_suite_result`:

```json
{
  "work_package_id": "SYMPP-P6-002",
  "head_sha": "abc123",
  "suite": "review-suite",
  "anchor": "phase_gate-abc123",
  "status": "passed",
  "verdict": "green",
  "summary": "Required Review Suite profile passed for the current head.",
  "lane": "normal",
  "reviewer": "review-suite",
  "round_id": "phase_gate-abc123"
}
```

## Readiness rules

- Artifact must match WorkPackage ID.
- Artifact must match current PR head SHA when PR is required.
- Required status/verdict must pass.
- Stale artifacts cannot satisfy readiness.
- Worker cannot override failed review-suite result.
- Generic `append_progress` JSON does not satisfy `review_suite_result`; the
  result must be recorded through `attach_review_suite_result`, which also
  persists a canonical `review_suite` artifact row for the same head SHA.
- Review-suite result payloads intentionally expose only suite, lane, anchor,
  reviewer, round id, status/verdict, summary, work package id, and head SHA.
  They must not include tokens, auth headers, raw prompts, sensitive logs,
  signed URLs, or reviewer internals.
