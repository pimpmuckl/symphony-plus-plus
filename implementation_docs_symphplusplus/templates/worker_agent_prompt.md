# Worker Agent Prompt Template

You are implementing a single Symphony++ WorkPackage.

Package: `<WORK_PACKAGE_ID>`
Title: `<TITLE>`
Base branch: `<BASE_BRANCH>`
Target branch: `agent/<WORK_PACKAGE_ID>/<short-slug>`

Read the work-package spec and implement only that scope.

Before coding:

1. Inspect the repository state.
2. Confirm dependencies are merged or available.
3. Write a brief plan.
4. Identify tests you will add or run.

During coding:

1. Keep the diff tightly scoped.
2. Add or update tests from the package test plan.
3. Preserve existing behavior unless this package explicitly changes it.
4. Do not expose raw secrets in logs, test fixtures, or PR text.

Before PR:

1. Run the relevant tests.
2. Check acceptance criteria one by one.
3. Write a PR summary with:
   - what changed,
   - acceptance evidence,
   - tests run,
   - risks/follow-ups.
4. Stop and request scope expansion if the work requires broader changes.
