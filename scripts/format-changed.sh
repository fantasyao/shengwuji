#!/usr/bin/env bash
# 只格式化「本次改动过」的 .dart 文件。
#
# 为什么不能直接 `dart format lib`：2026-09-07 已做过一次全仓 tall style 迁移
# （58c0997），formatter 输出至今稳定；但之后的改动常被手写成旧风格又从不格式化，
# 存量漂移会越积越多，一次目录级 format 就会一次性爆出上百文件的无关 diff
# （2026-10-27 误跑 `dart format lib`，115/223 文件被重排）。
#
# 用法：
#   bash scripts/format-changed.sh          # 与 HEAD 对比：已改（含暂存）+ 未跟踪的 .dart
#   bash scripts/format-changed.sh main     # 与指定分支/提交对比
set -euo pipefail

base="${1:-HEAD}"
root="$(git rev-parse --show-toplevel)"
cd "$root"

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(
  {
    # ACMR：新增/复制/修改/重命名后的新路径（删除的文件不参与格式化）
    git diff --name-only --diff-filter=ACMR "$base" -- '*.dart'
    git ls-files --others --exclude-standard -- '*.dart'
  } | sort -u
)

if [ "${#files[@]}" -eq 0 ]; then
  echo "没有需要格式化的 .dart 改动（基准: $base）"
  exit 0
fi

echo "基准 $base，格式化 ${#files[@]} 个文件："
printf '  %s\n' "${files[@]}"
dart format "${files[@]}"
