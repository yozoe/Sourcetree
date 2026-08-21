# macOS 窗口与进程模型

日期：2026-08-21

状态：已实现，自动化与 Release 构建验证通过

## 目标

Git Desktop 在 macOS 上采用“一个仓库首页 + 每个仓库一个独立工作区进程”的模型：

- 首页是唯一显示 Dock 图标的仓库入口。
- 一个工作区窗口只承载一个仓库。
- 同一仓库路径只能存在一个工作区窗口。
- 新窗口出现时位于最前方，重复点击已有仓库时激活已有窗口。
- 工作区进程的创建和退出不会让 Dock 短暂出现第二个图标。

## 进程角色

### 仓库首页

首页进程使用 regular activation policy，负责：

- 恢复并显示已知仓库清单。
- 发起打开、克隆和初始化工作区请求。
- 接收工作区成功加载仓库的通知。
- 串行登记仓库并持久化会话快照。
- 显示 LaunchServices 启动失败等用户可恢复错误。

首页的 Riverpod 状态只属于首页进程。工作区不能通过写同一个会话文件假装直接修改首页
内存，因此仓库成功加载后必须显式回传首页。

### 仓库工作区

每个工作区是由同一 app bundle 启动的独立 accessory 进程，负责一个仓库的 Git 状态、
历史、Diff 和写操作。工作区不执行全局会话恢复；其初始仓库来自以下启动参数：

```text
--git-desktop-workspace
--git-desktop-repository=<canonical path>
--git-desktop-action=<cloneRepository|initializeRepository>
```

在已有工作区中选择“打开仓库”时，应用会请求另一个独立工作区，而不是在当前进程追加
仓库 tab。克隆或初始化成功后，原先没有仓库身份的工作区会注册最终仓库路径。

## 打开与去重流程

```text
首页/工作区选择仓库
  → Flutter MethodChannel: openWorkspace
  → 原生层标准化路径并解析 symlink
  → 已存在：发送激活通知并置前窗口
  → 正在启动：追加到该路径的 completion 队列
  → 尚未启动：LaunchServices 创建新的 app 实例
  → 启动成功：完成所有等待请求
  → 启动失败：向所有等待请求返回 FlutterError
```

去重注册包含标准化仓库路径、PID 和进程启动时间。仅比较 PID 不安全，因为工作区退出后
macOS 可以把相同 PID 分配给首页或另一个仓库进程。查找已有窗口时必须同时验证：

1. PID 仍对应运行中的应用。
2. bundle identifier 和 bundle 路径与当前 app 一致。
3. `NSRunningApplication.launchDate` 与注册的启动时间一致。

工作区正常退出时只在注册 PID 仍属于自身时删除记录，避免清理后来进程的新注册。

## 前台激活与 Dock

`Info.plist` 将 app 声明为 `LSUIElement`，因此 LaunchServices 创建任何新进程时都不会先
产生 Dock tile。`AppDelegate` 在首页进程初始化时将 activation policy 提升为 regular；
工作区保持 accessory。

新工作区完成原生窗口初始化后会：

1. 移动到当前 Space。
2. 取消最小化并激活进程。
3. 将窗口短暂设为 floating 并 `orderFrontRegardless`。
4. 200 ms 后恢复 normal level，同时保持 key window 和前台顺序。

这一短暂层级只用于跨应用启动时可靠置前，不会让仓库窗口长期覆盖其他应用。

## 首页同步

工作区进入 ready 状态后通过 MethodChannel 向其原生宿主报告标准化仓库路径。原生宿主：

1. 更新该工作区的去重注册和激活目标。
2. 通过 `DistributedNotificationCenter` 通知首页进程。
3. 首页原生窗口将通知转发给 Flutter。
4. 首页等待初始会话恢复结束，再按接收顺序打开并登记仓库。

串行队列保证两个工作区同时完成时，不会让 `repositoryGeneration` 互相失效，也不会基于
同一个旧快照产生最后写入者覆盖。

## 主题共享

主题模式和主题色保存在应用支持目录的 `ui-preferences.json`。每次保存先写独占临时文件，
刷新后以 rename 替换目标；其他进程监听父目录事件并重新加载，因此首页和工作区会同步主题。
无法读取或解析时使用系统模式与 Cobalt 默认主题，保存失败只影响持久化，不撤销当前切换。

## 安装与升级

`./install_macos.sh` 会先请求首页退出，再终止仍属于已安装 bundle 的 accessory 工作区。
确认全部进程退出后，新 app 和旧 app 都暂存在 `/Applications` 下的同一隐藏目录中完成替换。
安装或 LaunchServices 注册失败时恢复旧 app；成功后删除暂存目录并正常启动，不保留会造成
LaunchServices 或 Dock 识别冲突的第二个 app bundle。

## 验证

提交前至少运行：

```sh
flutter analyze
flutter test
flutter build macos --release
```

macOS 人工冒烟应覆盖：

1. 首页点击仓库后，新窗口位于最前方且 Dock 始终只有一个图标。
2. 快速连续点击同一仓库，只出现一个工作区。
3. 再次点击已打开仓库，已有窗口从最小化或其他 Space 恢复并置前。
4. 同时打开两个不同仓库，两个工作区各自只显示自己的仓库。
5. 克隆或初始化成功后，仓库立即出现在仍打开的首页中。
6. 退出工作区并反复打开不同仓库，不会因 PID 复用激活错误窗口。
7. 人为制造 LaunchServices 启动失败时，首页显示错误而不是静默无响应。
