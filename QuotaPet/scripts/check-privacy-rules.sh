#!/usr/bin/env bash
# 隐私规则的回归测试：全部用合成的文件，不碰真实数据、不联网。
# 坏的要拦住（文件名、内容、压缩包里的东西、提交钩子），合法的 fixtures 不能被误伤。
# 用法：QuotaPet/scripts/check-privacy-rules.sh（CI 和本机都能跑）
set -uo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
scan="$here/.githooks/privacy-scan.sh"
fixture="$here/QuotaPet/fixtures/transcript-ids.txt"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failed=0 passed=0
ok()   { passed=$((passed + 1)); }
bad()  { failed=$((failed + 1)); echo "✗ $1"; }
# expect_block <说明> <命令…>：命令必须失败（被拦住）；expect_pass：必须成功
expect_block() { local what=$1; shift; if "$@" >/dev/null 2>&1; then bad "$what：应该被拦住，却放行了"; else ok; fi; }
expect_pass()  { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$what：不该被拦，却拦住了"; fi; }

# 敏感字样都在运行时拼出来，免得这个脚本自己被规则查到
users="/Us""ers"
other_path="$users/zhangsan/Desktop/x"
escaped_path="\\/Us""ers\\/zhangsan\\/x"
real_line='{"parent''Uuid":"a","session''Id":"b","type":"user"}'

names() { printf '%s\n' "$@" | "$scan" names; }
text()  { printf '%s\n' "$1" | "$scan" text; }

# --- 文件名 ---
for n in "data.jsonl" "x/DATA.JSONL" "intervals.jsonl.bak" "docs/popover-live-dark.png" "Screenshot 2026-11-20.png" "snapshots-1.txt" "cli-readings.jsonl" "a/cli-probe/out.txt" "CleanShot 1.png" "屏幕快照 1.png"; do
    expect_block "文件名 $n" names "$n"
done
for n in "QuotaPet/fixtures/transcript-ids.txt" "docs/images/popover.png" "QuotaPet/Sources/QuotaPet/CLIProbe.swift" \
         "QuotaPet/Sources/QuotaPetCore/Claude/UsageIntervals.swift" "QuotaPet/Resources/Pets/classic/portrait-sleep.png"; do
    expect_pass "合法文件名 $n" names "$n"
done

# --- 内容 ---
expect_block "本机路径" text "path = $other_path"
expect_block "JSON 里转义的本机路径" text "{\"p\":\"$escaped_path\"}"
expect_pass "假路径 someone 放行" text "path = $users/someone/x"
expect_block "HOME" text "cwd = $HOME/work"
expect_block "真实对话日志（带会话字段）" text "$real_line"
expect_pass "合法 fixtures 的内容（合成的对话日志）" "$scan" text <"$fixture"
expect_pass "普通文字" text "你好，用 ~/Library 就行"

# --- 目录（发布包解压出来的样子） ---
app="$work/good/QuotaPet.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources/Pets/classic"
printf 'binary-ish\0data' >"$app/MacOS/QuotaPet"
printf 'png' >"$app/Resources/Pets/classic/portrait-sleep.png"
expect_pass "干净的 .app" "$scan" dir "$work/good"
cp -R "$work/good" "$work/bad1" && printf 'x\0%s\0y' "$other_path" >"$work/bad1/QuotaPet.app/Contents/MacOS/QuotaPet"
expect_block "可执行文件（二进制）里的本机路径" "$scan" dir "$work/bad1"
# 真的二进制：不合法的 UTF-8 字节夹着路径（Mach-O 里就是这样），在 UTF-8 环境下也要拦住
cp -R "$work/good" "$work/bad1b" && printf '\xff\xfe\x80\xc3%s\xff\xfe' "$other_path" >"$work/bad1b/QuotaPet.app/Contents/MacOS/QuotaPet"
expect_block "非 UTF-8 的二进制里的本机路径（UTF-8 环境）" env LC_ALL=en_US.UTF-8 "$scan" dir "$work/bad1b"
expect_block "非 UTF-8 的二进制里的本机路径（text 模式）" bash -c 'printf "\xff\xfe\x80%s\xff\n" "$1" | LC_ALL=en_US.UTF-8 "$2" text' _ "$other_path" "$scan"
cp -R "$work/good" "$work/bad2" && printf '{}' >"$work/bad2/QuotaPet.app/Contents/Resources/Pets/classic/notes.jsonl"
expect_block "包里的 .jsonl" "$scan" dir "$work/bad2"
cp -R "$work/good" "$work/bad3" && printf 'a' >"$work/bad3/QuotaPet.app/Contents/Resources/popover-live.png"
expect_block "包里的 popover-live 截图" "$scan" dir "$work/bad3"
cp -R "$work/good" "$work/bad4" && printf '%s\n' "$real_line" >"$work/bad4/QuotaPet.app/Contents/Resources/readme.txt"
expect_block "包里改了后缀的真实日志" "$scan" dir "$work/bad4"

# --- 最终的压缩包（需要 ditto，只在 macOS 上测） ---
if command -v ditto >/dev/null; then
    release="$here/QuotaPet/scripts/check-release-archive.sh"
    pack() { (cd "$1" && ditto -c -k --norsrc --noextattr --keepParent QuotaPet.app "$2"); }
    pack "$work/good" "$work/good.zip"
    expect_pass "干净的压缩包" "$release" "$work/good.zip"
    pack "$work/bad1b" "$work/bad1b.zip"
    expect_block "压缩包里非 UTF-8 二进制里的本机路径" env LC_ALL=en_US.UTF-8 "$release" "$work/bad1b.zip"
    pack "$work/bad1" "$work/bad1.zip"
    expect_block "压缩包里的本机路径" "$release" "$work/bad1.zip"
    pack "$work/bad2" "$work/bad2.zip"
    expect_block "压缩包里的 .jsonl" "$release" "$work/bad2.zip"
    cp -R "$work/good" "$work/bad5" && printf 'x' >"$work/bad5/QuotaPet.app/Contents/Resources/Pets/classic/original-art.png"
    pack "$work/bad5" "$work/bad5.zip"
    expect_block "宠物图目录里不在清单格式里的文件" "$release" "$work/bad5.zip"
    cp -R "$work/good" "$work/bad6" && printf 'x' >"$work/bad6/QuotaPet.app/.DS_Store"
    pack "$work/bad6" "$work/bad6.zip"
    expect_block "压缩包里的隐藏文件" "$release" "$work/bad6.zip"
fi

# --- 提交钩子（临时仓库，合成文件） ---
repo="$work/repo"
git init -q "$repo"
mkdir -p "$repo/.githooks" "$repo/QuotaPet/fixtures"
cp "$here/.githooks/pre-commit" "$here/.githooks/privacy-scan.sh" "$repo/.githooks/"
git -C "$repo" config user.email "1+x@users.noreply.github.com"
git -C "$repo" config user.name x
hook() { (cd "$repo" && .githooks/pre-commit); }
cp "$fixture" "$repo/QuotaPet/fixtures/transcript-ids.txt"
git -C "$repo" add QuotaPet/fixtures/transcript-ids.txt
expect_pass "钩子：合法 fixtures 可以提交" hook
git -C "$repo" reset -q
printf '%s\n' "$real_line" >"$repo/notes.txt"
git -C "$repo" add notes.txt
expect_block "钩子：改了后缀的真实日志" hook
git -C "$repo" reset -q
printf 'see %s\n' "$other_path" >"$repo/notes2.txt"
git -C "$repo" add notes2.txt
expect_block "钩子：新增内容里的本机路径" hook
git -C "$repo" reset -q
printf 'a' >"$repo/Screenshot 1.png"
git -C "$repo" add "Screenshot 1.png"
expect_block "钩子：截图文件名" hook

echo "隐私规则自测：通过 $passed 项，失败 $failed 项"
[[ $failed -eq 0 ]]
