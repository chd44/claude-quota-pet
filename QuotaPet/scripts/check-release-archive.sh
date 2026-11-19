#!/usr/bin/env bash
# 检查最终要发布的压缩包（make release 打完包之后跑）：解开来查文件名和内容，不查打包前的 .app，
# 这样压缩这一步多带进去的东西（隐藏文件、扩展属性、旧文件）也查得到。用法：check-release-archive.sh <zip>
set -euo pipefail
cd "$(dirname "$0")/.."
zip=${1:?用法：check-release-archive.sh <zip>}
scan=../.githooks/privacy-scan.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"

rc=0
# 1. 文件名和内容：本机路径、真实数据、截图、真实对话日志
"$scan" dir "$work" || rc=1

# 1b. 沿用原来更严的一道：任何文件里出现「用户目录前缀」就不行（不管后面跟什么用户名）
if grep -r -a -l "/Us""ers/" "$work"; then
    echo "❌ 压缩包里有本机绝对路径（上面列出的文件）" >&2
    rc=1
fi

# 2. 只能有 QuotaPet.app 一个顶层目录，里面的宠物图只能是清单里的那几类名字
top=$(cd "$work" && ls -A)
if [[ "$top" != "QuotaPet.app" ]]; then
    echo "❌ 压缩包顶层应该只有 QuotaPet.app，实际有：$top" >&2
    rc=1
fi
extra=$(cd "$work/QuotaPet.app/Contents/Resources/Pets" 2>/dev/null && find . -type f | grep -vE '^\./[a-z]+/(portrait|icon)-[a-z-]+\.png$' || true)
if [[ -n "$extra" ]]; then
    echo "❌ 宠物图目录里有不是 portrait-/icon-<表情>.png 的文件：" >&2
    printf '%s\n' "$extra" | sed 's/^/    /' >&2
    rc=1
fi
hidden=$(cd "$work" && find . -name '.*' ! -name . | head -5)
if [[ -n "$hidden" ]]; then
    echo "❌ 压缩包里有隐藏文件：" >&2
    printf '%s\n' "$hidden" | sed 's/^/    /' >&2
    rc=1
fi

if [[ $rc -ne 0 ]]; then echo "❌ 压缩包没通过检查，不能发布" >&2; exit 1; fi
echo "✅ 压缩包检查通过（文件名、内容、宠物图清单）"
