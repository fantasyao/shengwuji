# Git 工作流规范

## 提交规范

### Claude 发起的提交

每完成一个功能点的修复或实现，**必须**执行：

1. 暂存所有更改：`git add 对应的修改文件`
2. 创建提交：`git commit -m "claude: [简短描述任务内容]"`

### 提交信息格式

- **前缀**: `claude:`
- **描述**: 简洁明确的任务描述
- **示例**:
  - `claude: 添加语音录制功能`
  - `claude: 修复日记列表刷新问题`
  - `claude: 优化异步加载状态管理`

### 禁止行为

- ❌ 除非用户明确要求，否则**不要执行** `git push`
- ❌ 不要使用破坏性的 git 命令（如 `--force`），除非用户明确指示

### 安全命令

以下命令需要用户明确批准：

- `git reset --hard`
- `git clean -f`
- `git rebase`
- 任何带 `--force` 的命令

## 分支策略

### 主分支

- **main**: 主开发分支
- 大多数工作应在 main 分支进行

### 功能分支（如使用）

- 创建：`git checkout -b feature/功能名称`
- 合并：首选 merge over rebase（保留历史）

## 提交前检查

### 代码质量

提交前应确保：

1. 代码通过 `flutter analyze`
2. 代码符合 `dart format` 标准
3. 相关测试通过
4. 没有 TODO 或 FIXME 注释遗留（除非是有意的）

### 提交内容

- 避免将敏感文件（如 `.env`）纳入版本控制
- 检查 `git status` 确认要提交的文件
- 不要提交构建产物（`build/`, `.dart_tool/`）

## 与 Git Hook 集成

项目配置了提交前钩子（见 @/.claude/hooks/pre-commit-check.ps1）：

- 自动运行 `flutter analyze`
- 自动运行 `dart format`
- 如果检查失败，阻止提交

## 常用命令

### 查看状态

```bash
git status
git log --oneline -10
```

### 撤销更改

```bash
# 撤销工作区更改
git restore <file>

# 撤销暂存区更改
git restore --staged <file>

# 撤销最后一次提交（保留更改）
git reset --soft HEAD~1
```

### 查看差异

```bash
git diff              # 工作区 vs 暂存区
git diff --staged     # 暂存区 vs 最后提交
git diff HEAD~1       # 最后两次提交的差异
```
