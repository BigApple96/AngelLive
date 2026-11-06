# 插件兼容范围

支持 API v1、manifest、预加载脚本和全局 LiveParsePlugin。下载包必须匹配索引的 ID/版本并通过 SHA-256、ZIP CRC；拒绝路径穿越、符号链接与超限内容。第三方插件不在仓库中，真实源通过私有配置提供。

## 宿主能力

| 能力 | 实现 |
| --- | --- |
| HTTP | 请求头、文本/二进制 body、响应、受控重定向、超时和 Cookie |
| 凭据模式 | HTTPS/WSS 与平台域名边界、正式/登录事务 Cookie、cookieInject |
| Crypto / time | MD5、Base64 decode、时间戳 |
| Session / storage | 当前插件 Cookie、事务种子、分平台加密存储 |
| WebSocket | 基本连接、收发、关闭 |
| loginChallenge | v1/v2 create/poll/cancel、二维码和验证码接口；真实登录待验证 |
| nativeStream / mediaTransform | 未实现 |
| 登录推送 / 网页 bootstrap | 未实现，能力声明 false |
| 内置脚本加载 | 返回 false，使用插件随包脚本 |

UI 接入分类、房间、搜索、详情、分享解析、取流与清晰度刷新。保留请求头、requestContext 和原始选择模型；相同临时地址的不同清晰度保持独立。

首页推荐、弹幕 UI、OAuth 设备码/Token、DRM/CENC 和特殊媒体变换尚未实现。脚本加载成功不代表其全部能力或所有内容可用。

## 排障顺序

先区分源下载/校验、脚本初始化、凭据、平台接口结果、地址有效性、播放器解码与前后台恢复。普通网络失败不能被当成无直播；增加重连不能修复接口契约变化、权限或不支持的媒体格式。诊断使用中性协议状态，不把来源专用字段写进宿主代码或测试。
