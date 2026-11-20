#!/usr/bin/env bash
# 单一资源清单，供打包、最终归档校验及合成 CI fixture 共用；输出不含扩展名。
#   默认：每款必需的 30 张（基础图 + 四个额度档位）
#   --optional：可以补充的状态图（GPT 补图后放进 Resources/Pets/agy 即可；缺图时 App 退回基础图）
set -euo pipefail
if [[ "${1:-}" == "--optional" ]]; then
    for prefix in '' pilot- gardener-; do
        for kind in menu panel; do
            for state in revived resting nervous confused loading poke pout; do
                printf '%s%s-%s\n' "$prefix" "$kind" "$state"
            done
        done
    done
    exit 0
fi
for prefix in '' pilot- gardener-; do
    for kind in menu panel; do
        printf '%s%s\n' "$prefix" "$kind"
        for state in energetic tired exhausted sleeping; do
            printf '%s%s-%s\n' "$prefix" "$kind" "$state"
        done
    done
done
