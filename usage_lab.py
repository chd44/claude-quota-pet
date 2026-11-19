#!/usr/bin/env python3
"""Claude 订阅额度实验室

把本机 Claude Code 的逐请求 token 记录（~/.claude/projects/**/*.jsonl）
和额度百分比快照（桌面端每 15 分钟一次的 plan-usage-history.json，
加上手动记录的 snapshots.jsonl）按时间对齐，用最小二乘回归估算：

    每 1% 的 5 小时额度 ≈ 多少 API 等价美元 ≈ 多少 tokens（按模型）

只读本机文件，不联网、不读任何凭据。

用法：
    python3 usage_lab.py summary [--hours 24]      各模型 token 用量汇总
    python3 usage_lab.py snap FH SD [--note 文字]   手动记一个额度快照（5小时% 每周%）
    python3 usage_lab.py ratio                       每周%/5小时% 的换算比
    python3 usage_lab.py calibrate --since ISO时间   回归 + 每周额度估算
    python3 usage_lab.py backtest                    按 App 的学习方式逐区间回测实时估算
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
TRANSCRIPT_GLOB = HOME + "/.claude/projects/**/*.jsonl"
HISTORY = HOME + "/Library/Application Support/Claude/plan-usage-history.json"
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "snapshots.jsonl")

# 官方 API 价格，$/百万 tokens：输入, 5分钟缓存写, 1小时缓存写, 缓存读, 输出
# 按提示词长短分两档的模型后面再跟两项：提示词超过多少 token、超过时各项乘几（与 ModelPrice.longPromptAbove 一致）
# 来源：platform.claude.com/docs/en/about-claude/pricing（2026-10）
# 各模型族当前这一代（Fable 5.1、Opus 5.5、Sonnet 5.5、Haiku 5.5），与 ClaudePricing.currentPrice 一致
PRICES = {
    "fable": (10, 12.5, 20, 0.25, 50),
    "opus": (4, 5, 8, 0.20, 20),
    "sonnet": (2, 2.5, 4, 0.20, 10),
    "haiku": (0.1, 0.125, 0.2, 0.01, 0.5, 100_000, 5),  # Haiku 5.5：提示词超过 10 万 token 的整个请求 $0.50 / $2.50
}
# 同一族里更老、价格不一样的版本：版本号低于第一项的按第二项算，从新到旧排（与 ClaudePricing.olderPrices 一致）。
# 模型名里读不出版本号的（或者是还没收录的新版本）按 PRICES 算
OLDER_PRICES = {
    "fable": [((5, 1), (10, 12.5, 20, 1.0, 50))],       # Fable 5、Mythos 5：缓存读 $1
    "opus": [((5, 5), (5, 6.25, 10, 0.50, 25)),          # Opus 4.5～5
             ((4, 5), (15, 18.75, 30, 1.50, 75))],       # Opus 4、4.1
    "sonnet": [((5, 0), (3, 3.75, 6, 0.30, 15))],        # Sonnet 4.6 及更早
    "haiku": [((5, 5), (1, 1.25, 2, 0.10, 5)),          # Haiku 4.5
              ((4, 5), (0.8, 1, 1.6, 0.08, 4))],         # Haiku 3.5（Bedrock 等还能用）
}
# 缓存读在额度里大约只算 API 价格的一半（与 ClaudePricing.cacheReadQuotaWeight 一致）
CACHE_READ_WEIGHT = 0.5
# 起始换算率，额度加权美元 / 1%（与 ClaudeRates.starting 一致）
STARTING = {"fh": 0.27, "sd": 2.0}
# 官方增量比本机估算多出 a + b×本机估算 才算其他端（网页 / 手机）用量（与 OtherUsage.threshold 一致）
OTHER_THRESHOLD = (2, 0.2)
FIELDS = ("inp", "cw5", "cw1h", "cr", "out")
FIELD_NAMES = {"inp": "输入", "cw5": "缓存写5m", "cw1h": "缓存写1h", "cr": "缓存读", "out": "输出"}


def family(model):
    """模型名里包含哪个族就算哪个（和 ModelFamily.of 一样）。Mythos 和 Fable 同一档、同样的价格，算 Fable"""
    model = (model or "").lower()
    if "mythos" in model:
        return "fable"
    for f in PRICES:
        if f in model:
            return f
    return None


def version(model, fam):
    """模型名里的版本号（和 ClaudePricing.version 一样）：claude-opus-4-8 → (4, 8)、claude-opus-4-20250514 → (4, 0)、
    老命名 claude-3-7-sonnet → (3, 7)。族名后面（或者前面）紧跟的一两位数字才算，日期那种长数字不算；读不出来是 None"""
    parts = re.split(r"[^a-z0-9]+", (model or "").lower())
    names = {"fable", "mythos"} if fam == "fable" else {fam}
    i = next((i for i, p in enumerate(parts) if p in names), None)
    if i is None:
        return None

    def numbers(tokens):
        out = []
        for t in tokens:
            if len(out) == 2 or not (t.isdigit() and len(t) <= 2):
                break
            out.append(int(t))
        return out

    found = numbers(parts[i + 1:]) or numbers(parts[:i][::-1])[::-1]
    return (found[0], found[1] if len(found) > 1 else 0) if found else None


def price(model, fam):
    """某个模型的价格：先按族取当前这一代的，模型名里的版本号更老时换成那一代的"""
    p, v = PRICES[fam], version(model, fam)
    for below, older in OLDER_PRICES.get(fam, []) if v else []:
        if v < below:
            p = older
    return p


def applied(p, tok):
    """这个请求实际用的价格（和 ModelPrice.applied 一样）：分档的模型提示词（输入 + 缓存写 + 缓存读）超过门槛时各项乘倍数"""
    if len(p) > 5 and sum(tok[k] for k in FIELDS if k != "out") > p[5]:
        return tuple(x * p[6] for x in p[:5])
    return p[:5]


def cost(p, tok):
    """API 等价花费，p 是 price() 给的价格"""
    p = applied(p, tok)
    return sum(tok[k] * p[i] for i, k in enumerate(FIELDS)) / 1e6


def parse_ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def fmt_ts(t):
    return dt.datetime.fromtimestamp(t).strftime("%m-%d %H:%M:%S")


def load_requests():
    """每个 API 响应在 jsonl 里会按内容块拆成多行、usage 重复，按 message.id 去重。"""
    reqs = {}
    for path in glob.glob(TRANSCRIPT_GLOB, recursive=True):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                m = d.get("message")
                if not isinstance(m, dict) or not m.get("usage") or "timestamp" not in d:
                    continue
                fam = family(m.get("model"))
                if not fam:  # 例如 <synthetic> 占位消息
                    continue
                u = m["usage"]
                cc = u.get("cache_creation") or {}
                if cc:
                    cw5, cw1h = cc.get("ephemeral_5m_input_tokens") or 0, cc.get("ephemeral_1h_input_tokens") or 0
                else:
                    cw5, cw1h = u.get("cache_creation_input_tokens") or 0, 0
                tok = {"inp": u.get("input_tokens") or 0, "cw5": cw5, "cw1h": cw1h,
                       "cr": u.get("cache_read_input_tokens") or 0, "out": u.get("output_tokens") or 0}
                # 和 App（ClaudeTranscriptScanner.ingest）一样：message.id → requestId → (文件, uuid)，都取非空的；
                # 三个都没有的行归到同一个文件里的同一条（取各字段最大值）
                key = m.get("id") or d.get("requestId") or (path, d.get("uuid") or None)
                prev = reqs.get(key)
                if prev:  # 同一响应取各字段最大值（流式中途写入的行可能偏小）
                    for k in FIELDS:
                        prev["tok"][k] = max(prev["tok"][k], tok[k])
                    prev["t"] = max(prev["t"], parse_ts(d["timestamp"]))
                else:
                    reqs[key] = {"t": parse_ts(d["timestamp"]), "fam": fam, "price": price(m.get("model"), fam), "tok": tok,
                                 "sub": "/subagents/" in path or bool(d.get("isSidechain"))}
    return sorted(reqs.values(), key=lambda r: r["t"])


def load_snapshots():
    """合并桌面端历史 + 手动快照，返回 [(t秒, fh, sd, 来源)]。
    桌面端切换过账号时只用最近那个组织的读数，和 App（ClaudeDesktopHistory.parse）一样。"""
    snaps = []
    try:
        with open(HISTORY, encoding="utf-8") as fh:
            # 和 App 一样只看至少有一个数字读数的样本（JSON 的 true/false 在 App 里也算数字）
            samples = sorted((s for s in json.load(fh).get("samples", [])
                              if "t" in s and any(isinstance(v, (int, float)) for v in (s.get("u") or {}).values())),
                             key=lambda s: s["t"])
        org = samples[-1].get("org") if samples else None
        for s in samples:
            u = s["u"]
            if (org is None or s.get("org") == org) and "fh" in u and "sd" in u:
                snaps.append((s["t"] / 1000, u["fh"], u["sd"], "desktop"))
    except (OSError, ValueError):
        pass
    if os.path.exists(LOG):
        with open(LOG, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    s = json.loads(line)
                    snaps.append((parse_ts(s["t"]), s["fh"], s["sd"], s.get("note") or "manual"))
    return sorted(snaps)


def bucket(reqs, t0, t1):
    """(t0, t1] 区间内按模型族汇总：请求数 n、token、API 等价成本 usd、其中缓存读的成本 cr_usd、最近一个请求的价格 price。
    每个请求按它自己的模型版本定价，同一族里新老版本混着用也对。"""
    out = collections.defaultdict(lambda: {"n": 0, "tok": dict.fromkeys(FIELDS, 0), "usd": 0.0, "cr_usd": 0.0, "price": None})
    for r in reqs:
        if t0 < r["t"] <= t1:
            x = out[r["fam"]]
            x["n"] += 1
            for k in FIELDS:
                x["tok"][k] += r["tok"][k]
            x["usd"] += cost(r["price"], r["tok"])
            x["cr_usd"] += r["tok"]["cr"] * applied(r["price"], r["tok"])[3] / 1e6
            x["price"] = r["price"]
    return out


def quota_cost(x, weight=CACHE_READ_WEIGHT):
    """额度加权花费：缓存读打折，和 App 的实时估算一样。x 是 bucket() 里一个模型族的汇总"""
    return x["usd"] - (1 - weight) * x["cr_usd"]


def solve(a, b):
    """高斯消元解 a x = b。"""
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        if abs(m[p][c]) < 1e-12:
            raise ValueError("数据不足以区分这些模型（矩阵奇异）")
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def lstsq(rows, ys):
    k = len(rows[0])
    ata = [[sum(r[i] * r[j] for r in rows) for j in range(k)] for i in range(k)]
    aty = [sum(r[i] * y for r, y in zip(rows, ys)) for i in range(k)]
    return solve(ata, aty)


# ---------------------------------------------------------------- 命令

def cmd_summary(args):
    reqs = load_requests()
    t0 = dt.datetime.now().timestamp() - args.hours * 3600
    print(f"最近 {args.hours} 小时，本机 Claude Code 请求（不含网页/手机端）：\n")
    print(f"{'模型':<8}{'请求数':>7}" + "".join(f"{FIELD_NAMES[k]:>11}" for k in FIELDS) + f"{'API等价$':>10}")
    for fam, x in bucket(reqs, t0, float("inf")).items():
        print(f"{fam:<8}{x['n']:>8}" + "".join(f"{x['tok'][k]:>13,}" for k in FIELDS) + f"{x['usd']:>11.2f}")


def cmd_snap(args):
    rec = {"t": dt.datetime.now(dt.timezone.utc).isoformat(), "fh": args.fh, "sd": args.sd, "note": args.note}
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print("已记录", rec)


def weekly_ratio(snaps):
    """在 5 小时窗口和每周窗口都没重置的连续段里，累计 Δ周% / Δ5小时%。"""
    dfh = dsd = 0
    seg = [snaps[0]] if snaps else []
    for s in snaps[1:] + [None]:
        if s is None or s[1] < seg[-1][1] or s[2] < seg[-1][2]:
            if len(seg) > 1:
                dfh += seg[-1][1] - seg[0][1]
                dsd += seg[-1][2] - seg[0][2]
            seg = [s] if s else []
        else:
            seg.append(s)
    return (dsd / dfh if dfh else None), dfh, dsd


def cmd_ratio(args):
    r, dfh, dsd = weekly_ratio(load_snapshots())
    if r is None:
        sys.exit("快照不够，无法计算")
    print(f"累计 5小时额度涨了 {dfh}%，同期每周额度涨了 {dsd}%")
    print(f"=> 1% 的 5小时额度 ≈ {r:.3f}% 的每周额度；一个满的 5 小时窗口 ≈ 每周额度的 {100 * r:.1f}%")
    print(f"=> 每周额度 ≈ {1 / r:.1f} 个满的 5 小时窗口")


def cmd_calibrate(args):
    reqs = load_requests()
    since = parse_ts(args.since) if args.since else 0
    until = parse_ts(args.until) if args.until else float("inf")
    snaps = [s for s in load_snapshots() if since <= s[0] <= until and (not args.manual_only or s[3] != "desktop")]
    if len(snaps) < 3:
        sys.exit("区间内快照少于 3 个")
    # 只用同一个 5 小时窗口里的连续快照（遇到重置就截断）
    for i in range(1, len(snaps)):
        if snaps[i][1] < snaps[i - 1][1]:
            snaps = snaps[:i]
            break
    base_t = snaps[0][0]
    # --known opus=0.27：该模型每 1% 的额度加权花费已知（缓存读按 CACHE_READ_WEIGHT 折算，不是 API 原价），直接从 y 里扣掉，不参与回归
    known = {k: float(v) for k, v in (kv.split("=") for kv in args.known)}
    fams = sorted({r["fam"] for r in reqs if base_t < r["t"] <= snaps[-1][0]} - set(known))
    rows, ys = [], []
    print(f"{'快照时间':<16}{'5h%':>5}{'周%':>5}  " + "".join(f"{f + '$':>9}" for f in fams) + "   备注")
    for s in snaps:
        spent = bucket(reqs, base_t, s[0])
        x = [quota_cost(spent[f]) for f in fams]
        rows.append(x + [1.0])  # 截距吸收起始点的取整误差
        ys.append(s[1] - sum(quota_cost(spent[f]) / per for f, per in known.items()))
        print(f"{fmt_ts(s[0]):<16}{s[1]:>5}{s[2]:>5}  " + "".join(f"{v:>9.3f}" for v in x) + f"   {s[3]}")
    coef = lstsq(rows, ys)
    resid = [y - sum(c * v for c, v in zip(coef, r)) for r, y in zip(rows, ys)]
    rms = (sum(e * e for e in resid) / len(resid)) ** 0.5
    ratio, _, _ = weekly_ratio(load_snapshots())
    if args.weekly_ratio:
        ratio = args.weekly_ratio
    spent_all = bucket(reqs, base_t, snaps[-1][0])

    print(f"\n回归残差 RMS = {rms:.2f} 个百分点（百分比是整数，<0.5 算拟合良好）")
    print(f"每周/5小时 换算比 = {ratio:.3f}\n")
    for f, k in zip(fams, coef):
        if k <= 0:
            print(f"{f}: 系数 ≤ 0，数据不足")
            continue
        per_pct = 1 / k                      # 1% 5小时额度 ≈ $
        window = 100 / k                     # 满 5 小时窗口 ≈ $
        week = window / (100 * ratio) * 100  # 满周额度 ≈ $
        p = spent_all[f]["price"] or PRICES[f]  # 换算成 token 时按这一族最近用的那个版本的价格
        mix_cost = quota_cost(spent_all[f])
        mix_tok = sum(spent_all[f]["tok"].values())
        print(f"【{f}】 1% 5小时额度 ≈ ${per_pct:.3f}   满 5 小时窗口 ≈ ${window:.1f}   满周 ≈ ${week:.0f}（缓存读按 {CACHE_READ_WEIGHT:g} 倍算）")
        print(f"   换成纯输出 tokens：5小时 ≈ {window / p[4] * 1e6:,.0f}   每周 ≈ {week / p[4] * 1e6:,.0f}")
        print(f"   换成纯新输入 tokens：5小时 ≈ {window / p[0] * 1e6:,.0f}   每周 ≈ {week / p[0] * 1e6:,.0f}")
        if mix_cost > 0:
            print(f"   按本次实验的实际 token 构成（含缓存）：每周 ≈ {week / mix_cost * mix_tok:,.0f} tokens")
        print()


def learn(done, prior, half_life):
    """和 App 的 RateLearner 一样学换算率。done = [(结束时间, 额度加权花费, 官方增量)]，按时间排序。
    Σ权重×花费 ÷ Σ权重×增量，权重按半衰期从最近一个区间往前算，16 个半衰期以前的不算，加 $2 的先验。
    同时在其他端用过（官方涨得明显比本机多）的区间不用：先用按「时间衰减 × 花费」加权的中位数挑，
    再用剩下的区间学到的换算率重新挑，直到挑出来的不再变。"""
    if not done:
        return prior
    latest = done[-1][0]
    items = [x for x in done if latest - x[0] < 16 * half_life]
    weight = lambda end: 0.5 ** ((latest - end) / half_life)

    def fit(xs):
        spent, gained = 2.0, 2.0 / prior
        for end, u, d in xs:
            spent, gained = spent + weight(end) * u, gained + weight(end) * d
        return spent / gained

    points = sorted(((u / d if d > 0 else float("inf")), weight(end) * u) for end, u, d in items)
    half, acc, rate = sum(w for _, w in points) / 2, 0.0, None
    for r, w in points:
        acc += w
        if acc >= half:
            rate = r if r != float("inf") else None
            break
    rate = rate or fit(items)
    a0, b0 = OTHER_THRESHOLD
    mixed = None
    for _ in range(len(items) + 1):  # 单调，一定会停
        flags = [d - u / rate > a0 + b0 * u / rate for _, u, d in items]
        if flags == mixed:
            break
        mixed = flags
        clean = [x for x, f in zip(items, flags) if not f]
        if clean:
            rate = fit(clean)
    if all(mixed):  # 挑完一个有效的区间都没剩：rate 是挑掉之前学到的，不能用，回到起始值（和 App 的 RateLearner 一样）
        return prior
    return min(max(rate, prior / 10), prior * 10)


def cmd_backtest(args):
    """每个 15 分钟区间结束时，用之前的区间学到的换算率（见 learn）估算这段的官方增量，和实际增量比。"""
    reqs = load_requests()
    snaps = [s for s in load_snapshots() if s[3] == "desktop"]
    for col, name in ((1, "5 小时"), (2, "每周")):
        prior = STARTING["fh" if col == 1 else "sd"]
        done, errs, stale, down = [], [], [], 0
        for a, b in zip(snaps, snaps[1:]):
            if b[0] - a[0] > 20 * 60 or b[col] < a[col]:  # 桌面端没开 / 窗口重置了
                continue
            spent = bucket(reqs, a[0], b[0]).values()
            if sum(x["usd"] for x in spent) < 0.02:  # 本机没在用
                continue
            usd = sum(quota_cost(x, args.cache_weight) for x in spent)
            rate = learn(done, prior, args.half_life * 3600)
            est, actual = usd / rate, b[col] - a[col]
            errs.append(abs(est - actual))
            stale.append(actual)
            down += actual - est < -1
            done.append((b[0], usd, actual))
        if not done:
            print(f"{name}：没有可用的区间")
            continue
        n = len(errs)
        print(f"{name}：{n} 个区间，缓存读 ×{args.cache_weight:g}，半衰期 {args.half_life:g} 小时")
        print(f"  区间结束时只看上次官方读数：平均差 {sum(stale) / n:.2f} 个百分点")
        print(f"  实时估算：平均差 {sum(errs) / n:.2f}，最大 {max(errs):.1f}；官方读数比估算低 1 点以上（数字往回跳）{down} 次")
        print(f"  全部区间合起来：每 1% ≈ ${sum(u for _, u, _ in done) / max(1, sum(d for _, _, d in done)):.3f}（重新定起始值时用）")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary"); s.add_argument("--hours", type=float, default=24); s.set_defaults(fn=cmd_summary)
    s = sub.add_parser("snap"); s.add_argument("fh", type=int); s.add_argument("sd", type=int)
    s.add_argument("--note", default=""); s.set_defaults(fn=cmd_snap)
    s = sub.add_parser("ratio"); s.set_defaults(fn=cmd_ratio)
    s = sub.add_parser("calibrate"); s.add_argument("--since"); s.add_argument("--until")
    s.add_argument("--manual-only", action="store_true", help="只用手动快照（实验时推荐）")
    s.add_argument("--weekly-ratio", type=float, help="手动指定 每周%%/5小时%% 换算比")
    s.add_argument("--known", nargs="*", default=[], metavar="模型=$每1%%",
                   help="已知速率的模型，例如 opus=0.27（额度加权美元：缓存读按半价，不是 API 原价），其消耗会先从额度变化里扣掉")
    s.set_defaults(fn=cmd_calibrate)
    s = sub.add_parser("backtest"); s.add_argument("--cache-weight", type=float, default=CACHE_READ_WEIGHT)
    s.add_argument("--half-life", type=float, default=3, help="小时"); s.set_defaults(fn=cmd_backtest)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
