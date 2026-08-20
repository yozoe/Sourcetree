# 一次性 AskPass IPC 评估

日期：2026-08-20  
状态：设计结论已确认；尚未启用真实凭据输入

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

- [ ] macOS helper 的签名、bundle 路径和 Gatekeeper 行为验证。
- [ ] nonce 重放、错误 UID、第二连接、超长 prompt、畸形 UTF-8 和 helper 欺骗测试。
- [ ] Token、用户名密码、SSH passphrase、拒绝认证、网络中断和用户取消测试。
- [ ] 日志、异常、操作面板和 macOS 诊断包的秘密泄漏扫描。
- [ ] 真实 Git credential helper、SSH Agent、Keychain 与企业 SSO 的兼容性测试。
- [ ] macOS UI E2E：认证等待、取消、恢复和远端结果核验。

## 当前边界

当前版本尚未提供认证输入 UI 或 AskPass helper；私有远端依赖用户现有无交互
credential helper 或 SSH Agent。出现认证需求时应用显示可操作的认证错误，不会在
隐藏的 Git 子进程中等待终端输入。
