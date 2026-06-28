# NovelHub

一个 Flutter 的 LLM 小说写作 Agent 应用（Android + Windows）。

## 运行

需要 Flutter SDK（≥3.3）。由于本机未安装 SDK，先安装并执行：

```bash
flutter create --platforms android,windows --org com.novelhub .
flutter pub get
flutter run -d windows      # 或 -d <android-device-id>
flutter test                # 运行单测（段落工具 / 时间线 / agent loop）
```

> 注意：`flutter create .` 会在当前目录补齐平台工程（android/、windows/、test driver 等），
> 不会覆盖 lib/ 与 pubspec.yaml。

## 架构

- **domain/** 纯模型：`entities`（Novel/Chapter/Paragraph/Setting/TextRequirement）、
  `conversation`（Message/ToolCall/Conversation）、`paragraph_doc`（段落 range 操作 + 逆操作）、
  `timeline`（事件溯源 revertTo）。
- **data/llm/** LLM 抽象：`LlmClient` 接口 + 三 provider
  （OpenAI 兼容 / OpenAI 流式 / DeepSeek 前缀续写 beta），`streaming_retry`（自动 + 手动续写），
  SSE 解析。`provider_factory` 按 `ProviderConfig.type` 构建 client。
- **agent/** `tool_registry`（function-calling schema + dispatch）、`tool_specs`、
  `system_prompt`（默认拼接设定 + 当前章节全文带段落号）、`agent_loop`。
- **state/** Riverpod：`providers`（小说/章节/provider 配置/激活）、`editor_state`
  （文档 + 时间线 + 会话 + 模式 + agent 编排）。
- **data/repositories/** `JsonAppRepository`：JSON 文件持久化（无需 codegen，
  跨平台、可手动备份）。可后续替换为 Isar。

## 关键设计

- **段落工具**：1-based 闭区间，`edit_range(12,13,"xxx\nyyy")` 把第 12、13 段
  替换为 "xxx"、"yyy" 两段。每次变更记录逆操作，供时间线回滚。
- **时间线回滚**：`revertTo(messageId)` 自后向前应用逆操作，回到某条消息时的
  文档状态；重发/回到某条消息会同步撤销后续文本改动。
- **清空上下文**：仅清会话消息，保留已落盘文本。
- **前缀续写**：DeepSeek `/beta` + `prefix:true` 真续写；可配 `cotPrefix` 限制 CoT 前几字
  （`reasoning_content` 续写）。流式中断自动重试 N 次，失败后 UI 提供手动重试。
