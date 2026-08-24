#!/usr/bin/env python3
"""claude-usage-report — Claude Code のローカル記録からトークン利用状況を集計する。

【このスクリプトは何を読み、何を読まないか】
~/.claude/projects/**/*.jsonl の各行から、トークン数(message.usage 配下の数値)と
少数のメタデータ(model / effort / speed / service_tier / cwd / gitBranch /
isSidechain / sessionId / timestamp / requestId)だけを取り出します。
プロンプト本文・会話内容・ツールの入出力(message.content, toolUseResult 等)には
一切アクセスしません。読むフィールドは下の extract() に列挙されたものがすべてで、
それ以外のキーには触れず、出力にも会話内容は一切含まれません。

使い方:  python3 claude_usage_report.py [--dir PATH] [--days N] [--json FILE]
出力:    人が読む要約(標準出力) と 機械可読 JSON(--json、既定 claude-usage-report.json)

依存: Python 3.9+ 標準ライブラリのみ。
"""
import argparse, glob, json, os, sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

# 判定閾値(根拠は docs/claude-usage-report.md 参照)
CACHE_READ_RATE_MIN = 0.90  # キャッシュ読取率がこれ未満なら警告(効率的な利用の実測基準線は 97.8%)
FAST_SHARE_MAX = 0.05       # fast mode(割高)の割合がこれ超なら警告(基準線は 0%)
E5M_SHARE_MAX = 0.20        # キャッシュ書込のうち5分TTLの比率がこれ超なら警告(基準線は約4%)

TOKEN_KEYS = ("input_tokens", "output_tokens",
              "cache_read_input_tokens", "cache_creation_input_tokens")


def extract(rec):
    """1レコードから許可フィールドのみを抜き出す。usage の無い行(会話本文等)は None。"""
    msg = rec.get("message")
    usage = msg.get("usage") if isinstance(msg, dict) else None
    if not isinstance(usage, dict):
        return None
    cache = usage.get("cache_creation") or {}
    tools = usage.get("server_tool_use") or {}
    return {
        "tokens": {k: usage.get(k) or 0 for k in TOKEN_KEYS},
        "cache_1h": cache.get("ephemeral_1h_input_tokens") or 0,
        "cache_5m": cache.get("ephemeral_5m_input_tokens") or 0,
        "web_search": tools.get("web_search_requests") or 0,
        "web_fetch": tools.get("web_fetch_requests") or 0,
        "speed": usage.get("speed") or "(記録なし)",
        "service_tier": usage.get("service_tier") or "(記録なし)",
        "model": msg.get("model") or "(記録なし)",
        "effort": rec.get("effort") or "(記録なし)",
        "cwd": rec.get("cwd") or "(記録なし)",
        "git_branch": rec.get("gitBranch") or "(記録なし)",
        "sidechain": bool(rec.get("isSidechain")),
        "session_id": rec.get("sessionId"),
        "timestamp": rec.get("timestamp") if isinstance(rec.get("timestamp"), str) else None,
        "request_id": rec.get("requestId") or (msg.get("id") if isinstance(msg, dict) else None),
    }


def aggregate(base_dir, days=None, dedup=True):
    files = glob.glob(os.path.join(base_dir, "**", "*.jsonl"), recursive=True)
    since = None
    if days:
        since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S")
    agg = {
        "files": len(files), "parse_errors": 0, "requests": 0, "duplicate_rows_skipped": 0,
        "sessions": set(), "first_ts": None, "last_ts": None,
        "totals": Counter(), "by_model": defaultdict(Counter), "by_repo": defaultdict(Counter),
        "by_branch": defaultdict(lambda: defaultdict(Counter)),
        "effort": Counter(), "speed": Counter(), "service_tier": Counter(),
        "sidechain": defaultdict(Counter), "seen": set(),
    }
    for path in files:
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            agg["parse_errors"] += 1
            continue
        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    agg["parse_errors"] += 1
                    continue
                row = extract(rec) if isinstance(rec, dict) else None
                if row is None:
                    continue
                if since and row["timestamp"] and row["timestamp"] < since:
                    continue
                # 同一リクエストは複数行に分割記録され usage が複製される。既定で1回だけ数える
                if dedup and row["request_id"]:
                    if row["request_id"] in agg["seen"]:
                        agg["duplicate_rows_skipped"] += 1
                        continue
                    agg["seen"].add(row["request_id"])
                _add(agg, row)
    return agg


def _add(agg, row):
    agg["requests"] += 1
    if row["session_id"]:
        agg["sessions"].add(row["session_id"])
    ts = row["timestamp"]
    if ts:
        agg["first_ts"] = min(agg["first_ts"] or ts, ts)
        agg["last_ts"] = max(agg["last_ts"] or ts, ts)
    t = agg["totals"]
    for k, v in row["tokens"].items():
        t[k] += v
    t["cache_1h"] += row["cache_1h"]
    t["cache_5m"] += row["cache_5m"]
    t["web_search"] += row["web_search"]
    t["web_fetch"] += row["web_fetch"]
    m = agg["by_model"][row["model"]]
    m["requests"] += 1
    for k, v in row["tokens"].items():
        m[k] += v
    r = agg["by_repo"][row["cwd"]]
    r["requests"] += 1
    for k, v in row["tokens"].items():
        r[k] += v
    b = agg["by_branch"][row["cwd"]][row["git_branch"]]
    b["requests"] += 1
    b["output_tokens"] += row["tokens"]["output_tokens"]
    agg["effort"][row["effort"]] += 1
    agg["speed"][row["speed"]] += 1
    agg["service_tier"][row["service_tier"]] += 1
    s = agg["sidechain"]["sidechain" if row["sidechain"] else "main"]
    s["requests"] += 1
    s["output_tokens"] += row["tokens"]["output_tokens"]


def rates(agg):
    t = agg["totals"]
    read, write = t["cache_read_input_tokens"], t["cache_creation_input_tokens"]
    fast = sum(v for k, v in agg["speed"].items() if k == "fast")
    return {
        "cache_read_rate": read / (read + write) if read + write else None,
        "cache_5m_share": t["cache_5m"] / write if write else None,
        "fast_share": fast / agg["requests"] if agg["requests"] else None,
    }


def warnings_for(r):
    w = []
    if r["cache_read_rate"] is not None and r["cache_read_rate"] < CACHE_READ_RATE_MIN:
        w.append({"code": "low_cache_read_rate", "value": round(r["cache_read_rate"], 4),
                  "threshold": CACHE_READ_RATE_MIN,
                  "message": "キャッシュ読取率が低い。コンテキストの再書込が多い状態。"
                             "セッションを短く保つ・不要な /clear 直後の長文貼付を避ける等の見直し余地あり。"})
    if r["fast_share"] is not None and r["fast_share"] > FAST_SHARE_MAX:
        w.append({"code": "high_fast_mode_share", "value": round(r["fast_share"], 4),
                  "threshold": FAST_SHARE_MAX,
                  "message": "fast mode の割合が高い。fast は割高のため、急ぐ場面に限定する余地あり。"})
    if r["cache_5m_share"] is not None and r["cache_5m_share"] > E5M_SHARE_MAX:
        w.append({"code": "high_5m_ttl_share", "value": round(r["cache_5m_share"], 4),
                  "threshold": E5M_SHARE_MAX,
                  "message": "キャッシュ書込の5分TTL比率が高い。usage credits 利用中はキャッシュ寿命が"
                             "5分に落ちる。環境変数 ENABLE_PROMPT_CACHING_1H=1 で1時間に保てる"
                             "(最も費用対効果の高い設定)。"})
    return w


def M(n):  # 百万トークン表記
    return f"{n / 1e6:,.1f}M"


def render(agg, r, warns, json_path):
    t, out = agg["totals"], []
    period = f"{(agg['first_ts'] or '?')[:10]} 〜 {(agg['last_ts'] or '?')[:10]}"
    out.append(f"━━ Claude Code 利用レポート ({period}) ━━")
    out.append(f"対象: {agg['files']}ファイル / {len(agg['sessions'])}セッション / "
               f"{agg['requests']:,}リクエスト (重複行 {agg['duplicate_rows_skipped']:,} を除外 / "
               f"読み飛ばした壊れ行 {agg['parse_errors']})")
    out.append("")
    out.append("⚠ 警告: " + ("なし" if not warns else ""))
    for w in warns:
        out.append(f"  - {w['message']} [実測 {w['value']:.1%} / 閾値 {w['threshold']:.0%}]")
    out.append("")
    out.append(f"■ トークン合計  入力 {M(t['input_tokens'])} / 出力 {M(t['output_tokens'])} / "
               f"キャッシュ読取 {M(t['cache_read_input_tokens'])} / 書込 {M(t['cache_creation_input_tokens'])}")
    if r["cache_read_rate"] is not None:
        out.append(f"  キャッシュ読取率 {r['cache_read_rate']:.1%} (警告閾値 {CACHE_READ_RATE_MIN:.0%})")
    if r["cache_5m_share"] is not None:
        out.append(f"  書込TTL内訳: 1時間 {M(t['cache_1h'])} / 5分 {M(t['cache_5m'])} "
                   f"(5分比率 {r['cache_5m_share']:.1%})")
    out.append("")
    out.append("■ モデル別 (リクエスト / 出力 / キャッシュ読取)")
    for name, c in sorted(agg["by_model"].items(), key=lambda kv: -kv[1]["output_tokens"]):
        out.append(f"  {name:28s} {c['requests']:>7,}  {M(c['output_tokens']):>9}  "
                   f"{M(c['cache_read_input_tokens']):>10}")
    out.append("")
    dist = lambda c: " / ".join(f"{k} {v:,}" for k, v in c.most_common())
    out.append(f"■ effort: {dist(agg['effort'])}")
    out.append(f"■ speed:  {dist(agg['speed'])}" +
               (f"  (fast 割合 {r['fast_share']:.1%})" if r["fast_share"] is not None else ""))
    out.append(f"■ service_tier: {dist(agg['service_tier'])}")
    sc = agg["sidechain"]
    out.append(f"■ 本体/サブエージェント: main {sc['main']['requests']:,}req・出力 {M(sc['main']['output_tokens'])}"
               f" / subagent {sc['sidechain']['requests']:,}req・出力 {M(sc['sidechain']['output_tokens'])}")
    if agg["sessions"]:
        out.append(f"■ セッションあたり出力: {t['output_tokens'] // len(agg['sessions']):,} tokens")
    out.append(f"■ web検索 {t['web_search']:,}回 / webフェッチ {t['web_fetch']:,}回")
    out.append("")
    out.append("■ リポジトリ別 上位 (リクエスト / 出力)")
    for cwd, c in sorted(agg["by_repo"].items(), key=lambda kv: -kv[1]["output_tokens"])[:8]:
        out.append(f"  {cwd:52s} {c['requests']:>7,}  {M(c['output_tokens']):>9}")
    out.append("")
    out.append(f"機械可読の全量は {json_path} に出力済み(ブランチ別内訳もこちら)。")
    return "\n".join(out)


def to_json(agg, r, warns):
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "period": {"from": agg["first_ts"], "to": agg["last_ts"]},
        "files": agg["files"], "parse_errors": agg["parse_errors"],
        "requests": agg["requests"], "duplicate_rows_skipped": agg["duplicate_rows_skipped"],
        "sessions": len(agg["sessions"]),
        "totals": dict(agg["totals"]),
        "rates": {k: (round(v, 4) if v is not None else None) for k, v in r.items()},
        "thresholds": {"cache_read_rate_min": CACHE_READ_RATE_MIN,
                       "fast_share_max": FAST_SHARE_MAX, "e5m_share_max": E5M_SHARE_MAX},
        "warnings": warns,
        "by_model": {k: dict(v) for k, v in agg["by_model"].items()},
        "effort": dict(agg["effort"]), "speed": dict(agg["speed"]),
        "service_tier": dict(agg["service_tier"]),
        "sidechain": {k: dict(v) for k, v in agg["sidechain"].items()},
        "by_repo": {cwd: dict(c, branches={b: dict(bc) for b, bc in agg["by_branch"][cwd].items()})
                    for cwd, c in agg["by_repo"].items()},
    }


def main(argv=None):
    p = argparse.ArgumentParser(description="Claude Code ローカル記録の利用状況レポート(会話内容は読まない)")
    p.add_argument("--dir", default=os.path.expanduser("~/.claude/projects"),
                   help="セッション記録の場所 (既定: ~/.claude/projects)")
    p.add_argument("--days", type=int, default=None, help="直近N日のみ集計")
    p.add_argument("--json", default="claude-usage-report.json", help="JSON出力先 (- で標準出力のみ)")
    p.add_argument("--raw", action="store_true",
                   help="検証用: 同一リクエストの重複行を除外せずそのまま数える")
    a = p.parse_args(argv)
    if not os.path.isdir(a.dir):
        print(f"記録が見つかりません: {a.dir} (Claude Code 未使用の端末では出力なし)", file=sys.stderr)
        return 0
    agg = aggregate(a.dir, days=a.days, dedup=not a.raw)
    r = rates(agg)
    warns = warnings_for(r)
    payload = json.dumps(to_json(agg, r, warns), ensure_ascii=False, indent=1)
    if a.json == "-":
        print(payload)
    else:
        with open(a.json, "w", encoding="utf-8") as f:
            f.write(payload + "\n")
    print(render(agg, r, warns, a.json))
    return 0


if __name__ == "__main__":
    sys.exit(main())
