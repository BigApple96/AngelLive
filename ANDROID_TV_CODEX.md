# 安卓电视：复制给 Codex 的安装调试任务

本 fork 只启用 **Android TV APK**，继承的 Apple CI 已停用。目标是 **索尼 KD-55X85J**，Android 实际型号须通过 ADB 读取。

## 直接复制下面整段

把第一行换成电视实际显示的调试地址。首次开启调试、接受 RSA 授权或无线配对需要人在电视上确认。

```text
我的电视 ADB 地址：<填写电视显示的 IP:连接端口；若还没有，请指导我确认>。

请在我家能连接电视的电脑上，安装并调试 https://github.com/BigApple96/AngelLive 的独立安卓电视客户端，目标为索尼 KD-55X85J。只处理安卓 TV，不构建其他客户端。

先检查目录和 Git 状态；没有仓库则克隆我的 fork，已有仓库则保留本地修改。读取根 AGENTS.md、PRODUCT.md、ANDROID_TV_CODEX.md、android-tv/AGENTS.md、android-tv/docs/HOME_AI.md 和插件兼容范围。不要只停在给我操作步骤，要完成当前环境具备条件的安装、取证和问题修复。

准备 Python 3.10+、Git、GitHub CLI、JDK 17、Android SDK platform-tools 和 build-tools 36.0.0。缺失工具从官方来源获取。GitHub 构建 APK，家里电脑通过 ADB 操作电视。不要扫描内网或猜 IP；缺地址或 RSA 授权时只暂停设备动作，继续准备源码、工具和分析。

进入 android-tv，将 tv.local.example.json 复制为忽略的 tv.local.json，填入明确设备地址、本机 SDK/ADB 路径和 BigApple96/AngelLive。运行 scripts/tv.py 的 connect、doctor，用实测 model 填 expectedModel。按本文件已核验构建表固定包名和证书，不因校验失败就接受另一证书。

选定明确成功的 Android TV APK 运行编号，核对仓库、分支 main、源码 SHA、版本、APK SHA-256、实际签名、电视型号、API 和 ABI。使用 python scripts/tv.py github-install --run-id <已核验编号>。只允许保留数据的替换安装，不自动卸载、清数据、降级或重置账号/插件；签名变化则停止安装并报告需要固定签名。

新包已配置默认 JSON 订阅：首次启动或保存的订阅地址为空时，应自动下载完整索引并显示全部插件，数量以实际 JSON 为准；已有自定义订阅要保留。插件 ZIP 首次打开对应入口时按需下载并校验，也可用“安装／更新全部”。索引导入成功不代表全部插件能播放，不能跳过 SHA、版本和协议检查。真实订阅、账号、二维码、设备地址、测试房间和未审核日志只放本机私有配置，不提交公开 GitHub。

启动后先读取原尺寸截图，每次只发一个方向键或确认键，再看新截图。验证默认订阅、遥控焦点、分类、列表、进房、返回、清晰度和线路切换。用我私下指定且当时确认开播的房间测试。针对“列表可见但进不去”和“播放一会卡住并显示未直播”，分别检查索引/插件下载、WebView 桥接、登录、取流返回、播放请求头、播放器错误和状态误判；不要把普通请求失败当作直播结束。

需要改代码时，仅修改安卓模块和对应构建/调试文档。按故障证据定位并做必要修复及相关检查，保留账号、收藏和历史。源码变化后必须重新构建、安装并取证，旧截图不算新版本证据。没有写入权限或固定签名时完成能做的本地修复并给补丁，不假装已上传或安装成功。

至少观察一个实际开播房间连续播放十分钟，记录起播、音画、缓冲、内存、焦点和切换结果。断网/待机实验先确认不影响我当前使用。没有实时声音/画面观察，只能报告进程、日志和截图状态，不能称长时间流畅。

最后报告 run URL、源码 SHA、APK SHA-256、证书、版本、实测型号/API/ABI、安装结果、测试动作、证据路径、修复和未验证项。分别说明构建、安装、界面、起播、持续播放是否通过，不用 Actions 绿灯代替电视实测。
```

## 默认订阅

用户指定的 JSON 通过 Actions Secret `TV_PLUGIN_SOURCE_URL` 写入 APK。公开的 `android-tv/assets/bootstrap.json` 保持空值；真实订阅和第三方插件包不提交。只有受信任默认分支的构建读取该配置，PR 不读取。

首次启动自动导入完整索引；保存的空地址也采用默认值，非空自定义地址保持不变。当前核对的索引有 **19 项**，不按固定数量裁剪。索引可见、ZIP 安装、脚本运行与实际播放分别验收。

## 已核验构建

| 项目 | 已核验值 |
| --- | --- |
| 成功运行 | [42199555302](https://github.com/BigApple96/AngelLive/actions/runs/42199555302) |
| 构建源码 SHA | `46df3ad29eb19a9bdd2603206f034ed7aea05be3` |
| 安装包 | Artifacts → `android-tv-apk` → `AngelLive-TV-preview.apk` |
| 版本 / 架构 | `0.1.0+6`，ARM32 / ARM64 |
| 包名 | `works.angel.angel_live_android_tv.preview` |
| APK SHA-256 | `c0396320307163c7ada41b91e4925e97b0251d3e669a5d56f2702a5cdc42726e` |
| 签名证书 SHA-256 | `482388f43c77de6d2dfecaebd572a03802b0cad88601c85c7b774dd27618893f` |
| 默认订阅 | 已从下载后的实际 APK 核对，与用户指定配置一致 |
| 检查 | Flutter analyze、11 项 Flutter 测试、18 项脚本测试、APK 签名/对齐/双架构/校验值均通过 |
| 真实电视安装与播放 | 尚未验证，按上方任务在家中执行 |

配置完成并核对签名后，在 `android-tv/` 执行：

```shell
python scripts/tv.py connect
python scripts/tv.py doctor
python scripts/tv.py github-install --run-id 42199555302
```

此表只信任明确列出的构建。旧运行 `42185960643` 没有默认订阅；不同预览运行的签名也可能不同，不要直接更换已有配置中的信任指纹来覆盖安装。

## 相关入口

- [安卓源码](android-tv/)
- [自动构建与签名](android-tv/docs/GITHUB_ACTIONS.md)
- [设备操作和日志手册](android-tv/docs/HOME_AI.md)
- [插件兼容范围](android-tv/docs/PLUGIN_COMPATIBILITY.md)
- [Android TV APK 构建下载](https://github.com/BigApple96/AngelLive/actions/workflows/android-tv.yml)

预览版使用独立包名和临时签名，不保证不同运行间可覆盖升级。沿用之前兼容版的数据须使用原固定签名，不自动卸载或清数据来继续调试。
