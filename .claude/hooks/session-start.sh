#!/bin/bash
# 云端会话（claude.ai/code）启动时跑一次；本机直接退出，什么都不改。
# 1. 提交身份换成 GitHub noreply 地址：云端默认是 noreply@anthropic.com，会被隐私检查和 CI 拦下
# 2. 有了 noreply 身份才启用 .githooks 的提交前隐私检查（新 clone 默认没开），不然每次提交都会被拦
# 3. 宠物设计脚本（design/painted/*.py）要 Pillow 和 numpy，缺了就装
# 云端没有 Swift（download.swift.org 不通），Swift 改动推上去看 CI，见 CLAUDE.md
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

noreply() { case "$(git config user.email || true)" in *@users.noreply.github.com) return 0 ;; esac; return 1; }

if ! noreply; then
  # 用这次会话登录的 GitHub 账号的 noreply 地址（在 fork 上就是 fork 主人的）
  who=$(timeout 15 gh api user --jq '"\(.id) \(.login)"' 2>/dev/null || true)
  id=${who%% *}; login=${who#* }
  if [ -n "$who" ] && [ "$id" != "$who" ] && [ -n "$login" ]; then
    git config user.name "$login"
    git config user.email "$id+$login@users.noreply.github.com"
  elif git remote get-url origin 2>/dev/null | grep -q 'caihaodong44chd-gif/claude-quota-pet'; then
    # gh 用不了时，主人自己的仓库直接用主人的地址
    git config user.name caihaodong44chd-gif
    git config user.email 327893803+caihaodong44chd-gif@users.noreply.github.com
  fi
fi

if ! python3 -c 'import PIL, numpy' 2>/dev/null; then
  python3 -m pip install --quiet --user pillow numpy 2>/dev/null ||
    python3 -m pip install --quiet --user --break-system-packages pillow numpy
fi

# stdout 会进会话的上下文，只说一句现在的状态
if noreply; then
  git config core.hooksPath .githooks
  echo "QuotaPet 云端环境：隐私钩子已启用，提交身份 $(git config user.email)；这里没有 Swift，改了 Swift 推上去用 CI 验证（见 CLAUDE.md）。"
else
  echo "QuotaPet 云端环境：没找到 GitHub noreply 身份，隐私钩子没有启用。提交前先 git config user.email <id>+<login>@users.noreply.github.com，再 git config core.hooksPath .githooks。这里没有 Swift，改了 Swift 推上去用 CI 验证（见 CLAUDE.md）。"
fi
