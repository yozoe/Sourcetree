# macOS 单进程多窗口模型

日期：2026-08-22

状态：已实现

## 目标

Git Desktop 在 macOS 上采用“一个应用进程 + 一个仓库首页窗口 + 多个单仓库工作区窗口”的模型：

- 整个 App 只有一个 `NSApplication` 进程和一个 Dock 图标。
- 首页和每个工作区都是独立的原生 `NSWindow`。
- 每个窗口拥有自己的 `FlutterEngine`、`FlutterViewController` 和 Dart isolate。
- 一个工作区窗口只承载一个仓库，同一标准化仓库路径只能存在一个工作区窗口。
- 新窗口位于最前方；重复打开同一仓库时激活已有窗口。
- 明确退出 App 或在 `flutter run` 中按 `q` 时，整个进程及全部窗口一起退出。

单进程是窗口生命周期和应用生命周期的边界；多 Engine 用于保持各工作区 UI 与仓库状态隔离，
不再通过启动同一 app bundle 的多个实例实现窗口隔离。

## 进程与窗口角色

### 应用进程

唯一的 regular app 进程负责：

- 持有 `AppDelegate`、Dock 菜单和应用级快捷键。
- 创建并持有窗口协调器 `WindowCoordinator`。
- 管理首页窗口和全部工作区窗口的创建、激活、关闭与去重。
- 在应用退出时关闭全部 Flutter Engine、Git 子进程和原生资源。

不再使用 accessory 工作区进程、PID 注册、进程启动时间、
`DistributedNotificationCenter` 或 `NSWorkspace.openApplication` 创建工作区。

### 仓库首页窗口

首页窗口负责恢复并显示已知仓库清单，发起打开、克隆和初始化请求，并持久化成功打开的仓库。
首页窗口可以被关闭；只要仍有工作区窗口，应用进程继续运行。工作区按 `Command + N` 时，
窗口协调器激活已有首页窗口，或在首页已销毁时重新创建它。

### 仓库工作区窗口

每个工作区窗口拥有独立 Flutter Engine 和独立 Riverpod 容器，只加载一个标准化仓库路径，
负责该仓库的 Git 状态、历史、Diff 和写操作。工作区不恢复首页的全局仓库清单，也不在同一
窗口内切换为另一个仓库；“打开仓库”请求继续交给窗口协调器创建或激活目标工作区窗口。

工作区初始配置由创建该 Engine 的原生宿主通过 `dartEntrypointArguments` 注入。这些参数属于
当前进程中新建 Engine 的 Dart 入口，不是另一个应用进程的启动参数。

### 工作区标签合并

工作区默认仍以独立窗口打开，以保留现有的多窗口工作流。系统“窗口”菜单中的“合并所有窗口”
会把全部已打开的工作区收拢到当前工作区的原生 macOS tab group，标题栏下方的标签使用已识别的
仓库名。首页窗口不参与合并。

原生标签只改变窗口呈现方式：每个标签仍对应一个 `WorkspaceFlutterWindowController`、一个
`FlutterEngine`、一个 Dart isolate 和一份 Git 操作状态。关闭一个标签会走该工作区既有的有界
清理与注销流程，不会关闭同组内的其他仓库。

## 原生结构

建议的所有权关系如下：

```text
NSApplication / AppDelegate
└── WindowCoordinator
    ├── repositoryLibrary: MainFlutterWindow（NIB 创建的初始 Engine）
    └── workspaces: [CanonicalRepositoryPath: WorkspaceWindowController]
        └── FlutterEngine + FlutterViewController（每个仓库一组）
```

`WindowCoordinator` 是窗口身份和生命周期的唯一事实来源。窗口控制器关闭时必须注销自身；
Flutter 状态不得自行维护另一份原生窗口注册表。

## 打开与去重流程

```text
首页/工作区选择仓库
  → Flutter MethodChannel: openWorkspace
  → WindowCoordinator 标准化路径并解析 symlink
  → 已存在：恢复最小化状态并激活已有 NSWindow
  → 尚未创建：在主线程同步注册路径并在当前进程创建 FlutterEngine、FlutterViewController 和 NSWindow
  → Engine 就绪：通过 Dart 入口参数注入仓库路径和初始动作
  → 创建失败：向发起请求的 Engine 返回 FlutterError
```

去重键使用标准化仓库路径；由于全部窗口属于同一进程，不再需要 PID 和进程启动时间防止复用。
同一路径窗口关闭后，协调器先移除对应注册，再允许创建新窗口。

## 窗口激活、快捷键与 Dock

App 以普通 regular activation policy 运行，所有窗口共享唯一 Dock 图标。工作区不再需要
`LSUIElement`、accessory policy 或临时启动另一个 app 实例来隐藏额外 Dock tile。

窗口协调器直接执行以下操作：

- `Command + ~`：在仓库首页与最近获得焦点的工作区之间切换。
- 点击 Dock 图标重新激活 App：恢复最后成为 key window 的首页或工作区；若该窗口已关闭，
  回退到仍存活的工作区 MRU，最后才显示首页。
- 工作区中的 `Command + N`：显示或激活仓库首页。
- 重复打开同一仓库：取消最小化、移动到当前 Space 并置前已有窗口。
- “窗口”→“合并所有窗口”：将全部工作区加入当前工作区的原生标签组；仅在存在未合并的多个
  工作区时可用。
- App 的 `Quit` 或 `flutter run` 的 `q`：终止唯一进程，全部窗口一起退出。

协调器使用有序的 MRU 记录维护工作区焦点历史；当前工作区关闭后，切换目标是仍存活窗口中
最近获得过焦点的一个，而不是依赖字典枚举顺序。

快捷键由应用菜单或应用级事件处理器路由到 `WindowCoordinator`，不再发送跨进程通知。

## 跨窗口状态

多个 Flutter Engine 拥有不同 Dart isolate，不能直接共享 Riverpod 内存。跨窗口协调通过当前
进程内的原生协调器完成：

1. 工作区进入 ready 状态后，通过 MethodChannel 报告标准化仓库路径。
2. 协调器更新工作区注册并通知首页 Engine。
3. 首页等待初始会话恢复结束，再按接收顺序登记仓库。
4. 主题或其他全局偏好持久化后，由协调器广播给所有存活 Engine，文件仍作为重启后的事实来源。

这里是进程内消息路由，不使用分布式通知，也不依赖不同进程刷新同一份 `UserDefaults` 缓存。

## 关闭与退出语义

- 关闭工作区窗口：销毁该窗口控制器和对应 Flutter Engine，不影响其他窗口。
- 关闭仓库首页窗口：隐藏或销毁首页窗口，但应用在存在工作区时继续运行。
- 工作区按 `Command + N`：重新显示或创建首页窗口。
- 明确退出 App：按顺序停止全部窗口、Engine 和 Git 子进程，然后结束唯一进程。
- `flutter run` 控制台按 `q`：终止被调试的唯一应用进程，因此全部窗口一起退出。

工作区关闭或应用退出前，原生协调器先通过 `prepareToClose` 请求对应 Dart isolate 取消
Clone、Fetch、Pull、Push 和 AskPass，卸载 Widget 树并释放该 Engine 的 Riverpod 容器。
收到回执后才销毁 Engine；回执异常时使用有界超时，避免退出流程永久挂起。

不再存在“仓库首页进程退出但工作区进程残留”或“工作区重新启动首页进程”的状态。

## Flutter 调试边界

单进程保证一次 `flutter run` 控制整个 App 的退出生命周期，但不承诺动态创建的所有
Flutter Engine 都自动加入同一次热重载或热重启。当前调试边界是：

- `q` 必须结束整个进程和全部窗口。
- `r`/`R` 至少作用于 `flutter run` 直接连接的初始 Engine。
- 若次级 Engine 不能稳定热更新，开发文档必须明确要求关闭并重新创建对应工作区窗口。
- Swift/AppKit 修改始终需要停止并重新执行 `flutter run`。

不能为了宣称“所有窗口可热重载”而重新引入多个应用进程。

## 安装与升级

`./install_macos.sh` 只需要请求唯一的已安装应用进程退出，并确认该进程结束后替换 app bundle。
不再枚举或强制清理 accessory 工作区进程。替换或 LaunchServices 注册失败时仍需恢复旧版本，
且不得留下重复 app bundle。

## 实现状态

- `WindowCoordinator` 和 `WorkspaceFlutterWindowController` 已在唯一应用进程中管理工作区。
- 每个工作区拥有独立 Flutter Engine，关闭窗口时注销路径、移除 MethodChannel handler 并关闭 Engine。
- 窗口路由已改为进程内 MethodChannel；工作区 app 实例、PID 注册、分布式通知、accessory policy
  和孤儿进程清理逻辑均已删除。
- 安装脚本只管理 `/Applications/Git Desktop.app` 的唯一进程。
- 原生测试覆盖 Engine 入口参数、路径索引替换与清理、`Command + N` 和 `Command + ~` 识别。
- 工作区使用统一的原生 tabbing identifier；“合并所有窗口”只合并工作区，不合并首页，也不改变
  各标签的 Engine 所有权。

## 验证

提交前至少运行：

```sh
flutter analyze
flutter test
flutter build macos --release
```

macOS 人工冒烟应覆盖：

1. 首页点击仓库后，新工作区窗口位于最前方且 Dock 始终只有一个图标。
2. 快速连续点击同一仓库，只出现一个工作区窗口。
3. 再次点击已打开仓库，已有窗口从最小化或其他 Space 恢复并置前。
4. 同时打开两个不同仓库，两个工作区各自只显示自己的仓库。
5. 克隆或初始化成功后，仓库立即出现在仍打开或重新创建的首页中。
6. 关闭一个工作区不会影响其他窗口，再次打开同一路径会创建新的工作区。
7. `Command + ~` 可在首页与最近使用的工作区之间往返。
8. 工作区按 `Command + N` 会显示首页，首页中的相同按键仍交给产品定义的首页行为。
9. 明确退出 App 或在 `flutter run` 中按 `q`，全部窗口和应用进程同时结束。
10. 验证 `r`/`R` 对初始 Engine 和次级 Engine 的实际影响，并记录不支持的调试边界。
11. 打开至少两个仓库后选择“窗口”→“合并所有窗口”，确认出现原生标签、标签标题为仓库名；关闭
    一个标签后，其他标签仍可继续执行 Git 操作。
