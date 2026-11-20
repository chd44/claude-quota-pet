#!/usr/bin/env bash
# 把 GPT 画好的一张 agy 状态图导入成 App 用的两张：
#   panel（面板半身像，192×192）和 menu（菜单栏头像，44×44，取画面上部中间的头部）。
# 用法：scripts/import-agy-art.sh <prism|pilot|gardener> <状态> <图片.png>
#   状态：revived resting nervous confused loading poke pout（也可以重做 energetic tired exhausted sleeping）
# 输入要求：正方形、透明背景的 PNG，构图和 design/agy-states/refs 里同款的参考图一致。
set -euo pipefail
cd "$(dirname "$0")/.."
style=${1:-}; state=${2:-}; src=${3:-}
case "$style" in
    prism) prefix='' ;;
    pilot) prefix='pilot-' ;;
    gardener) prefix='gardener-' ;;
    *) echo "用法：$0 <prism|pilot|gardener> <状态> <图片.png>" >&2; exit 2 ;;
esac
allowed=" revived resting nervous confused loading poke pout energetic tired exhausted sleeping "
[[ "$allowed" == *" $state "* ]] || { echo "❌ 不认识的状态：$state（可用：$allowed）" >&2; exit 2; }
[[ -f "$src" ]] || { echo "❌ 找不到图片：$src" >&2; exit 2; }
file --brief --mime-type "$src" | grep -qx 'image/png' || { echo "❌ 需要 PNG：$src" >&2; exit 2; }
w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}')
h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')
alpha=$(sips -g hasAlpha "$src" | awk '/hasAlpha/ {print $2}')
[[ "$w" == "$h" ]] || { echo "❌ 需要正方形图片，现在是 ${w}×${h}" >&2; exit 2; }
(( w >= 512 )) || { echo "❌ 图片太小（${w}px），至少 512px" >&2; exit 2; }
[[ "$alpha" == "yes" ]] || echo "⚠️ 图片没有透明通道：面板里会带着底色，最好让 GPT 输出透明背景" >&2

dest="Resources/Pets/agy"
panel="$dest/${prefix}panel-$state.png"
menu="$dest/${prefix}menu-$state.png"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sips -s format png -z 192 192 "$src" --out "$panel" >/dev/null
# 菜单栏头像：和现有图一样，取上部居中、边长约 68% 的正方形（头部和脸）
side=$(( w * 68 / 100 )); left=$(( w * 16 / 100 ))
sips -s format png -c "$side" "$side" --cropOffset 0 "$left" "$src" --out "$tmp/head.png" >/dev/null
sips -s format png -z 44 44 "$tmp/head.png" --out "$menu" >/dev/null
echo "✅ $panel"
echo "✅ $menu"
echo "重新打包（make app / make install）后生效；缺的状态 App 会退回这款的基础图。"
