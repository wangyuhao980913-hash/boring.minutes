# 会议纪要 (Meeting Minutes)

基于 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 开源项目二次开发的 macOS 会议录音与智能纪要工具。

利用 MacBook 刘海区域，提供一键录音、实时语音转写、AI 智能总结等功能，让会议记录不再繁琐。

## 新增功能

- **一键会议录音**：系统音频 + 麦克风双路采集，自适应增益混音
- **实时语音转写**：接入豆包流式 ASR，录制过程中即时出字幕
- **AI 智能总结**：录制结束后自动生成会议摘要、待办事项、智能章节
- **云端同步**：基于火山引擎 TOS 对象存储，多设备间同步会议记录
- **会议回放**：歌词式转录对照播放，点击跳转到对应时间点

## 系统要求

- macOS 14 Sonoma 或更高版本
- Apple Silicon 或 Intel Mac

## 构建

1. 克隆仓库：
   ```bash
   git clone https://github.com/yuhao-wang-git/boring.minutes.git
   cd boring.minutes
   ```

2. 用 Xcode 打开项目：
   ```bash
   open boringMinutes.xcodeproj
   ```

3. 点击 Run (Cmd+R) 即可运行。

## 配置

首次使用需在设置中配置火山引擎相关凭证。详细的注册、开通、配置步骤请参阅：

**👉 [火山引擎接入与使用指南](docs/会议纪要-火山引擎接入与使用指南.md)**

简要来说，需要配置两套凭证：

- **火山引擎 TOS（对象存储）**：Access Key / Secret Key / Bucket / Region
- **豆包语音妙记（转写+总结）**：App ID / Access Token

## 致谢

本项目基于 [boring.notch](https://github.com/TheBoredTeam/boring.notch) 开源项目开发，感谢 TheBoredTeam 团队的优秀工作。原项目提供了刘海交互框架、音乐控制、日历集成、文件架等基础功能。

## License

沿用原项目 License。
