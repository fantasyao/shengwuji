# 声物记（my_first_app）— Agent 指南

Flutter 离线语音识别应用（sherpa_onnx SenseVoice 模型内置 APK，完全离线）。项目概览见 [README.md](README.md) 与 [CLAUDE.md](CLAUDE.md)（功能地图、关键文件索引）；架构权威叙述在 `docs/architecture/`，开发指南与踩坑复盘在 `docs/guides/`。本文件只放**必须每次生效的行为规则**，细节见各引用文件。

## 交流

- 始终使用**简体中文**交流（回复、commit message、注释叙述全中文）

## 任务前

1. `find docs/ -name "*.md" | sort` 浏览可用文档，按任务读相关篇（架构改动必读 docs/architecture/ 对应文件）
2. **改状态流转 / 跨页 / 生命周期逻辑前：先搜所有引用关键变量的地方，列出完整调用链后再一次性改**（教训见 docs/guides/postmortem-lazy-model-loading.md——2026-04-18 连修 5 次的复盘）
3. 探索类代码任务优先用 codebase-memory-mcp 工具，项目名 `S-CodeProject-my_first_app`（带前缀）：定义/调用链/源码片段走 search_graph / trace_path / get_code_snippet；Grep 只用于非代码（配置、Markdown、log）；**编辑前仍须 Read**
4. 大块探索/实现可委托子代理（探索→Explore，实现→general-purpose）；小而上下文重的改动主代理直做

## 代码保护（详见 .claude/rules/coding-style.md）

- **严禁删除 print/debugPrint**（本仓库刻意保留运行日志，`flutter analyze` 的 avoid_print info 属预期，不要顺手清理），除非用户明确要求
- **用户手写注释禁删改**（`git blame` 区分：`claude:` / `zcode:` 前缀 = AI 注释可精简，无前缀 = 用户手写禁动）
- AI 注释精简边界：演进史叙事/修复记录可压缩成一句 + 短 SHA 锚点；**必须保留**反直觉 why、不变量与上下游约束、魔法数字来源、`///` docstring、⚠️ 防再犯警告、「用户要求」标注
- **行为变了注释必须同步改写**；批量精简单独开 commit，不与功能混合

## 验证与提交（详见 .claude/rules/workflow.md）

- **声称完成前必须验证**：`flutter analyze`（0 error）+ `flutter test` 全过；动 Kotlin 加 `gradle compileDebugKotlin`；证据先于断言
- **验证通过后立即主动提交，不等用户提醒**；混批改动按功能分类拆提交（一个提交一件事）
- `git add` 明确列出文件路径，**禁止 `git add .` / `git add -A`**；**禁止主动 push**
- 提交信息：`zcode: <概述>——<实现要点/边界/测试结果>`，单行长信息，风格对齐 `git log` 既有提交
- 架构改动同步更新 docs/architecture/ 对应文档（含 changelog 表）

## 跨端同步陷阱

悬浮窗等 Dart/Kotlin 双侧实现存在**硬编码副本常量**（如 HANDLE_WIDTH_DP、VOICE_MEMO_OVERLAY_HEIGHT_DP），改尺寸/常量必须双侧同步并核对 docs/architecture/floating-window.md 记录的不变量（如语音胶囊 84 < 把手 88）。
