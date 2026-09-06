# Codebase Memory MCP 命令速查（本地文档，不进版本控制）

> cbm 项目名：`S-CodeProject-my_first_app`（由仓库路径 `s:\CodeProject\my_first_app` 自动生成，**不是** `my_first_app`）
>
> 所有工具均为 MCP 工具，在 Claude Code 会话中直接调用，不是 shell 命令。

## 1. 索引管理

| 操作 | 调用 |
|---|---|
| 全量重建索引 | `index_repository(repo_path="s:/CodeProject/my_first_app", mode="full")` |
| 增量/快速重建 | `index_repository(repo_path="...", mode="moderate")` 或 `mode="fast"`（fast 无相似度/语义边） |
| 生成可分享产物 | `index_repository(..., persistence=true)` → 写入 `.codebase-memory/graph.db.zst` |
| 查索引状态 | `index_status(project="S-CodeProject-my_first_app")` |
| 列出已索引项目 | `list_projects()` |
| 删除索引 | `delete_project(project="S-CodeProject-my_first_app")` |
| 跨仓库关联 | `index_repository(..., mode="cross-repo-intelligence", target_projects=["*"])`（需目标项目已有新鲜索引） |

## 2. 代码探索（日常最常用）

| 场景 | 调用 |
|---|---|
| 按名字找函数/类/路由 | `search_graph(project="...", name_pattern=".*Regex.*")` |
| 自然语言搜索 | `search_graph(project="...", query="更新设置")` |
| 语义搜索（跨词汇） | `search_graph(project="...", semantic_query=["send","publish"])`（需 moderate/full 索引） |
| 看调用链/谁调了谁 | `trace_path(project="...", function_name="Xxx.yyy", mode="calls", direction="both", depth=3)` |
| 数据流追踪 | `trace_path(project="...", function_name="Xxx.yyy", mode="data_flow")` |
| 跨服务追踪 | `trace_path(project="...", function_name="Xxx.yyy", mode="cross_service")` |
| 取精确源码 | `get_code_snippet(project="...", qualified_name="完整限定名")`（先用 search_graph 拿到 qualified_name） |
| 架构概览（含社区聚类） | `get_architecture(project="...", aspects=["all"])` |
| 图增强文本搜索 | `search_code(project="...", pattern="关键字", regex=false)` |
| git diff 影响范围 | `detect_changes(project="...", base_branch="main")` |
| 复杂多跳查询 | `query_graph(project="...", query="MATCH ... RETURN ...")`（Cypher） |
| 看图 schema | `get_graph_schema(project="...")` |
| 运行时轨迹增强 | `ingest_traces(project="...", traces=[...])` |

## 3. ADR（架构决策记录）

| 操作 | 调用 |
|---|---|
| 读 | `manage_adr(project="...", mode="get")` |
| 读指定章节 | `manage_adr(project="...", mode="sections", sections=["..."])` |
| 写/更新 | `manage_adr(project="...", mode="update", content="...")` |

## 4. 常用提示

- **分页**：`search_graph` 响应有 `total` 和 `has_more`，截断时用 `offset += limit` 翻页；`search_code` 无 offset，用 `limit` 加大或 `path_filter` 收窄
- **热点性能查询**（Cypher 示例）：
  ```cypher
  MATCH (f:Function)
  WHERE f.transitive_loop_depth >= 3 OR f.linear_scan_in_loop >= 1
  RETURN f.qualified_name, f.transitive_loop_depth, f.linear_scan_in_loop
  ORDER BY f.transitive_loop_depth DESC
  ```
- **默认排除目录**：`.claude .dart_tool .git .idea .vscode .waylog build logs 同步盘 ios/Flutter ios/Runner android/.gradle android/build`
- **何时重建索引**：改了代码想让 cbm 看到最新结构时，重跑 `index_repository`（mode=moderate 够日常使用）
- **规则**：探索任务先 cbm，编辑前才用 Read；搜配置/Markdown 等非代码内容用 Grep
