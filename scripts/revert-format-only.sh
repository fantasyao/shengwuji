#!/usr/bin/env bash
# 误跑了目录级 `dart format` 之后的回收脚本。
#
# 判定方式：取 HEAD 里的内容用当前 formatter 格式化一遍，再与工作区文件比对——
#   一致        → 这个文件只有格式化变化，回滚到 HEAD（无信息损失）
#   不一致      → 文件里有真实改动，一律不动，交给人看
# 只看已跟踪的修改（M），未跟踪的新文件不碰。
#
# 用法：
#   bash scripts/revert-format-only.sh           # 只预览会回滚哪些文件
#   bash scripts/revert-format-only.sh --apply   # 真正回滚
set -uo pipefail

apply=0
case "${1:-}" in
  --apply) apply=1 ;;
  "") ;;
  *)
    echo "未知参数: $1（只支持 --apply）" >&2
    exit 2
    ;;
esac

root="$(git rev-parse --show-toplevel)"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 有暂存改动的文件跳过：回滚会连 index 一起覆盖，宁可让人手工确认
staged="$(git diff --cached --name-only -- '*.dart')"
format_only=()
real_changed=()
skipped=()
unreadable=()

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue

  if printf '%s\n' "$staged" | grep -Fqx -- "$f"; then
    skipped+=("$f")
    continue
  fi

  if ! git show "HEAD:$f" > "$tmp/head.dart" 2>/dev/null; then
    unreadable+=("$f")
    continue
  fi

  # stdin 模式输出到 stdout；--stdin-name 让 formatter 知道文件路径与语言版本
  if ! dart format --stdin-name="$f" < "$tmp/head.dart" > "$tmp/fmt.dart" 2>/dev/null; then
    unreadable+=("$f")
    continue
  fi

  if diff -q --strip-trailing-cr "$tmp/fmt.dart" "$f" > /dev/null 2>&1; then
    format_only+=("$f")
  else
    real_changed+=("$f")
  fi
done < <(git diff --name-only --diff-filter=M HEAD -- '*.dart')

echo "只有格式化变化（将被回滚）: ${#format_only[@]} 个"
if [ "${#format_only[@]}" -gt 0 ]; then
  printf '  %s\n' "${format_only[@]}"
fi

echo "有真实改动（保持不动）: ${#real_changed[@]} 个"
if [ "${#real_changed[@]}" -gt 0 ]; then
  printf '  %s\n' "${real_changed[@]}"
fi

if [ "${#skipped[@]}" -gt 0 ]; then
  echo "跳过（有暂存改动，请手工确认）: ${#skipped[@]} 个"
  printf '  %s\n' "${skipped[@]}"
fi

if [ "${#unreadable[@]}" -gt 0 ]; then
  echo "跳过（读不到 HEAD 版本或格式化失败）: ${#unreadable[@]} 个"
  printf '  %s\n' "${unreadable[@]}"
fi

if [ "$apply" -eq 0 ]; then
  echo
  echo "预览模式，未改动任何文件。确认无误后执行：bash scripts/revert-format-only.sh --apply"
  exit 0
fi

if [ "${#format_only[@]}" -gt 0 ]; then
  git checkout HEAD -- "${format_only[@]}"
fi
echo
echo "已回滚 ${#format_only[@]} 个纯格式化文件；有真实改动的 ${#real_changed[@]} 个文件未动。"
