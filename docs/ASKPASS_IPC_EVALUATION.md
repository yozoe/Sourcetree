# 一次性 AskPass IPC 评估

日期：2026-08-20  
状态：macOS bundle 的用户主动远端操作已接入；发布与兼容性验证待完成

## 结论

首版继续保持 `GIT_TERMINAL_PROMPT=0`。在 macOS helper、受限 IPC、取消和
泄漏测试全部完成前，应用不得把密码、Token、SSH 私钥口令或 OAuth 回调交给
Git 子进程。

后续交互认证仅采用一次性 AskPass helper 加本机 IPC；不通过命令参数、普通
环境日志、remote URL、剪贴板或持久化文本文件传递秘密。

## 建议架构

```text
用户确认的 Clone / Fetch / Pull / Push
  → Application 创建单次 AuthenticationSession
  → 生成 256-bit nonce 与仅当前用户可读的 Unix domain socket
  → GitInvocation 设置 GIT_ASKPASS、GIT_TERMINAL_PROMPT=0、会话标识
  → 签名的 AskPass helper 接收 Git prompt
  → helper 通过 socket 发送 prompt 元数据和 nonce
  → Flutter UI 显示受控输入框
  → 秘密仅通过 socket 响应返回 helper，再写入 AskPass stdout
  → Git 退出 / 取消 / 超时后关闭 socket、销毁 nonce 与内存中的秘密
```

AskPass helper 不应解析或保存 Git 命令；它只将单次 prompt 转发到指定 socket。
应用只显示经过脱敏的远端主机和 prompt 类型，不显示含用户信息、Token 或查询
参数的完整 URL。

应用侧已实现并测试非秘密请求的协议校验：nonce 必须为 256-bit 十六进制值，消息
只允许 `nonce` 和 `prompt` 两个字段，prompt 限制为 8 KiB。该代码不接收、保存或
序列化秘密。Flutter 侧现已实现一次性 Unix socket session：在权限为 `0700` 的
随机临时目录创建 `0600` socket，每次生成新 nonce，只接受一条连接/请求，并在成功、
拒绝、取消或 60 秒超时后关闭并删除 endpoint。它只把 UI 回调的单次回答编码为响应
帧，限制整个响应为 16 KiB，且不保留秘密；取消时不发送空秘密。Dart 标准库暂未暴露
UID；开发/测试 runtime 的 Dart fallback 以随机私有目录和权限复核收紧访问面。正式
macOS bundle 则通过 native broker 在 server 端完成 helper peer UID 校验。

macOS 已有固定路径的 `git-desktop-askpass` C helper，Xcode 会将其编译到
`Git Desktop.app/Contents/MacOS/`，并已通过 Debug bundle 的签名完整性验证。
helper 只接受绝对 Unix socket 路径、64 位十六进制 nonce 和一个 prompt；它转发
长度受限的 JSON 请求，并仅将 socket 返回的秘密写到 stdout。

helper 在连接前通过 `lstat` 要求 endpoint 为当前有效 UID 拥有的 `0600` Unix socket，
连接后用 macOS `getpeereid` 再确认服务端 peer UID 与当前有效 UID 相同；非 socket 或
宽松权限的路径会在发送 prompt 前失败。Flutter 标准库仍不能在 server 端验证 helper
client UID。已新增并打包 `git-desktop-askpass-broker`，它会在 accept 后以
`getpeereid` 验证 helper client UID；正式 macOS app bundle 的 Flutter session 现已使用
该 broker，开发/测试中的非 bundle runtime 继续使用 Dart fallback。完整链路已有
Flutter session、broker 与 helper 的进程级测试。

session 只可根据 `Platform.resolvedExecutable` 的 `*.app/Contents/MacOS/` 固定 bundle
布局推导 helper 路径，并生成 `GIT_ASKPASS`、`GIT_TERMINAL_PROMPT=0`、socket 与 nonce
四项环境变量；生产调用不接受仓库配置、remote 或 UI 文本指定 helper。测试可使用独立
fixture 路径验证 IPC，并以 `@visibleForTesting` 标识测试入口。当前只有 macOS 正式 app
bundle 的用户主动 Clone、Fetch、Pull、Push 会为实际远端 Git 子进程传入这些环境变量。
Flutter 的提示协调器只在状态中保存已校验的非秘密请求，用户输入直接回传 session 后即被
清除；取消操作会同时取消提示、关闭 socket/broker 和失效 nonce。开发与测试运行时不猜测
helper 路径、不设置 `GIT_ASKPASS`，仍可使用既有 credential helper 或 SSH Agent，但
`GIT_TERMINAL_PROMPT=0` 保持生效。

## 不可妥协的安全契约

1. socket 目录权限为 `0700`，socket 权限为 `0600`；创建后验证 owner 为当前 UID。
2. 每次 Git 操作生成新 nonce；helper 的第一帧必须携带该 nonce，且只接受一次连接。
3. IPC 请求采用长度受限的结构化消息，prompt 文本最大 8 KiB，秘密最大 16 KiB；
   拒绝未知字段、重复回答和超限数据。
4. helper 只允许位于应用已签名 bundle 内的固定绝对路径；不接受仓库配置或用户输入
   指定的 AskPass 可执行文件。
5. GitInvocation 继续强制 `GIT_TERMINAL_PROMPT=0`；只在用户显式发起的远端写/读
   操作中设置 `GIT_ASKPASS`，后台刷新永不设置。
6. 密码、Token、私钥口令、完整认证 URL、IPC payload 不进入 `GitResult`、操作日志、
   崩溃报告或 `technicalDetails`。UI 输入框禁用自动填充、复制和调试输出。
7. 取消、Git 退出、窗口关闭、helper 断开、60 秒超时都必须关闭 socket、终止 helper，
   并使 nonce 失效；之后的连接一律拒绝。
8. 认证结果只交由用户现有 Git credential helper/SSH Agent/Keychain 决定是否持久化；
   应用自身不落盘保存秘密。

## 认证状态机

```text
准备 → 运行 Git → 等待 AskPass prompt → 用户回答 / 拒绝 / 超时
→ Git 继续 → 成功 / 失败 / 取消 → 销毁会话 → 刷新仓库
```

同一仓库在等待认证时保持写操作独占。用户取消应同时取消 Git、关闭 IPC 并清除 UI
输入内容；不能因为 helper 已经读取秘密就假设远端操作未发生。

## 实施前验证清单

- [x] macOS helper 的 Debug bundle 路径、C 编译和签名完整性验证。
- [ ] Release/Developer ID 签名与 Gatekeeper 行为验证。
- [x] nonce 重放、第二连接、畸形 UTF-8 与错误 nonce helper 的负向测试。
- [ ] 错误 UID 与签名 helper 欺骗测试（peer UID 已验证；仍需要发布签名环境）。
- [x] 非秘密 IPC 请求的未知字段、非法 nonce 与超长 prompt 校验。
- [x] 一次性 Flutter Unix socket 的 nonce、单连接、超时、拒绝和清理测试。
- [x] macOS helper 与 Flutter session 的进程级 socket 往返测试（测试临时编译同一 C 源码）。
- [ ] Token、用户名密码、SSH passphrase、拒绝认证、网络中断和用户取消的真实远端测试。
- [x] 源码、日志入口、异常和操作面板的秘密泄漏扫描；URL userinfo、常见认证 Header 和
  query 秘密键由脱敏单元测试覆盖。
- [x] Git credential helper 调用顺序与 SSH Agent socket 环境继承的契约测试。
- [ ] 真实 macOS Keychain、SSH Agent、企业 SSO 与受认证远端的兼容性测试。
- [x] macOS 核心工作区 UI E2E：真实 Flutter desktop app 配合本地 bare remote fixture，覆盖
  打开工作区、暂存、提交、创建分支、推送及远端 ref 核验。
- [x] macOS bundle AskPass UI E2E：native helper、broker、session 与 Flutter 脱敏认证弹窗
  的完整取消链路，不显示原始 URL 或 userinfo。
- [ ] macOS UI E2E：认证等待、取消、恢复和远端结果核验。

## 当前边界

当前版本只在 macOS 正式 app bundle 的用户主动 Clone、Fetch、Pull、Push 中启用认证
UI、helper 和 session；后台 refresh、status、diff、仓库探测以及 Push 后 `ls-remote`
核验均不会注入 AskPass 环境。非 bundle 的开发和测试运行时仍依赖已有无交互
credential helper 或 SSH Agent；出现认证需求时不会在隐藏的 Git 子进程中等待终端输入。

受控认证弹窗已通过提示协调器接入上述用户主动操作：它只显示认证类型，不渲染原始 Git
prompt、完整 URL 或用户名；密码和私钥口令字段关闭自动填充、建议、自动更正与选择菜单，
取消返回 `null`。

当前自动化覆盖验证 GitRunner 继续使用配置的 credential helper，并保留 `SSH_AUTH_SOCK`；
macOS Keychain 通过 credential helper 协议复用这一执行路径，但尚未以真实钥匙串和企业
SSO 账号做端到端验证。应用不会读取、导入或持久化这些系统凭据。
