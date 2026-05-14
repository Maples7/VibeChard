---
name: "Handle GitHub Issue"
description: "Validate and process one GitHub issue end-to-end: close invalid issues, or implement valid work on a branch, run /pre-commit-review, open a PR with Closes #N, wait for CI, and merge."
argument-hint: "<issue-number-or-url>"
agent: "Issue Steward"
tools: [read, edit, search, execute, todo, agent]
---

Handle the GitHub issue provided after this slash command from triage through merge.

Use the issue identifier from the prompt arguments. If it is missing, ask for the issue number or URL and then continue.

Follow the `Issue Steward` agent workflow exactly:

1. Fetch the GitHub issue details and comments.
2. Compare the issue against the current `origin/master` source tree.
3. If the issue is invalid, already fixed, out of scope, or contradicted by current code, comment on the issue with evidence and close it.
4. If the issue is reasonable, create a new branch from `origin/master`, implement the requested code/docs/tests change, and validate it locally.
5. Invoke `/pre-commit-review` on the branch diff before opening the PR.
6. Fix every actionable audit finding, including `info` severity items when they point to concrete improvements, then rerun the audit and affected tests.
7. Push the branch and open a GitHub PR whose body contains `Closes #<issue-number>`.
8. Wait for PR CI. If CI fails, inspect the failure, fix it, push again, and wait for green checks.
9. Merge the PR after required checks pass, using the repository's preferred merge method and without bypassing branch protection.

Keep going until the issue is closed as invalid, the PR is merged, or a genuine blocker prevents completion.