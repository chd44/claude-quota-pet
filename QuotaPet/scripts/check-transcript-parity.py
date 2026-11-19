#!/usr/bin/env python3
"""跨实现的一致性检查：usage_lab.py 的 load_requests 和 App 的 ClaudeTranscriptScanner 对同一份日志（fixtures/transcript-ids.txt）
必须得出一样的请求。去重键：message.id → requestId → (文件, uuid)，都取非空的；三个都没有的行归到同一个文件里的同一条，取各字段最大值。
App 那边的同一组期望在 QuotaPetChecks 里（Claude Code 日志一节）。改任何一边的规则，两边的期望都要改。
全程只读合成的文件，不碰 ~/.claude。"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
import usage_lab  # noqa: E402

# (input, output)，和 QuotaPetChecks 里的 expectedIDRequests 一样
EXPECTED = [(1, 30), (2, 40), (3, 50), (6, 80), (9, 7)]

with tempfile.TemporaryDirectory() as tmp:
    project = os.path.join(tmp, "proj")
    os.makedirs(project)
    with open(os.path.join(HERE, "..", "fixtures", "transcript-ids.txt"), encoding="utf-8") as src, \
            open(os.path.join(project, "session.jsonl"), "w", encoding="utf-8") as dst:
        dst.write(src.read())
    usage_lab.TRANSCRIPT_GLOB = tmp + "/**/*.jsonl"
    got = sorted((r["tok"]["inp"], r["tok"]["out"]) for r in usage_lab.load_requests())
if got != EXPECTED:
    print(f"✗ usage_lab.py 和 App 的去重规则对不上：{got}，应该是 {EXPECTED}")
    sys.exit(1)
print(f"✓ usage_lab.py 的缺 ID 去重规则和 App 一致（{len(got)} 个请求）")
