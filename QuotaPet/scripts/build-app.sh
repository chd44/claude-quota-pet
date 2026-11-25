#!/usr/bin/env bash
# 把 SwiftPM 编译出来的可执行文件打包成 build/QuotaPet.app（ad-hoc 签名）
# UNIVERSAL=1 时 Apple 芯片和 Intel 各编一份再合成一个（make release 用）
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/QuotaPet.app

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${UNIVERSAL:-}" == 1 ]]; then
    # 命令行工具里没有 XCBuild，--arch 两个一起编不了，只能按 triple 各编一次再用 lipo 合并。
    # 下面渲染图标用本机架构的那份（BIN），不用再单独编一次本机的
    bins=()
    launcher_bins=()
    for arch in arm64 x86_64; do
        triple="$arch-apple-macosx14.0"
        # 每个架构用自己的构建目录：Swift 6.4 起不同 triple 的产物都放在同一个 .build/out/Products/Release，
        # 后编的会盖掉先编的（lipo 报「same architectures」）
        scratch=(--scratch-path ".build/universal-$arch")
        swift build -c release "${scratch[@]}" --product QuotaPet --triple "$triple"
        swift build -c release "${scratch[@]}" --product QuotaPetLauncher --triple "$triple"
        launcher_bins+=("$(swift build -c release "${scratch[@]}" --triple "$triple" --show-bin-path)/QuotaPetLauncher")
        bin="$(swift build -c release "${scratch[@]}" --triple "$triple" --show-bin-path)/QuotaPet"
        bins+=("$bin")
        if [[ "$arch" == "$(uname -m)" ]]; then BIN="$bin"; fi
    done
    lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/QuotaPet"
    lipo -create "${launcher_bins[@]}" -output "$APP/Contents/MacOS/QuotaPetLauncher"
else
    swift build -c release --product QuotaPet
    BIN="$(swift build -c release --show-bin-path)/QuotaPet"
    cp "$BIN" "$APP/Contents/MacOS/QuotaPet"
    swift build -c release --product QuotaPetLauncher
    cp "$(dirname "$BIN")/QuotaPetLauncher" "$APP/Contents/MacOS/QuotaPetLauncher"
fi
# 去掉调试符号：链接器会把编译时每个 .o 的本机绝对路径（带用户名）记在里面，发出去的包不能带
strip -S "$APP/Contents/MacOS/QuotaPet" "$APP/Contents/MacOS/QuotaPetLauncher"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/dev.quotapet.launcher.plist "$APP/Contents/Library/LaunchAgents/"
codesign --force --sign - "$APP/Contents/MacOS/QuotaPetLauncher"
cp Resources/quotapet-shell.sh "$APP/Contents/Resources/quotapet-shell.sh"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"  # 各语言的 App 名字（访达、通知里显示的）
# 精绘宠物的图（design/painted/export_painted.py 导出）：按清单一张张拷，不整个目录拷。
# 清单 = 每款形象（design/painted/<形象>.json）× 表情（PaintedArt.swift 里的 faces）× {portrait, icon}；
# 目录里多出来的东西（原图、.DS_Store、没登记的形象）不会进发布包
faces=$(sed -n 's/^ *static let faces: \[String\] = \[\(.*\)\].*/\1/p' Sources/QuotaPetCore/Pet/PaintedArt.swift | tr -d '" ' | tr ',' ' ')
[[ -n "$faces" ]] || { echo "❌ 读不出 PaintedArt.swift 里的表情清单"; exit 1; }
for config in design/painted/*.json; do
    style=$(basename "$config" .json)
    mkdir -p "$APP/Contents/Resources/Pets/$style"
    for face in $faces; do
        for kind in portrait icon; do
            src="Resources/Pets/$style/$kind-$face.png"
            [[ -f "$src" ]] || { echo "❌ 缺宠物图：$src"; exit 1; }
            cp "$src" "$APP/Contents/Resources/Pets/$style/"
        done
    done
done

# agy 专属静态头像：仅复制清单里登记的 PNG（必需的三十张 + 已补的状态图），不复制参考图或整个目录。
mkdir -p "$APP/Contents/Resources/Pets/agy"
while IFS= read -r name; do
    src="Resources/Pets/agy/$name.png"
    [[ -f "$src" ]] || { echo "❌ 缺 agy 静态图：$src"; exit 1; }
    cp "$src" "$APP/Contents/Resources/Pets/agy/"
done < <(bash scripts/agy-asset-names.sh)
# 补充的状态图：有就带上（必须是 PNG），没有不报错
while IFS= read -r name; do
    src="Resources/Pets/agy/$name.png"
    [[ -f "$src" ]] || continue
    file --brief --mime-type "$src" | grep -qx 'image/png' || { echo "❌ agy 补充图不是 PNG：$src"; exit 1; }
    cp "$src" "$APP/Contents/Resources/Pets/agy/"
done < <(bash scripts/agy-asset-names.sh --optional)

# 用经典款的宠物生成 App 图标（大图标用 Resources/AppIcon.png，它不拷进 App 包）
"$BIN" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "✅ 已生成 $APP"
