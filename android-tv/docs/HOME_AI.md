# 家里 AI：从 GitHub 构建到电视安装与调试

本 fork 的直接复制入口见 [复制给 Codex 的完整任务](../../ANDROID_TV_CODEX.md)，其中列出目标电视、默认订阅和已核验构建。下面是通用操作手册。

## 执行位置与前置条件

GitHub 云端负责构建；家里的电脑负责通过局域网连接电视。普通 GitHub hosted runner 无法直接访问家庭私有地址。不要为了构建把 ADB 端口暴露到互联网。

家里电脑需要 Python 3.10+、Git、GitHub CLI（`gh`）、Android SDK platform-tools 和 build-tools 36.0.0，签名工具需要 JDK 17。把 `adb` 放进 PATH，设置 `ANDROID_HOME` 或模板中的 `sdkPath`；Windows 可在本机私有配置里指定 `adbPath`。Python 脚本仅使用标准库。

1. 在电视“关于”的系统版本/内部版本号位置按提示开启开发者选项，再打开调试功能；具体菜单随固件变化。
2. 电视支持网络调试时，使用电视显示的地址和端口。较新固件若要求无线配对，先用电视展示的配对地址执行 `adb pair`，配对码不保存进仓库。不能假定配对端口等于连接端口。
3. 老固件如只提供 USB 调试，先确认设备已经能通过实际 ADB 数据连接枚举；仅在这一步成立后才可对明确 serial 启用 `adb tcpip`。普通 U 盘接口不能直接当作已建立的 ADB 连接。
4. 首次连接必须有人在电视端接受 RSA 调试授权。这一步不能由未获授权的 AI 远程跳过。

## 一次配置

克隆**用户自己的 fork**，进入 `android-tv/`，将 `tv.local.example.json` 复制为 `tv.local.json`。

先填 `serial` 和本机 SDK 路径，运行：

```shell
python scripts/tv.py connect
python scripts/tv.py doctor
```

将 doctor 返回的实际 `model` 填入 `expectedModel`。营销型号和系统的 `ro.product.model` 可能不同，不要靠型号名称猜这个值。

填写自己的 `githubRepository`（所有者/仓库）、受信任分支和 `expectedCertificateSha256`。签名指纹应来自用户已经信任的本地安装包或已核对的签名证书；不要遇到校验失败就自动改成新包的指纹。

当前兼容版包名为 `works.angel.angel_live_android_tv`。CI 预览版使用 `.preview` 后缀并单独显示名称；若明确测试预览版，私有配置的包名和信任证书也须对应。预览版使用临时开发签名，不保证不同运行之间能覆盖升级。要持续自动升级，配置固定的正式签名。

## 从 Actions 下载并安装

先 `gh auth login` 登录有权访问目标仓库的账号。在仓库 Actions 中确认 **Android TV APK** 的某次运行成功，记录明确的 run ID：

```shell
gh run list --workflow android-tv.yml --branch main --status success
python scripts/tv.py github-install --run-id 123456789
```

运行编号只是格式示例。脚本会核对仓库、workflow、分支、事件、成功状态、源码 SHA 与 artifact 元数据；然后再次检查 APK 本身的签名、SHA-256、包名、ABI 与最低 SDK。通过后执行 `adb install -r`、启动并截图。不会自动卸载、清数据或允许版本降级。

私有配置未准备完整、签名不符或设备未授权时停止依赖它的设备动作。退出码 0 也只说明安装和启动命令通过；最终 UI、音画和播放要看证据。

## 安装本地构建

```shell
python scripts/verify_apk.py path/to/app.apk --output path/to/artifact.json
python scripts/tv.py install --apk path/to/app.apk --metadata path/to/artifact.json
python scripts/tv.py launch
python scripts/tv.py capture
```

检验目标由私有配置固定，不能把不匹配的元数据改一改就安装。

## 遥控与证据

```shell
python scripts/tv.py key down
python scripts/tv.py key select
python scripts/tv.py key back
python scripts/tv.py capture
```

可用按键为 up/down/left/right/select/back/playpause/home。每次按键后查看新截图，再决定下一步。脚本只保存 PNG 原尺寸截图、设备信息、该应用当前进程日志、内存快照和待填写的 observation.md。日志会去掉明显的凭据行和网络 URL，但仍须人工审核；截图可能包含账号或登录二维码，不上传到公共 Issue 或 Git。

没有运行进程时，不会采集其他应用的日志。若要定位启动即崩溃，在启动前用明确包名过滤崩溃缓冲并审核输出；不要把全系统 logcat 原样发布。`capture` 没有设置已通过结论，需要 AI 根据观察填写。

## 故障处理

| 情况 | 下一步 |
| --- | --- |
| offline / unauthorized / connection refused | 检查电视展示的 IP、端口、局域网和 RSA 授权；不要盲目换端口扫描 |
| 证书不匹配 / INSTALL_FAILED_UPDATE_INCOMPATIBLE | 停止安装，核查固定签名；不自动卸载旧包 |
| 版本降级被拒绝 | 使用 versionCode 更高的构建；不加 `-d` 绕过 |
| 插件加载失败 | 核查源可达性、插件 SHA、协议与系统 WebView 版本 |
| 列表可见但无法取流 | 记录当时房间、登录状态和错误；先看插件返回，不能直接归因于解码 |
| 播放后缓冲或冻结 | 采集当前进程日志/内存/截图，记录时间、线路、清晰度与网络状态，再对比另一档位 |
| 无数据/黑屏 | 进程存在不等于视频在播放；结合实际画面、声音和播放器事件判断 |

首次真实设备验收请按 `AGENTS.md` 的清单完成。不要把本地单元测试或 Actions 绿灯当作电视流畅播放的证据。

## 可直接交给家里 AI 的任务

> 阅读根 AGENTS.md、PRODUCT.md、android-tv/AGENTS.md 和 android-tv/docs/HOME_AI.md。使用我的 tv.local.json 中指定的电视和仓库，核对 Android TV APK 的受信任成功运行，验证签名后保留数据安装。启动后逐步截图操作，测试我在私有配置中指定的房间，记录起播、清晰度切换和至少十分钟播放结果。失败时采集该应用日志并定位；不要卸载、清数据、重置账号、扫描内网或改动 Apple 端。报告具体 SHA、版本、设备、动作和未验证项。
