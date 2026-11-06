# 第三方组件与协议参考

本次交付为独立实现的 Android TV 兼容客户端，不是 pcccccc/AngelLive 或插件源维护者的官方发行版。原 Angel Live 是 Apple 平台 Swift 项目；本客户端以 Flutter/Dart、Kotlin 和 JavaScript 实现宿主协议。

| 组件 | 本次版本 / 来源 | 许可与源码 |
| --- | --- | --- |
| Angel Live 协议参考 | fd0d548c4183c7d2d1d9082bef723ec456f9a262 | https://github.com/pcccccc/AngelLive ，上游 GPLv3 文本随附 |
| Flutter / Dart | Flutter 3.38.3 | https://github.com/flutter/flutter/tree/3.38.3 ，BSD 风格许可；https://github.com/dart-lang/sdk |
| media_kit | 1.2.2 | https://github.com/media-kit/media-kit ，MIT |
| media_kit_video | 1.3.1 | 同上，MIT |
| media_kit_libs_video | 1.0.7 | 同上，MIT |
| media_kit_libs_android_video | 1.3.8 | https://pub.dev/packages/media_kit_libs_android_video/versions/1.3.8 ，MIT 包装层 |
| libmpv Android 原生视频库 | v1.1.7 | https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.7 ，依赖构建入口见该仓库的 buildscripts 和 Gradle 配置 |
| mpv / FFmpeg | 上述原生构建中包含 | https://github.com/mpv-player/mpv / https://ffmpeg.org/ ，GPL/LGPL（取决于构建选项） |
| archive / crypto / path / path_provider / qr_flutter 等 | 见 pubspec.lock | 随附已解析 Pub 依赖的 LICENSE 原文 |

原生库使用 media_kit 提供的预编译 JAR，未修改二进制。包装层的 MIT 许可不取代所包含的 mpv、FFmpeg 及其依赖许可。重新分发时应保留这些声明和相应源码/构建信息。

源码 ZIP 不含第三方插件、下载缓存、签名私钥、账号或临时直播地址。插件索引 URL 是应用默认配置，保留在 `assets/bootstrap.json`；插件的版权、许可和服务限制以各插件原始清单为准。
