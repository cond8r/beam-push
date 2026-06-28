# Beam Push

跨设备即时传输工具，支持文字和文件在手机（iOS/Android）与电脑（Chrome 浏览器）之间互相推送。

## 功能

- **文字推送**：发送文字到其他设备，自动复制到剪贴板
- **文件传输**：
  - < 50 MB：直接通过自建服务器传输
  - ≥ 50 MB：自动上传到 GoFile 临时存储，发送下载链接
- **实时接收**：SSE 长连接，秒级到达
- **多平台**：iOS App、Android App、Chrome 扩展程序

## 项目结构

```
beam/
├── server/          # Python FastAPI 后端服务器
├── flutter_app/     # Android / 跨平台客户端（Flutter）
├── ios/             # iOS 原生客户端（Swift/SwiftUI）
├── chrome-extension/# Chrome 浏览器扩展程序
└── mac/             # macOS 客户端（可选）
```

## 部署

### 1. 服务器

需要一台有公网 IP 的 VPS，安装 Python 3.10+。

```bash
cd server
pip install -r requirements.txt
export BEAM_AUTH_TOKEN=your_token_here
uvicorn server:app --host 0.0.0.0 --port 8899
```

### 2. 客户端配置

每个客户端都有一个示例配置文件，复制后填入你的服务器地址和 auth token：

| 平台 | 示例文件 | 复制到 |
|------|---------|--------|
| Android/Flutter | `flutter_app/lib/services/config.dart.example` | `flutter_app/lib/services/config.dart` |
| iOS | `ios/Beam/Beam/Constants.swift.example` | `ios/Beam/Beam/Constants.swift` |
| Chrome | `chrome-extension/config.js.example` | `chrome-extension/config.js` |

### 3. 构建

**Android APK：**
```bash
cd flutter_app
flutter build apk --release
```

**Chrome 扩展：**
直接在 `chrome://extensions/` 加载 `chrome-extension/` 目录（开发者模式），或打包为 zip 分发。

**iOS：**
用 Xcode 打开 `ios/Beam/Beam.xcodeproj`，Archive 后上传到 TestFlight。

## 大文件传输说明

大于 50MB 的文件会自动上传到 [GoFile](https://gofile.io)（免费临时存储），接收端点击链接在浏览器中下载。GoFile 文件有有效期，仅适合临时传输。

## 依赖的第三方服务

| 服务 | 用途 | 备注 |
|------|------|------|
| 自建 VPS | 消息中转、小文件传输 | 核心服务，挂则全断 |
| GoFile | 大文件（≥50MB）临时存储 | 免费，文件有期限 |
