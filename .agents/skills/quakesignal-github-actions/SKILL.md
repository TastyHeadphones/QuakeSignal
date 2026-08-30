---
name: quakesignal-github-actions
description: Run and verify QuakeSignal work only with GitHub-hosted Actions. Use for any repository task that would build, test, lint, package, run Xcode or a simulator, execute project scripts or binaries, migrate data, deploy, or otherwise execute app or backend code; never use the current workstation for those operations.
---

# QuakeSignal GitHub Actions execution

Keep all project execution off the current workstation. GitHub-hosted Actions
are the execution environment for this repository.

## Execution boundary

Never run any of the following on the workstation:

- Xcode, `xcodebuild`, `xcrun`, Simulator, or Apple platform build tools
- app, backend, desktop, extension, or Worker code
- tests, builds, linters, formatters, type checks, package scripts, or benchmarks
- repository scripts, migrations, development servers, packaging, or deployment
- project commands inside Docker, a local virtual machine, or another local app

Do not use a self-hosted GitHub Actions runner. Use only GitHub-hosted
`macos-*`, `ubuntu-*`, or `windows-*` runners so execution cannot fall back to
the project owner's computer.

Local operations are limited to control-plane work that does not execute
project code: reading and editing files, reviewing diffs, Git staging and
commits, pushing a branch, dispatching or observing a workflow, and downloading
workflow logs or artifacts. If a Git hook would execute project code locally,
do not run the hook; rely on the equivalent required Action instead.

## Workflow

1. Decide whether execution is actually needed. Documentation, source review,
   and mechanical edits do not require an invented test run.
2. Match the change to an existing workflow:
   - Apple/Xcode work: `.github/workflows/ios.yml`
   - desktop work: `.github/workflows/desktop-build.yml`
   - Chrome extension work: `.github/workflows/extension-build.yml`
   - backend validation: `.github/workflows/cloudflare-staging.yml`
   - production backend deployment: `.github/workflows/cloudflare.yml`
   - listing assets: `.github/workflows/listing-assets.yml`
   - workflow and repository-skill validation:
     `.github/workflows/workflow-lint.yml` and
     `.github/workflows/skill-validation.yml`
3. Prefer a branch push or pull request that activates the workflow's existing
   path filters. Use `workflow_dispatch` when a suitable manual entry point
   already exists.
4. If no existing workflow can safely run the required check, add a
   purpose-specific GitHub-hosted workflow or job with fixed commands. Never add
   a generic free-form shell-command input.
5. Commit and push only the in-scope files needed for the run. Wait for the
   remote job, inspect its conclusion and logs, and download artifacts when the
   task requires them.
6. Fix failures in source or workflow configuration and repeat on GitHub
   Actions. Never fall back to a local run because CI is slow, unavailable, or
   failing.

## Xcode and screenshots

Run Xcode work on a GitHub-hosted macOS runner. Use the existing simulator
selection in `ios.yml` or add a specific job when another Apple destination is
required. Generate screenshots, test results, archives, and diagnostic logs on
the runner and upload them as workflow artifacts.

Signing, TestFlight upload, App Store Connect upload, and production deployment
must remain in their protected, purpose-built manual workflows and environments.
Do not expose signing material in logs or add a less-protected workflow to work
around a release gate.

## Safety and completion

- A validation workflow must not mutate production services unless the user
  explicitly requested that production action.
- Preserve protected-environment approvals, branch protection, least-privilege
  permissions, pinned Actions, and existing concurrency controls.
- Report the workflow name, run result, and commit SHA. Include the run URL when
  available.
- If GitHub Actions or an external service blocks completion, report the remote
  gate and leave the repository in a reviewable state; do not execute locally.
