# Reviewer Checklist

Use this checklist for Symphony++ WorkPackage PRs. Keep the review tied to the
assigned package and the current PR head.

## Scope

- PR title includes the WorkPackage id.
- Diff is limited to the owned paths and package purpose.
- No dependent package, sibling package, broad reorganization, or cleanup-only
  work slipped in without architect approval.
- Base branch and target branch match the assignment.

## Acceptance

- Every acceptance criterion is satisfied with evidence or explicitly blocked.
- The PR body maps changes to the package, not to a larger roadmap claim.
- Implementation notes or package docs capture discovered constraints.

## Validation

- Required package tests or docs checks ran on the current head.
- For release-readiness PRs, `make -C elixir all` evidence is current when
  the diff touches runtime code, tests, build files, release-critical policy, or
  reviewer guidance. Documentation-only PRs may reuse prior green evidence only
  when they do not change release-critical policy or review requirements.
- Coverage ratchet evidence references the current `elixir/mix.exs` threshold
  and does not claim `100%` coverage as a current blocker.
- Review-suite evidence is attached to the current PR head SHA.

## Security

- No raw grant secrets, bearer tokens, GitHub tokens, Linear tokens, MCP auth
  tokens, signed URLs, or private keys appear in files, logs, PR bodies, or
  review artifacts.
- Worker grants remain scoped to one package.
- Human merge and branch protection remain authoritative for protected branches.
- Secret-dependent validation is marked blocked instead of using real secret
  values in durable text.

## Readiness Decision

Approve only when the package is scoped, tested, reviewed, and honest about
limitations. Request changes for correctness, missing evidence, stale review
artifacts, secret exposure, or unapproved scope expansion. Ask the architect for
a decision when feedback would require broader docs reorganization, old-doc
deletion, runtime redesign, or compatibility policy changes.
