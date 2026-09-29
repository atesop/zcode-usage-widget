#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GLM Coding Plan 多 Profile 用量一键总览

扫描 ~/.claude/profiles 下文件名包含 glm-flash 的 profile（与 ccc 工具共用同一批配置），
并发调用智谱监控 API 查询各订阅套餐用量，排版对齐后一次性输出总览。

用法:
    glmu                                  # 查询全部 glm-flash profile（默认，无交互）
    glmu --pattern glm                    # 自定义文件名匹配关键字
    glmu --dir ~/.claude/profiles         # 显式指定 profile 目录

安全说明:
    Token 仅从 profile JSON 读取（ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY），
    任何输出中都不会打印 Token 明文。
"""

import argparse
import datetime
import glob
import json
import os
import sys
import unicodedata
import urllib.error
from concurrent.futures import ThreadPoolExecutor

# 复用同目录 glm_usage_query.py 的请求与时间格式化逻辑
_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from glm_usage_query import fetch_usage, fmt_ts  # noqa: E402

# profile 目录与匹配关键字默认值
DEFAULT_PROFILES_DIR = os.path.expanduser("~/.claude/profiles")
DEFAULT_PATTERN = "glm-flash"
# 用量进度条样式与格数
BAR_FILLED = "▰"
BAR_EMPTY = "▱"
BAR_SLOTS = 10
# 已用百分比着色阈值（黄/红）
WARN_PCT = 60
CRIT_PCT = 85
# 汇总提醒阈值
ALERT_PCT = 80


# ---------- 渲染工具 ----------

def paint(text, code: str) -> str:
    """给文本加 ANSI 颜色；非 TTY 或设置了 NO_COLOR 时原样返回"""
    if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
        return str(text)
    return "\033[{}m{}\033[0m".format(code, text)


def dw(text: str) -> int:
    """终端显示宽度：中文等全角字符按 2 列计"""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def pad(text: str, width: int) -> str:
    """按显示宽度右补空格，保证中英文混排对齐"""
    return text + " " * max(0, width - dw(text))


def fmt_num(value) -> str:
    """大数字人类可读化：12345678 -> 12.3M，2000 -> 2000（小数值保留原样）"""
    if value is None:
        return "未知"
    try:
        num = float(value)
    except (TypeError, ValueError):
        return str(value)
    for div, suffix in ((1000000000, "B"), (1000000, "M")):
        if abs(num) >= div:
            short = num / div
            tpl = "{:.0f}{}" if abs(short) >= 100 else "{:.1f}{}"
            return tpl.format(short, suffix)
    if num == int(num):
        return str(int(num))
    return "{:.2f}".format(num)


def pct_color(pct) -> str:
    """按已用百分比返回 ANSI 颜色码：>=85 红，>=60 黄，其余绿"""
    pct = int(pct or 0)
    if pct >= CRIT_PCT:
        return "31"
    if pct >= WARN_PCT:
        return "33"
    return "32"


def usage_bar(pct) -> str:
    """生成带颜色的 10 格用量进度条"""
    pct = max(0, min(100, int(pct or 0)))
    filled = round(pct * BAR_SLOTS / 100)
    bar = BAR_FILLED * filled + BAR_EMPTY * (BAR_SLOTS - filled)
    return paint(bar, pct_color(pct))


# ---------- 数据解析 ----------

def extract_token(path: str) -> str:
    """从 profile JSON 中递归查找 ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY

    异常:
        OSError: 文件不存在或不可读
        ValueError: JSON 格式非法
    """
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    def walk(node):
        if isinstance(node, dict):
            for key in ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
                val = node.get(key)
                if isinstance(val, str) and val.strip():
                    return val.strip()
            for val in node.values():
                found = walk(val)
                if found:
                    return found
        elif isinstance(node, list):
            for item in node:
                found = walk(item)
                if found:
                    return found
        return None

    return walk(data)


def parse_quota(data: dict) -> list:
    """解析 data.limits 为结构化限额行

    按 type+unit 组合判定维度（percentage 一律为"已用"百分比）：
    - TIME_LIMIT                        -> 订阅周期额度池（含总量/剩余/分模型明细）
    - CREDIT_LIMIT + unit=3/6           -> lite 档的 N 小时窗口 / 周额度（含总量/剩余数值）
    - TOKENS_LIMIT + unit=3/6           -> Coding Plan 的 N 小时窗口 / 周额度（仅已用百分比）

    返回:
        行记录列表，每条含 name/pct/extra/reset/details 字段
    """
    rows = []
    for lim in data.get("limits") or []:
        t = lim.get("type")
        reset = fmt_ts(lim.get("nextResetTime"))
        # 维度名：unit=3 为 N 小时窗口，unit=6 为周额度
        if t == "TIME_LIMIT":
            name = "订阅周期额度池"
        elif lim.get("unit") == 3:
            name = "{} 小时窗口".format(lim.get("number"))
        elif lim.get("unit") == 6:
            name = "周额度"
        else:
            continue

        if t == "TOKENS_LIMIT":
            # 仅返回已用百分比
            pct = int(lim.get("percentage") or 0)
            extra = "剩 {}%".format(100 - pct)
            details = ""
        elif t in ("TIME_LIMIT", "CREDIT_LIMIT"):
            # 返回 总量/已用/剩余 数值
            pct = lim.get("percentage")
            extra = "共 {} · 剩 {}".format(
                fmt_num(lim.get("usage")), fmt_num(lim.get("remaining"))
            )
            details = ""
            if t == "TIME_LIMIT":
                details = "；".join(
                    "{}={}".format(u.get("modelCode"), fmt_num(u.get("usage")))
                    for u in lim.get("usageDetails") or []
                )
        else:
            continue
        rows.append({"name": name, "pct": pct, "extra": extra, "reset": reset, "details": details})
    return rows


def query_profile(path: str) -> dict:
    """查询单个 profile 的套餐用量

    失败不抛出，统一记入返回值的 error 字段，保证其余 profile 不受影响。

    返回:
        {ok, path, name, level, rows, error} 字典
    """
    result = {
        "ok": False,
        "path": path,
        "name": os.path.splitext(os.path.basename(path))[0],
        "level": "",
        "rows": [],
        "error": "",
    }
    try:
        token = extract_token(path)
        if not token:
            result["error"] = "profile 中未找到 ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY 字段"
            return result
        resp = fetch_usage(token)
        if resp.get("code") != 200 or resp.get("success") is False:
            result["error"] = "接口返回: {}".format(resp.get("msg") or "未知错误")
            return result
        data = resp.get("data") or {}
        rows = parse_quota(data)
        if not rows:
            # 携带原始 types，便于排查新增的未知限额类型
            types = ",".join(sorted({str(l.get("type")) for l in data.get("limits") or []}))
            result["error"] = "未解析到任何限额数据（types: {}）".format(types or "空")
            return result
        result.update(ok=True, level=str(data.get("level") or "未知"), rows=rows)
        return result
    except urllib.error.HTTPError as exc:
        # 尝试从错误响应体中提取接口的 msg 字段
        msg = ""
        try:
            msg = json.loads(exc.read().decode("utf-8")).get("msg", "")
        except Exception:
            pass
        result["error"] = "HTTP {}{}".format(exc.code, "：{}".format(msg) if msg else "")
    except urllib.error.URLError as exc:
        result["error"] = "网络错误: {}".format(exc.reason)
    except TimeoutError:
        result["error"] = "请求超时"
    except (OSError, ValueError) as exc:
        # OSError: 文件读取失败；ValueError: JSON 非法
        result["error"] = "配置/响应异常: {}".format(exc)
    return result


def render(results: list, pattern: str) -> str:
    """把查询结果排版为总览文本（对齐 + 配色 + 汇总提醒）"""
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    ok_list = [r for r in results if r["ok"]]
    lines = [
        paint("GLM Coding Plan 用量总览", "1;36"),
        paint("{} · 关键字 '{}'：成功 {}/{}".format(now, pattern, len(ok_list), len(results)), "2"),
        "",
    ]
    # 各列宽度全局统一，保证不同 profile 之间纵向对齐
    name_width = max((dw(row["name"]) for r in ok_list for row in r["rows"]), default=0)
    extra_width = max((dw(row["extra"]) for r in ok_list for row in r["rows"]), default=0)

    for res in results:
        if not res["ok"]:
            lines.append(paint("◆ " + res["name"], "1") + paint("  ✗ 查询失败：" + res["error"], "31"))
            lines.append("")
            continue
        lines.append(paint("◆ " + res["name"], "1") + paint("  〔{}〕".format(res["level"]), "36"))
        for i, row in enumerate(res["rows"]):
            branch = "├" if i < len(res["rows"]) - 1 else "└"
            pct = int(row["pct"] or 0)
            line = "".join([
                "  {} ".format(branch),
                pad(row["name"], name_width),
                "  ",
                usage_bar(pct),
                paint(" {:>3}% ".format(pct), pct_color(pct)),
                pad(row["extra"], extra_width),
                paint("  重置 {}".format(row["reset"]), "2"),
            ])
            if row["details"]:
                line += paint("  · " + row["details"], "2")
            lines.append(line)
        lines.append("")

    # 汇总提醒：列出所有已用达到阈值的维度
    alerts = []
    for res in ok_list:
        for row in res["rows"]:
            pct = int(row["pct"] or 0)
            if pct >= ALERT_PCT:
                alerts.append("{} 的 {} 已用 {}%".format(res["name"], row["name"], pct))
    if alerts:
        lines.append(paint("⚠ 接近限额：" + "；".join(alerts), "33"))
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="GLM Coding Plan 多 Profile 用量一键总览（无交互）")
    parser.add_argument("-d", "--dir", default=DEFAULT_PROFILES_DIR,
                        help="profile 目录（默认 ~/.claude/profiles）")
    parser.add_argument("-p", "--pattern", default=DEFAULT_PATTERN,
                        help="文件名匹配关键字（默认 glm-flash）")
    parser.add_argument("--json", action="store_true",
                        help="以 JSON 格式输出（供程序调用，如 Windows 悬浮小组件）")
    args = parser.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, "*{}*.json".format(args.pattern))))
    if not files:
        print("错误: {} 下未找到文件名含 '{}' 的 profile".format(args.dir, args.pattern), file=sys.stderr)
        return 1

    # 并发查询（各 profile 相互独立，单个失败不影响其余）
    with ThreadPoolExecutor(max_workers=min(8, len(files))) as pool:
        results = list(pool.map(query_profile, files))

    if args.json:
        # 结构化输出：稳定契约，供 Windows 小组件等程序消费
        payload = {
            "queried_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "pattern": args.pattern,
            "results": [
                {
                    "name": r["name"],
                    "ok": r["ok"],
                    "level": r["level"],
                    "rows": r["rows"],
                    "error": r["error"],
                }
                for r in results
            ],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render(results, args.pattern), end="")
    return 0 if all(r["ok"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
