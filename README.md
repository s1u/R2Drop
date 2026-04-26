# R2Drop 🦞

跨平台 Cloudflare R2 文件管理工具。

Mac → iPhone → Windows 三端统一体验。

## 功能

- 📤 拖拽上传（Finder 拖到 App 窗口）
- 📥 拖拽下载（从文件列表拖到桌面/文件夹）
- 📂 浏览 R2 文件列表
- 🔐 主密码加密存储凭据（不入系统钥匙串）
- 📊 实时传输进度
- 🔗 预签名分享链接（规划中）

## 构建

需要 **Xcode 15+**（macOS Sonoma 14+）。

```bash
# 克隆项目
git clone https://github.com/your-username/R2Drop.git
cd R2Drop

# 用 Xcode 打开
open Package.swift

# 或者命令行构建
swift build
swift run
```

> **注意：** 首次构建会下载 AWS SDK for Swift 及其依赖，耗时约 3-5 分钟。

## 首次使用

1. 打开 App 后会看到配置页面
2. 输入你的 Cloudflare R2 凭据：
   - Account ID（R2 仪表盘获取）
   - Bucket 名称
   - Access Key ID & Secret Access Key（R2 → 管理 API 令牌生成）
3. 设置一个主密码用于加密存储以上凭据
4. 点击「保存并连接」，完成 🎉

## 技术栈

- SwiftUI + AppKit（拖拽支持）
- AWS SDK for Swift（S3 兼容 API）
- CryptoSwift（AES-256-GCM 加密）
- 纯本地存储，不进系统钥匙串

## 文件结构

```
R2Drop/
├── Package.swift
├── Sources/
│   └── R2Drop/
│       ├── R2DropApp.swift          # App 入口
│       ├── Models/
│       │   ├── R2File.swift          # 文件模型
│       │   ├── R2Config.swift        # R2 配置
│       │   └── TransferProgress.swift # 传输进度
│       ├── Services/
│       │   ├── R2Service.swift       # R2 核心操作
│       │   ├── CryptoService.swift   # 加密/解密
│       │   └── AppState.swift        # 全局状态
│       ├── Views/
│       │   ├── ContentView.swift     # 路由
│       │   ├── MainView.swift        # 主界面
│       │   ├── Security/
│       │   │   ├── UnlockView.swift  # 解锁界面
│       │   │   └── SetupView.swift   # 首次配置
│       │   └── Settings/
│       │       └── SettingsView.swift # 设置
│       └── Utils/
│           ├── DragDropHandler.swift # 拖拽处理
│           └── FileHelper.swift      # 文件工具
└── README.md
```

## 许可

MIT
