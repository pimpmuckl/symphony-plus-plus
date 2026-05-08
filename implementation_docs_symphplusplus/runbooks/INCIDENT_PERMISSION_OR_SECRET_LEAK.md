# Incident Runbook: Permission Or Secret Leak

Use this when a worker grant, raw claim secret, bearer token, GitHub token,
Linear token, MCP auth token, private key, signed URL, or secret-bearing claim
URL may have appeared outside the private handoff path.

## Contain

1. Revoke the affected Symphony++ grant immediately.
2. Stop or pause the active AgentRun if possible.
3. Rotate any external credential that may have been exposed.
4. Preserve the workspace, logs, PR refs, and review artifacts for audit.
5. Freeze further package dispatch using the same handoff path until the leak
   class is understood.

## Assess

Search the bounded evidence surfaces for the leaked material or redacted
fingerprint:

- committed files and untracked planning files
- PR body, comments, reviews, and CI logs
- Symphony++ progress, findings, blockers, review packages, and artifacts
- local run logs and command transcripts
- dashboard/API payloads that may have rendered handoff metadata

Do not paste the raw secret into new searches, issue text, PR text, or review
comments. Use redacted fingerprints where possible.

## Fix

1. Identify whether the leak came from package creation output, prompt text,
   MCP configuration, worker commands, review artifacts, dashboard rendering,
   or manual operator handling.
2. Patch the narrow leak path or mark validation blocked if a safe patch cannot
   be made in the current package.
3. Add or update regression coverage for the leak class when the affected code
   is in scope.
4. Record the incident, affected package/grant ids, containment steps, and
   residual risk in package progress or incident notes.
5. Resume only with a new grant and clean private handoff.

Do not resume the affected package with the exposed grant, and do not preserve
secret values in durable incident text.
