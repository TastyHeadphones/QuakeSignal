# QuakeSignal agent instructions

Before any task that would execute project code or a project command, load and
follow `.agents/skills/quakesignal-github-actions/SKILL.md`.

Builds, tests, linters, formatters, type checks, Xcode and Simulator work,
repository scripts, packaging, migrations, and deployments must run only on
GitHub-hosted GitHub Actions runners. Do not run them on the current workstation
or a self-hosted runner.

Local file inspection, file editing, diff review, Git operations, and GitHub
Actions orchestration are allowed because they do not execute the product.
When no suitable workflow exists, add a narrowly scoped GitHub-hosted workflow,
push it, and use its remote result for verification.
