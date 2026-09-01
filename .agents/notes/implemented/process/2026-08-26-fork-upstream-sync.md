# Agent Note: Fork upstream sync token

Status: implemented

English | [中文](2026-08-26-fork-upstream-sync.zh.md)

## Problem

`onlyfeng/deepseek-harness` keeps `dev/compat` as the default working branch and treats `origin/master` as a fast-forward-only copy of `deepseek-ai/deepseek-harness`. The scheduled job that performs that fast-forward must push commits that change `.github/workflows/*`, which upstream does routinely.

`github.token` is a GitHub App installation token. GitHub refuses a push that creates or updates a workflow file unless the token has the `workflows` permission, and `GITHUB_TOKEN` cannot be granted that permission. The job then fails with `refusing to allow a GitHub App to create or update workflow … without workflows permission`, and the later integration-PR step never runs.

A token that *can* update workflow files also fires this fork's remaining `on: push` workflows. [`CI master`](../../../../.github/workflows/ci-master.yml) binds self-hosted standby jobs to labels this fork cannot allocate, so those jobs queue indefinitely unless that workflow is disabled in the Actions tab — the same operator action already required for upstream [`CI`](../../../../.github/workflows/ci.yml) in the [fork-hosted CI replacement](2026-08-26-fork-hosted-ci-replacement.md).

## Decision

[`.github/workflows/upstream-sync.yml`](../../../../.github/workflows/upstream-sync.yml) lives on `dev/compat` so the default-branch cron fires, and it is absent from the upstream-identical `master`. The job runs only when `github.repository == 'onlyfeng/deepseek-harness'`.

`origin/master` fast-forwards to `upstream/master` when it is an ancestor of that commit, and the job fails without force-pushing when it is not. When `dev/compat` does not contain `upstream/master`, the job opens or reuses a `master` → `dev/compat` pull request for a human to merge after resolving conflicts.

Checkout and the mirror push authenticate with repository secret `UPSTREAM_SYNC_TOKEN`. Accepted values are a fine-grained PAT with Contents, Pull requests, and Workflows set to Read and write, or a classic PAT with `repo` and `workflow`. A GitHub App installation token is not an accepted value: those expire after one hour and cannot be this static secret. An empty secret fails before fetch, with an error that names the secret and the required scopes. The integration PR is created with REST `POST /repos/{owner}/{repo}/pulls` using that PAT, then `github.token` if the PAT POST fails. A `workflow_dispatch` run must use workflow from `dev/compat`; this file is absent from `master`, and that picker does not choose the mirror branch.

Operators disable upstream `CI` and `CI master` on this fork. The workflow files stay unmodified so merging `master` does not conflict on `on:` or `runs-on`.

## Alternatives considered

**Grant `permissions: workflows: write` to `GITHUB_TOKEN`.** That key is invalid for `GITHUB_TOKEN`. GitHub rejects the workflow at parse time or still refuses the push, because the automatic token cannot receive Workflows write.

**Fast-forward `master` while omitting `.github/workflows/*`.** `origin/master` would then differ from upstream, breaking the pure-mirror invariant the integration PR relies on.

**Force-push `origin/master` onto upstream.** This would discard any accidental fork-only commit on the mirror instead of failing loudly.

**Push a side branch and open the integration PR from that branch, leaving `master` stale.** Any push of upstream commits still needs Workflows write, and `origin/master` would no longer be the upstream tip.

**Store a GitHub App installation token in `UPSTREAM_SYNC_TOKEN`, or mint one from App credentials on each run.** Installation access tokens expire after one hour, so a static Actions secret cannot survive the daily cron. Per-run minting needs the App ID, private key, and JWT issuance in the job — extra secrets and steps that do not change the Contents / Pull requests / Workflows permission a PAT already grants.

**Open the integration PR with `gh pr create`.** That command calls GraphQL `createPullRequest`. Fine-grained PATs that succeed on REST `POST /repos/{owner}/{repo}/pulls` still fail with `Resource not accessible by personal access token (createPullRequest)`.

**Drop the schedule and sync only from a human clone.** That abandons unattended catch-up; `workflow_dispatch` remains available once the secret is stored.

## Consequences

Scheduled Upstream Sync fails closed until an operator stores `UPSTREAM_SYNC_TOKEN` and disables `CI master`. Token-authenticated pushes to `master` trigger other still-enabled `on: push` workflows (hosted pack, e2e, sandbox); those are operator-disabled or allowed to run on hosted runners, not patched in the mirrored files. Integration PRs opened with the PAT are authored by the token owner rather than `github-actions[bot]`. A `github.token` REST fallback needs Settings → Actions → General → Allow GitHub Actions to create and approve pull requests. Merging that PR into `dev/compat` remains a human step: the job does not resolve conflicts or bypass [fork-hosted CI](2026-08-26-fork-hosted-ci-replacement.md).

## Testing

The workflow YAML parses, and each `run` script passes `bash -n`. An empty `UPSTREAM_SYNC_TOKEN` exits before fetch with the named `::error::`. A live mirror push is not an in-repository test; it requires that secret on `onlyfeng/deepseek-harness`.
