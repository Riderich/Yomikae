# Yomikae 译读

> 为中文读者做的 E-Hentai / ExHentai 阅读器：找本子、追作者和汉化组，日文漫画在手机上直接翻译成中文读。

[![Release](https://img.shields.io/github/v/release/Riderich/Yomikae)](https://github.com/Riderich/Yomikae/releases/latest)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue)](LICENSE)

[下载](https://github.com/Riderich/Yomikae/releases/latest) · [报告问题](https://github.com/Riderich/Yomikae/issues/new/choose) · [更新记录](https://github.com/Riderich/Yomikae/releases)

Yomikae（読み替え，“换一种方式来读”）由 [JHenTai](https://github.com/jiangtian616/JHenTai) 衍生而来，是独立维护的社区项目，**不是 JHenTai 官方版本**，也未获得原作者背书。本项目特有的问题请在本仓库反馈，不要提交给 JHenTai。

## 主要功能

### 找本子

- **发现**：排行榜、热门、最新一页看完，分类、语言、评分在筛选里
- **找本子**：十个分类一键直达；**标签浏览**按作者、社团、原作、角色、女性、男性等类型列出全部标签，显示中文名，按全站使用次数排序，可筛选
- **相似作品**：从任意作品出发，找同名的其他版本、同作者、同社团、同上传者，或“内容最相似”（自动选这本最有特点的标签组合搜索）

### 追作者、汉化组

- **关注**：上传者（汉化组的号）、作者、社团、任意标签都能点星标关注
- 打开关注页时检查新作，有新作的显示数字，底部图标也有红点；点进去即标记为已看
- 只在你打开时检查，不在后台运行

### 了解自己的口味

- **书架 → 口味**：统计全部收藏里最常出现的作者、社团、上传者、原作、角色和标签
- 内容标签按“在你收藏里常见、在全站不常见”排序，突出真正的偏好
- 每一项都能直接搜索或关注；统计结果缓存在本地，之后只补新收藏

### 漫画翻译

- **安卓：本机识别**。文字检测和日文识别（PP-OCRv6，约 31 MB 模型）在手机上完成，只有识别出的文字发给你配置的大模型 API（DeepSeek 等 OpenAI 兼容接口），译文擦字嵌回原图，支持竖排
- **Windows：本地翻译服务**。软件内一键初始化 Python 环境，使用 manga-image-translator 流程，可选自定义 API 或 NLLB 本地模型
- 阅读页长按图片即可翻译本页；翻译完成会显示各阶段耗时

## 下载与安装

从 [Releases](https://github.com/Riderich/Yomikae/releases/latest) 下载：

| 平台 | 文件 | 说明 |
|---|---|---|
| 安卓（绝大多数手机） | `app-arm64-v8a-release.apk` | 包名 `com.riderich.yomikae` |
| 安卓（老旧 32 位设备） | `app-armeabi-v7a-release.apk` | |
| Windows x64 | 压缩包 | 解压后运行，翻译需先在设置里初始化环境 |

Yomikae 与 JHenTai、旧的“JHenTai 翻译版”是不同的应用，可以同时安装，设置不会自动迁移。

## 安卓翻译怎么用

1. **设置 → 漫画翻译**，选择“手机本机识别”，点击“下载模型”（约 31 MB，可选 Hugging Face 或国内镜像）
2. 填写大模型 API 地址、Key 和模型名（默认预设为 DeepSeek），点“测试连接”
3. 在阅读页长按图片，选择“翻译本页”

只有识别出的文字会发送给你配置的 API 服务商，图片不会离开手机。

## Windows 翻译怎么用

1. 完整解压后运行 `app/jhentai.exe`，打开 **设置 → 漫画翻译 → 初始化翻译环境**
2. 初始化会自动准备独立 Python 环境、依赖和默认模型，预计下载 4–7 GB，建议预留 12 GB 空间；检测到 NVIDIA 显卡时可选 CUDA 加速
3. 选择自定义 API 或 NLLB 本地翻译，保存并测试连接
4. 阅读界面右键图片即可翻译当前页、重新翻译或切换原图/译图；也可以指定页码范围串行翻译

翻译服务只监听本机 `127.0.0.1`，请勿暴露到公网，也不要把 API Key 写进源码、日志或 Issue。

## 旧版界面

新界面（底部 发现 / 找本子 / 关注 / 书架）默认开启。想用原来的侧边栏导航：**设置 → 样式 → 关闭“新版导航”**。平板和电脑布局保持原样。

## 构建

```powershell
flutter pub get
flutter build apk --release --split-per-abi -t lib/src/main.dart
flutter build windows --release -t lib/src/main.dart
```

Windows 翻译适配层在 `translation_service/`，对 manga-image-translator 的兼容改动以补丁形式保存在 `translation_service/manga-image-translator.patch`。贡献前请阅读 [贡献指南](CONTRIBUTING.md)；安全问题请按 [安全说明](SECURITY.md) 私下报告。

## 来源与致谢

- [JHenTai](https://github.com/jiangtian616/JHenTai)（jiangtian616，Apache-2.0）：本项目的代码基础，包括 E-Hentai 访问、下载、阅读器等绝大部分功能
- [PaddleOCR / PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR)（Apache-2.0）与 [fumetodev 的漫画识别模型](https://huggingface.co/fumetodev/PP-OCRv6_small_rec_manga_ONNX)：安卓本机文字检测与识别
- [ONNX Runtime](https://onnxruntime.ai/)：安卓端模型推理
- [manga-image-translator](https://github.com/zyddnys/manga-image-translator)：Windows 端翻译流程
- [EhTagTranslation](https://github.com/EhTagTranslation/Database)：标签中文翻译；[e-hentai-tag-count](https://github.com/mokurin000/e-hentai-tag-count)：标签使用次数

详细的来源与修改说明见 [NOTICE](NOTICE)。

## 许可证

[Apache License 2.0](LICENSE)。模型、数据库、字体和第三方服务分别适用各自的许可证与使用条款。
