# Incident Runbook: Permission or Secret Leak

1. Revoke affected grant immediately.
2. Stop active AgentRun if possible.
3. Rotate any external tokens that may have been exposed.
4. Preserve logs/workspace for audit.
5. Search logs, PRs, artifacts, and dashboard payloads for raw secret.
6. Add regression test for the leak path.
7. Do not resume affected package until root cause is fixed.
