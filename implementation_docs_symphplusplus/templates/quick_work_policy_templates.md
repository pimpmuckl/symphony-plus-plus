# Quick Work Policy Templates

These templates describe the current quick-work policies. They are package
policy references for implemented behavior, not a backlog or phase-history
roadmap.

| Template | Planning depth | Default grant expiry | Readiness status | Required gates | Required review lanes | PR required |
|---|---|---:|---|---|---|---|
| `quick_fix` | `brief` | `none` | `ready_for_human_merge` | `focused_tests, review_t1` | `review_t1` | No |
| `hotfix` | `incident` | `none` | `ready_for_human_merge` | `focused_tests, review_t1, review_t2, human_merge` | `review_t1, review_t2` | Yes |
| `investigation` | `findings` | `none` | `ready_for_human_merge` | `findings_documented, recommendation_artifact_recorded` | `` | No |

## Behavior

- `quick_fix` uses light planning. Readiness can be satisfied with focused test evidence plus `review_t1` green evidence, without forcing branch or PR metadata.
- `hotfix` uses incident-depth planning. It requires branch and PR metadata, requires current-head review artifacts, and requires `review_t1` plus `review_t2` green evidence. Workers can mark it ready for human merge but cannot mark it merged.
- `investigation` records findings and a canonical recommendation artifact. New `request_scope_expansion` recommendations persist `recommendation.md`; stored legacy recommendation events do not satisfy readiness unless that canonical artifact already exists. It does not require a PR or review lane by default.

Default quick-work grants do not expire by clock. Authority ends through explicit
revocation, package completion/merge/close/archive lifecycle, or worker recycle.
