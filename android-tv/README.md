# Android TV 兼容客户端 0.1.0（测试版）

本 fork 新增的独立 Flutter/Dart/Kotlin 客户端，参照 Angel Live 功能与插件 API v1。不是上游官方安卓发行版，与仓库的 Apple 宿主分别构建。支持 Android API 24+、ARM32/ARM64，提供电视启动入口和方向键导航。

## 从这里开始

- [GitHub 自动构建与签名](docs/GITHUB_ACTIONS.md)：运行 **Android TV APK**，下载 Artifacts。
- [给家里 AI 的 AGENTS.md](AGENTS.md)：按已授权的目标安装、观察、调试和报告。
- [家庭设备安装调试手册](docs/HOME_AI.md)：本地配置、ADB 首次授权、下载成功构建和取证。
- [插件兼容范围](docs/PLUGIN_COMPATIBILITY.md)：已支持与未实现能力。

## 已实现

插件订阅与校验、分类分页、搜索、房间号或分享链接、收藏与历史、账号 Cookie 导入/插件声明的二维码流程、清晰度/线路切换、请求头继承、缓冲超时重新取流与重连。凭据使用 Android Keystore 加密，插件 JavaScript 在隔离 Worker 中运行。

首次安装需要通过私有构建配置 `TV_PLUGIN_SOURCE_URL` 或应用设置提供用户自己的订阅。公开源码的 `assets/bootstrap.json` 不包含真实订阅；第三方插件按需下载，不随源码或 APK 附带。

## 构建与验证

Flutter 3.38.3、JDK 17、Gradle 8.12、AGP 8.9.1、Kotlin 2.1.0，Dart 依赖锁定在 pubspec.lock。完整命令见构建文档。`scripts/verify_apk.py` 核对 APK 签名、包名、ABI、ZIP CRC、对齐和电视入口，再生成安装元数据。

CI 未配置固定签名时生成不同包名的预览包；若要保留之前兼容版的数据连续升级，必须使用同一固定签名。家里 AI 只能通过 ADB 在本地可达的电视上执行安装；GitHub 云端不直接访问家庭网络。

## 验证边界

桌面 Flutter 测试、脚本测试与 APK 静态验证不能代替真实设备检查。Android 桥接、解码、音画、遥控交互和持续播放尚待家庭电视验证；部分插件/内容可能无法使用。首版没有弹幕显示、首页推荐流、OAuth 设备码/Token 登录、登录网页 bootstrap、特殊媒体变换、DRM/CENC 或云同步。

报告请分别列出构建、安装、界面和播放证据，不把进程存在或截图正常称为“已长时间稳定播放”。

## 许可

本模块以 GPL-3.0-or-later 提供，见 LICENSE。协议参考项目：https://github.com/pcccccc/AngelLive ，参考提交 `fd0d548c4183c7d2d1d9082bef723ec456f9a262`。依赖许可见 THIRD_PARTY_NOTICES.md 和 third_party_licenses/。
