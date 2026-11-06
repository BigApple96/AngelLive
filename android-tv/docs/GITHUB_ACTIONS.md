# GitHub 自动生成 APK

## 启用与下载

本 fork 新增 `.github/workflows/android-tv.yml`，名称 **Android TV APK**，独立于上游 Apple CI。首次进入 fork 的 Actions 页面按提示启用工作流。

默认分支存在该 workflow 后，可选择 **Run workflow**。修改安卓目录并 push 也会触发。Pull request 只产生预览包；默认分支可使用固定签名。成功后在该次运行的 Artifacts 中下载 `android-tv-apk`，其中包含 APK、`artifact.json`、SHA-256 文件和许可。

Artifacts 是构建产物，不是应用商店发布；本工作流不创建 Release、不上传商店，也不从云端连接家庭电视。仓库原有 Apple CI 需要它自己的环境，不能用那个 workflow 判断安卓构建。

## 签名与默认插件源

在仓库 Settings → Secrets and variables → Actions 配置：

| Secret | 内容 |
| --- | --- |
| TV_KEYSTORE_BASE64 | 固定安卓签名 JKS 文件的 Base64 文本 |
| TV_STORE_PASSWORD | keystore 密码 |
| TV_KEY_ALIAS | 证书别名 |
| TV_KEY_PASSWORD | 对应私钥密码 |
| TV_PLUGIN_SOURCE_URL | 可选，用户自己的 HTTPS 插件订阅 URL |

使用与已安装兼容版相同的签名才能保留数据覆盖升级。私钥、密码、真实订阅和设备配置不进 Git；签名也不放 Actions 缓存或 artifact。插件订阅会编译进 APK，因此不能把账号 Cookie、Token 或应保密的访问凭据混进这个 URL。

如已决定把自己现有签名存入该仓库的 Actions Secrets，可在登录 `gh` 后使用 `scripts/setup_github_secrets.py --repo <所有者/仓库> --key-properties <本机私有配置> --keystore <本机JKS> --plugin-source-file <本机订阅文本>`。此命令会实际上传签名和密码到明确指定的仓库，内容通过标准输入交给 GitHub CLI，不打印或提交。它不会自动运行；不要将私有配置文件放进公开提交。

未配置四项签名 Secret 时，auto 模式产生不同包名的预览版；配置了一部分时直接报错。signed 模式要求四项完整。preview 模式强制生成预览版。正式签名和私有配置只在非 PR 的受信任默认分支构建使用；不要改用 `pull_request_target` 给不可信代码提供签名。

工作流保留版本名 0.1.0，使用该 workflow 的运行序号作为 versionCode。以后发布新功能版本应先按用户要求决定版本名；签名变更与数据迁移必须单独确认。初次运行的 versionCode 低于电视现有值时，需要显式指定更高构建号，不能绕过安装器降级保护。

## 本地构建

使用 Flutter 3.38.3、JDK 17、SDK/build-tools 36、NDK 28.2.13676358、Gradle 8.12、AGP 8.9.1、Kotlin 2.1.0。版本锁在 pubspec.lock 和 Android 工程中。通过 `android/key.properties` 配置自己的签名；本地默认未设置 CI 预览属性时保持正式包名。

```shell
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
python -m unittest discover -s scripts/tests -v
flutter build apk --release --no-pub --target-platform android-arm,android-arm64 --build-number 2
python scripts/verify_apk.py build/app/outputs/flutter-apk/app-release.apk --output dist/artifact.json
```

构建号 2 只是示例，应高于目标设备已安装版本。Linux/macOS 首次构建需 `chmod +x android/gradlew`。
