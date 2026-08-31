# Agent Note: Fork 上游同步令牌

Status: implemented

[English](2026-08-26-fork-upstream-sync.md) | 中文

## 问题

`onlyfeng/deepseek-harness` 以 `dev/compat` 为默认工作分支，并把 `origin/master` 当作 `deepseek-ai/deepseek-harness` 的只快进副本。执行该快进的定时作业必须推送会改动 `.github/workflows/*` 的提交，而上游经常这样改。

`github.token` 是 GitHub App 安装令牌。GitHub 拒绝创建或更新 workflow 文件的推送，除非该令牌具有 `workflows` 权限，而 `GITHUB_TOKEN` 无法被授予该权限。作业随后以 `refusing to allow a GitHub App to create or update workflow … without workflows permission` 失败，后面的集成 PR（Pull Request）步骤也不会运行。

*能够* 更新 workflow 文件的令牌同时会触发本 fork 上仍启用的 `on: push` 工作流。[`CI master`](../../../../.github/workflows/ci-master.yml) 把自托管待命作业绑到本 fork 无法分配的标签，因此除非在 Actions 选项卡中禁用该工作流，这些作业会无限排队——这与已经要求对上游 [`CI`](../../../../.github/workflows/ci.yml) 采取的操作者动作相同，见 [fork 托管 CI 替代方案](2026-08-26-fork-hosted-ci-replacement.zh.md)。

## 决策

[`.github/workflows/upstream-sync.yml`](../../../../.github/workflows/upstream-sync.yml) 放在 `dev/compat` 上，以便默认分支的 cron 能触发；它不出现在与上游一致的 `master` 上。作业仅在 `github.repository == 'onlyfeng/deepseek-harness'` 时运行。

当 `origin/master` 是 `upstream/master` 的祖先时，将其快进到该提交；若不是，作业失败且不强推。当 `dev/compat` 尚未包含 `upstream/master` 时，作业打开或复用 `master` → `dev/compat` 的拉取请求，供人工解决冲突后合并。

checkout、镜像推送和 `gh pr create` 使用仓库密钥 `UPSTREAM_SYNC_TOKEN` 鉴权。可接受的值是：Contents、Pull requests 与 Workflows 均为 Read and write 的细粒度个人访问令牌（PAT）；带 `repo` 与 `workflow` 的 classic PAT；或具有相同仓库权限的 GitHub App 安装令牌。密钥为空时在 fetch 之前失败，错误信息会写出密钥名和所需权限。

操作者在本 fork 上禁用上游 `CI` 和 `CI master`。这些工作流文件保持未修改，因此合并 `master` 不会在 `on:` 或 `runs-on` 上冲突。

## 备选方案

**给 `GITHUB_TOKEN` 加上 `permissions: workflows: write`。** 该键对 `GITHUB_TOKEN` 无效。GitHub 会在解析时拒绝工作流，或仍拒绝推送，因为自动令牌无法获得 Workflows write。

**快进 `master` 但省略 `.github/workflows/*`。** `origin/master` 会与上游不同，破坏集成 PR 所依赖的纯镜像不变量。

**把 `origin/master` 强推到上游。** 这会丢弃镜像上任何误加的 fork 专有提交，而不是大声失败。

**推送侧分支并从该分支开集成 PR，让 `master` 落后。** 推送上游提交仍然需要 Workflows write，且 `origin/master` 不再是上游尖端。

**强制使用专用 GitHub App，不允许同一密钥里放 PAT。** GitHub App 安装令牌已是 `UPSTREAM_SYNC_TOKEN` 的可接受值。强制建 App 增加设置，并不改变推送所需的权限。

**取消定时，只从人工 clone 同步。** 这放弃无人值守追齐；一旦存好密钥，`workflow_dispatch` 仍可用。

## 后果

在操作者存入 `UPSTREAM_SYNC_TOKEN` 并禁用 `CI master` 之前，定时 Upstream Sync 以失败告终。用令牌向 `master` 的推送会触发其他仍启用的 `on: push` 工作流（托管 pack、e2e、sandbox）；这些由操作者禁用，或允许在托管 runner 上运行，而不是去改镜像中的文件。集成 PR 的作者是令牌所有者，而不是 `github-actions[bot]`。将该 PR 合并进 `dev/compat` 仍是人工步骤：作业不解决冲突，也不绕过 [fork 托管 CI](2026-08-26-fork-hosted-ci-replacement.zh.md)。

## 测试

工作流 YAML 可被解析，每个 `run` 脚本通过 `bash -n`。空的 `UPSTREAM_SYNC_TOKEN` 在 fetch 之前以具名 `::error::` 退出。真实镜像推送不是仓内测试；它需要 `onlyfeng/deepseek-harness` 上的该密钥。
