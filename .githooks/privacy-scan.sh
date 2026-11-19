#!/bin/bash
# 隐私规则（仓库是公开的，Release 谁都能下载）：真实额度数据、截图、本机路径、真实对话日志都不能进 git，也不能进发布包。
# 提交钩子（pre-commit）、CI 和 make release 共用这一份规则，用法：
#   privacy-scan.sh names        从标准输入读文件名（一行一个），打印不该出现的
#   privacy-scan.sh text         从标准输入读文本（新增的行、文件内容），打印不该出现的行
#   privacy-scan.sh dir <目录>    文件名和内容都查（发布包解压出来的目录）
# 有问题时打印出来并返回 1。规则里用到的敏感字样都拆开写，免得这个脚本自己被自己的规则查到。

# 按字节处理，不按字符：发布包里的可执行文件有不合法的 UTF-8，在 UTF-8 环境下 grep/cut/sed 可能中途报错，把有问题的文件漏过去
export LC_ALL=C

# 可能是真实数据或截图的文件名（不分大小写：data.JSONL、intervals.jsonl.bak、CleanShot、screenshot 都算）
name_re='\.jsonl($|\.)|(^|/)popover-live[^/]*\.png$|(^|/)(snapshots|intervals|plan-usage-history|cli-readings)[^/]*$|(^|/)cli-probe(/|$)|screenshot|screen shot|cleanshot|截屏|屏幕快照'
# 真实的 Claude Code 对话日志里才有的字段（合成的测试数据不带）
real_re='"(session''Id|parent''Uuid|git''Branch)"[[:space:]]*:'
# 本机绝对路径：任何用户名（至少两个字符），自检里用的假路径 someone 放行；包括 JSON 里转义成 \/Users\/… 的
path_re='(/Users/|\\/Users\\/)[A-Za-z0-9._-]{2,}'
path_ok='(/Users/|\\/Users\\/)someone'

scan_names() {
  grep -iE "$name_re"
}

# 查一个文件的内容（grep -a：二进制也按文本查，发布包里的可执行文件、图片里也不能有本机路径）。有问题时打印、返回 1
scan_file() {
  local file=$1 rc=0 user_dir="/Users/$(id -un)" hits real
  local -a own=(-e "$user_dir" -e "$(printf '%s' "$user_dir" | sed 's#/#\\/#g')")
  # HOME 为空或只有一个斜杠时不能拿来当匹配串（会匹配到所有内容）
  if [ "${#HOME}" -gt 1 ]; then own+=(-e "$HOME" -e "$(printf '%s' "$HOME" | sed 's#/#\\/#g')"); fi
  # 有没有问题只看 grep 本身的结果；截断（head、cut）只用在打印上，不影响判断
  hits=$({ grep -aE "$path_re" "$file" | grep -avE "$path_ok"
           grep -aF "${own[@]}" "$file"; } || true)
  real=$(grep -aE "$real_re" "$file" || true)
  if [ -n "$hits" ]; then
    echo "✗ 有本机路径（换成 ~ 或删掉）：" >&2
    printf '%s\n' "$hits" | head -5 | cut -c1-160 | sed 's/^/    /' >&2
    rc=1
  fi
  if [ -n "$real" ]; then
    echo "✗ 看起来是真实的 Claude Code 对话日志（带会话字段），不能提交或发布：" >&2
    printf '%s\n' "$real" | head -3 | cut -c1-120 | sed 's/^/    /' >&2
    rc=1
  fi
  return $rc
}

case "${1:-}" in
  names)
    bad=$(scan_names)
    if [ -n "$bad" ]; then
      echo "✗ 这些文件可能是真实数据或截图，不能提交或发布：" >&2
      printf '%s\n' "$bad" | sed 's/^/    /' >&2
      exit 1
    fi
    ;;
  text)
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    cat >"$tmp"
    scan_file "$tmp"
    ;;
  dir)
    dir=${2:?用法：privacy-scan.sh dir <目录>}
    rc=0
    err=$(mktemp)
    trap 'rm -f "$err"' EXIT
    bad=$(cd "$dir" && find . \( -type f -o -type l \) | sed 's#^\./##' | scan_names)
    if [ -n "$bad" ]; then
      echo "✗ 这些文件可能是真实数据或截图，不能发布：" >&2
      printf '%s\n' "$bad" | sed 's/^/    /' >&2
      rc=1
    fi
    while IFS= read -r -d '' f; do
      scan_file "$f" 2>"$err" || { echo "✗ 文件内容有问题：${f#"$dir"/}" >&2; cat "$err" >&2; rc=1; }
    done < <(find "$dir" -type f -print0)
    exit $rc
    ;;
  *)
    echo "用法：privacy-scan.sh names|text|dir <目录>" >&2
    exit 2
    ;;
esac
