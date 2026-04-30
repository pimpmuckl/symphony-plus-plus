# Review Suite Artifact Contract

Review-suite results are first-class artifacts. They must be attached to a WorkPackage and, when a PR exists, to the current PR head SHA.

## JSON shape

```json
{
  "work_package_id": "SYMPP-P6-002",
  "pr_url": "https://github.com/example/repo/pull/123",
  "head_sha": "abc123",
  "result": "passed",
  "checks": [
    {
      "name": "unit_tests",
      "status": "passed",
      "details": "mix test passed"
    },
    {
      "name": "scope_guard",
      "status": "passed",
      "details": "All changed files are inside allowed scope."
    }
  ],
  "summary": "All required checks passed.",
  "created_by": "agent-run-id"
}
```

## Readiness rules

- Artifact must match WorkPackage ID.
- Artifact must match current PR head SHA when PR is required.
- Required checks must pass.
- Stale artifacts cannot satisfy readiness.
- Worker cannot override failed review-suite result.
