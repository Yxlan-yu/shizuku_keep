# Shizuku 常驻守护

![version](https://img.shields.io/badge/version-v2.5-blue)
![platform](https://img.shields.io/badge/platform-KernelSU%20%7C%20Magisk-green)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

开机以 root 拉起 Shizuku 并常驻看护（解决部分 APP 只要 Shizuku 权限并容易掉的问题），掉线约 10 秒自动补回，授权长期有效。内置 WebUI 可查看状态、切换模式、管理目标应用。

> 依赖已安装 [Shizuku](https://github.com/RikkaApps/Shizuku) 本体，本模块不包含 Shizuku。

---

## 解决什么问题

Shizuku 平时靠 ADB / 无线调试启动，一旦手机重启、调试断开或系统回收，`shizuku_server` 就没了。靠它拿权限的应用（GKD、Canta、MT管理器、音理音理 之类）会立刻掉授权，轻则功能失效，重则反复弹「请启动 Shizuku」「授权已失效」。

本模块用 root 在开机时直接把 Shizuku 服务拉起来，并一直盯着它：进程消失后 6~10 秒内自动补回来。之后不用再连电脑、不用再点无线调试，授权保持有效。

## 特点

- **开机自启**：root 直接拉起，不需要 ADB / 无线调试
- **掉线自愈**：服务不在时每 6 秒探测一次，12 秒心跳，掉了几秒就回来
- **两种模式**：永久开启（全局，推荐）/ 按需唤醒（只在指定应用进前台时拉起）
- **自动发现**：扫描所有声明了 `moe.shizuku.manager.permission` 的应用，新装的自动纳入
- **WebUI 管理**：状态、PID、模式开关、应用列表（带真实图标和名称）、运行日志，点点就能改
- **单实例保护**：`mkdir` 原子锁 + pidfile，开机瞬间不会拉出两个守护
- **弱侵入**：不 patch 系统、不注入应用，只用 root 启动 Shizuku 自己的启动器

## 安装

1. 下载 [Releases](../../releases/latest) 里的 `shizuku_keep_vX.Y.zip`
2. KernelSU / Magisk 管理器 → 模块 → 从本地安装 → 选这个 zip
3. 重启设备

不想重启的话，装完在 WebUI 里点「重启服务」即可立刻生效。

**WebUI 仅 KernelSU 支持**（需要管理器 3.x 的 WebView 接口）。Magisk 下模块照常工作，只是没有图形界面，改用下面的命令行和 `config.conf`。

## 使用

### WebUI

模块卡片上的 `<>` 按钮进入，能看到：

| 区块 | 作用 |
|---|---|
| 状态卡 | 服务是否在跑、PID、运行身份（uid/ppid）、守护进程、运行时长 |
| 运行模式 | 「永久开启」与「按需唤醒」一键切换 |
| 自动发现 | 开关；关掉后列表里只剩手动添加的项 |
| 目标应用 | 每行一个应用，带图标、名称、包名和来源标签 |
| 运行日志 | 倒序显示，最新一条在最上面 |

列表里的两个标签只是**来源标记**，权限上没有区别，在这张表里就会在切到前台时拉起 Shizuku：

- **手动**：你自己在「+ 添加」里选的，写进 `config.conf` 的 `WATCH_APPS`
- **自动**：自动发现扫出来的（该应用在 Manifest 里申请了 Shizuku 权限）

删除行为略有不同：删「自动」项会顺手写进 `EXCLUDE_APPS` 黑名单，否则下次扫描又冒回来；删「手动」项直接从 `WATCH_APPS` 拿掉。

「+ 添加」弹层默认只列**用户应用**，系统应用整体屏蔽，点右上角「显示系统应用」才放开。三个页签：全部应用 / 最近打开 / 手动输包名。

### 两种模式

| | 永久开启 `ALWAYS_ON=1`（默认） | 按需唤醒 `ALWAYS_ON=0` |
|---|---|---|
| 行为 | Shizuku 一直在线 | 只在目标应用处于前台时拉起 |
| 覆盖范围 | 全局，任何应用都能拿授权 | 仅列表内的应用 |
| 新装应用 | 不用管 | 自动发现会补进来（`AUTO_WATCH=1`） |
| 耗电 | 极小（12 秒一次 `pidof`） | 更小 |
| 适合 | 想彻底告别掉授权 | 在意常驻内存，能接受首次打开慢几秒 |

### 命令行

需要 root：

```sh
su -c 'sh /data/adb/modules/shizuku_keep/watch.sh list'          # 看当前列表
su -c 'sh /data/adb/modules/shizuku_keep/watch.sh add <包名>'      # 手动添加
su -c 'sh /data/adb/modules/shizuku_keep/watch.sh rm  <包名>'      # 移除
su -c 'sh /data/adb/modules/shizuku_keep/watch.sh auto'           # 立即重新扫描
su -c 'sh /data/adb/modules/shizuku_keep/watch.sh now'            # 立即拉起服务
```

不带参数运行会打印用法。

## 配置

改 `/data/adb/modules/shizuku_keep/config.conf`，保存即生效——守护每一轮都会重新读这个文件，不用重启。

| 项 | 默认 | 说明 |
|---|---|---|
| `ALWAYS_ON` | `1` | `1` 永久开启（全局），`0` 按需唤醒 |
| `WATCH_APPS` | `"moe.ouom.neriplayer"` | 手工目标应用，空格分隔 |
| `AUTO_WATCH` | `1` | `1` 自动发现声明了 Shizuku 权限的应用 |
| `AUTO_RESCAN` | `1800` | 自动重扫间隔（秒） |
| `EXCLUDE_APPS` | `""` | 自动发现的黑名单，空格分隔 |
| `POLL_DEAD` | `6` | 服务不在时的探测间隔（秒） |
| `POLL_ALIVE` | `12` | 服务健在时的心跳间隔（秒） |

## 工作原理

```
service.sh（root，PPID=1）
   ├─ 等 sys.boot_completed
   ├─ 读 config.conf
   ├─ 检查 pidof shizuku_server
   └─ 不在 → 执行 Shizuku 自带的 lib/arm64/libshizuku.so
              （它自己切 mount namespace / cgroup，定位 base.apk，
                再以 root 启动 shizuku_server）
```

几个踩过的坑，写在代码注释里了：

- **不能用 `app_process` 启动**：Shizuku 的 starter 依赖 native 库，直接跑会 `UnsatisfiedLinkError: librish.so`，必须调用 APK 里的 `libshizuku.so`。
- **启动器日志不能写进模块目录**：启动过程中它会调 `pm`，在模块目录里会报 `fatal: can't get path of manager`，日志要落到 `/data/local/tmp`。
- **HyperOS 没有 `topResumedActivity`**：前台检测同时匹配 `topResumedActivity` 和 `ResumedActivity`，再退回 `mFocusedApp`。
- **自动发现不能用 `grep shizuku`**：`dumpsys package` 的输出里混着最近任务列表，会误判；只认 `moe.shizuku.manager.permission` 这条权限声明。
- **别 `pkill -f service.sh`**：会把自己也匹配进去，用 pidfile + 锁目录判断存活。

## 文件

| 路径 | 说明 |
|---|---|
| `/data/adb/modules/shizuku_keep/` | 模块本体（config、脚本、webroot） |
| `/data/adb/modules/shizuku_keep/keep.log` | 守护日志（超过 80KB 自动清空） |
| `/data/local/tmp/shizuku_starter.log` | Shizuku 启动器自己的日志 |
| `/data/adb/shizuku_keep.auto` | 自动发现结果缓存 |
| `/data/adb/shizuku_keep.names` | 应用名/图标缓存 |
| `/data/adb/shizuku_keep.lock/pid` | 单实例锁 |

## 常见问题

**升级会不会丢配置？**
不会。安装脚本会在升级时把旧的 `config.conf` 拷回来。想彻底重置就删掉这个文件再装。

**要不要装 Shizuku？**
要，本模块只是拉起和管理 Shizuku 本体，不替代它。

**更新后模块卡片文案没变？**
KernelSU 管理器缓存了卡片信息，退出模块详情页再进一次就好。

**会不会被判成病毒/被系统杀？**
不会。守护是 root 启动的普通 shell 循环，没有注入任何进程；`shizuku_server` 本身就是 Shizuku 自己的服务。

## 致谢

- [Shizuku](https://github.com/RikkaApps/Shizuku) — RikkaApps
- 包名/图标走的是 KernelSU Manager 3.x 的原生接口（`ksu.pm()` / `ksu://icon`），解析思路参考 Device Faker

## License

MIT
