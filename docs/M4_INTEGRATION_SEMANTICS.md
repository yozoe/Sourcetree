# M4 平台与外部集成语义冻结

本文件冻结当前可验证的产品边界。没有满足“语义、授权、失败恢复和生命周期”四项门槛的能力，
不得新增菜单入口，也不得把待实现入口映射为相近但不同的 Git 操作。

## 当前支持矩阵

范围说明：LFS 只保留仓库详情中的既有只读摘要；Submodule 只保留工作区中的既有只读状态兼容显示。两者都不进入后续写操作、配置修改或独立管理功能；下表描述不得解释为待实现承诺。

| 能力 | 当前可见行为 | 允许的副作用 | 菜单状态 |
| --- | --- | --- | --- |
| 外部 Diff | Apple FileMerge 可比较受支持的只读快照；仓库详情已可编辑并持久化应用级只读 argv 配置；启用且信任仓库后，工作区/历史文件 Diff 入口及原生动作菜单使用该工具 | 只创建私有快照；不写回工作区，不执行仓库 `external diff`/`textconv` | 工作区/历史文件上下文及原生动作菜单已连接 |
| Submodule | 仅保留读取 Git porcelain v2 的提交、索引和工作树状态，并在文件行显示兼容性只读摘要 | 不添加、初始化、更新、同步、推送、切换、移除或提交嵌套仓库 | 不新增 Submodule 菜单入口 |
| Git LFS | 仅保留仓库详情中的既有只读摘要：读取 `.gitattributes` 的 `filter=lfs`、本机工具可用性和只读指针文件数量 | 不提供下载、上传、迁移、清理、配置修改或独立 LFS 管理入口 | 不新增 LFS 菜单入口 |
| Git-flow | v1 Start 支持 feature/release/hotfix 的本地创建并检出；单目标 Finish 支持显式选择本地目标并执行一次 `merge --no-edit --no-ff` | Start 只创建并检出；Finish 只检出目标并合并当前 Git-flow 分支；两者都不推送、不删除、不修改 upstream | “Git Flow…”仅在 Flutter capability 通过时可用；批量 Finish、版本发布和自动清理仍待实现 |
| 托管平台 / Pull Request | 不提供 GitHub 托管平台、Pull Request 创建、浏览或管理入口 | 不调用平台 API，不保存令牌，不自动 Push；GitHub 契约/API/Keychain 原型不属于产品路径 | 不支持；不新增菜单入口 |

## Git-flow v1 语义冻结与已交付边界

Git-flow v1 只覆盖本地分支编排，不把普通 Git 分支操作伪装成“完成 Git-flow”。当前 Start
与单目标 Finish 已按以下固定契约实现：

1. 支持 `feature/`、`release/` 和 `hotfix/` 三类显式前缀；`develop` 与生产基线分支由用户在
   预览中明确选择，不根据远端名称或当前分支猜测。版本号必须通过 Git-flow 对话框明确输入，
   并按完整 SemVer 校验；不会从最近标签或目录名推断。
2. Start 操作只创建一个本地分支并切换到该分支；执行前要求附着 HEAD、工作区干净、没有暂停的
   merge/rebase/cherry-pick/revert、没有其他 Git 写任务，并展示完整分支名和起点 SHA。
3. Finish 当前只允许一个显式本地目标：预览来源分支、目标分支和 `merge --no-edit --no-ff`
   策略，先检出目标，再执行一次合并。默认不删除任何分支、不推送任何远端、不修改远端跟踪
   配置；批量目标和多阶段部分成功保留到后续切片，不自动回滚已完成的 Git 写入。
4. 所有写操作都必须提供 dry-run 预览；冲突沿用现有 Git 暂停状态和 Continue/Abort 恢复入口，
   不在 Git-flow 层自动解析冲突。取消、窗口关闭或 Engine 销毁会终止当前 Git 进程，刷新结果
   不确定时显示不确定状态，不继续执行后续阶段。
5. 不支持远端发布、版本标签签名、自动 changelog、子模块/LFS 联动和隐式 force push；这些能力
   需要独立语义和授权契约。批量 Finish、自动删除、版本发布及上述未交付能力继续保留“（待实现）”
   并使用无副作用提示。

## 外部 Diff 配置门槛

配置只有同时满足以下条件才可交给进程层：

1. 工具类型为只读 Diff；Merge 写回当前拒绝保存。
2. 可执行文件是绝对路径，参数通过结构化 argv 传递，不经 Shell。
3. 参数必须包含 `{before}` 和 `{after}`，仓库相对路径只能通过 `{path}` 注入。
4. 仓库处于应用级 `trusted` 状态，且工具配置单独启用。
5. 前后快照每侧不超过 16 MiB；快照存放于私有临时目录。
6. 取消、切换仓库、窗口关闭和 Engine 销毁都必须终止进程并清理快照。
7. 配置文件采用原子替换；损坏、超限、非法路径和不支持的能力恢复为空配置。

上述门槛已由纯 Dart 配置/存储测试和真实进程生命周期测试覆盖。仓库详情设置面板已冻结字段
编辑、清除、校验失败和工具失败提示；原生动作菜单已复用同一门槛，并在 Flutter capability
快照与 AppKit 二次校验通过后调用，未满足条件时保持禁用或回退 Apple FileMerge。

## 托管平台 / Pull Request 结论（明确排除）

当前仓库只把 Git CLI 和本地凭据辅助链作为 Git 操作事实来源；它们不能被隐式当作
托管平台 API 登录。产品明确不实现托管平台或 Pull Request 能力，因此不新增浏览器交接、URL
构造、平台 API、OAuth、令牌或账户管理流程：

1. GitHub.com、GitHub Enterprise Cloud、GitHub Enterprise Server、企业域名和自定义 API 地址均不进入
   托管平台支持矩阵。通用 Git remote 只能继续用于 Fetch/Pull/Push，不能变成 PR 目标。
2. 不接入 OAuth、GitHub API、平台令牌或平台 Keychain 存储；Git credential helper、SSH agent 和 AskPass
   只服务于 Git 操作，不表示 GitHub.com 网页已登录。
3. 应用不创建、打开、浏览或管理 PR 页面，也不为 PR 读取账户、仓库、分支或权限信息。
4. 原生菜单不保留“创建拉取请求…”占位入口；用户继续使用 Git CLI、GitHub 网页或其他协作工具时，
   本应用不介入其 PR 流程。

## 后续能力的进入条件

- Git-flow：v1 分支前缀、版本号输入、upstream/远端不变、冲突恢复、删除保护、取消和
  dry-run 展示已冻结；单项 Start 与单目标 Finish 已交付。批量 Finish、自动删除、推送和版本
  发布仍需独立语义与验证，未交付入口继续保留“（待实现）”。
- 托管平台 / Pull Request：明确不在产品范围内；不新增 remote 解析、PR 页面 URL、浏览器交接、OAuth、
  GitHub API 或 GitHub API 令牌能力。
- Git LFS：不进入后续功能评估；仓库详情中的只读摘要仅用于说明当前仓库状态，不代表下载、上传、迁移或清理能力。
