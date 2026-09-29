#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
智谱 GLM Coding Plan 用量查询脚本

通过智谱（bigmodel.cn）监控 API 查询本机 ANTHROPIC_API_KEY 对应的
GLM Coding Plan 套餐用量，涵盖三个限额维度：
- 周额度
- 5 小时滚动窗口
- 订阅周期额度池

用法:
    export ANTHROPIC_API_KEY=xxx            # 先设置环境变量
    python3 glm_usage_query.py              # 纯文本输出
    python3 glm_usage_query.py --markdown   # Markdown 表格输出

安全说明:
    API Key 仅通过环境变量 ANTHROPIC_API_KEY 读取，
    任何输出中都不会打印 Key 明文。
"""

import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

# 智谱监控 API 查询地址（只读 GET 接口，可重复调用）
API_URL = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
# 请求超时时间（秒）
TIMEOUT = 20


def fmt_ts(ms):
    """毫秒时间戳转本地时间字符串

    参数:
        ms: 毫秒时间戳，空值返回"未知"

    返回:
        本地时区的时间字符串，格式 %Y-%m-%d %H:%M
    """
    if not ms:
        return "未知"
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M")


def fetch_usage(api_key):
    """调用智谱监控 API 查询套餐用量

    参数:
        api_key: 认证用的 API Key

    返回:
        解析后的 JSON 响应字典

    异常:
        urllib.error.URLError: 网络错误
        ValueError: 响应非合法 JSON
    """
    req = urllib.request.Request(
        API_URL,
        headers={
            "Authorization": "Bearer " + api_key,
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def parse_limits(data):
    """解析 data.limits 数组为限额维度的行记录

    必须联合 type + unit 区分维度，不能只看 type:
    - type=TIME_LIMIT              → 订阅周期额度池
    - type=TOKENS_LIMIT 且 unit=3  → N 小时滚动窗口（number=小时数，通常为 5）
    - type=TOKENS_LIMIT 且 unit=6  → 周额度

    percentage 一律为"已用"百分比（非剩余），滚动窗口/周额度的剩余 = 100 - 已用。

    返回:
        行记录列表，每条含 name/used/remaining/next_reset/details 字段
    """
    rows = []
    for lim in data.get("limits") or []:
        t = lim.get("type")
        details = ""
        if t == "TIME_LIMIT":
            # 订阅周期额度池：usage=总额度, currentValue=已用, remaining=剩余
            name = "订阅周期额度池"
            used = "{}/{}（{}%）".format(lim.get("currentValue"), lim.get("usage"), lim.get("percentage"))
            remaining = "剩 {}".format(lim.get("remaining"))
            details = "；".join(
                "{}={}".format(u.get("modelCode"), u.get("usage"))
                for u in lim.get("usageDetails") or []
            )
        elif t == "TOKENS_LIMIT" and lim.get("unit") == 3:
            # N 小时滚动窗口：仅返回已用百分比
            name = "{} 小时滚动窗口".format(lim.get("number"))
            pct = lim.get("percentage") or 0
            used = "已用 {}%".format(pct)
            remaining = "剩 {}%".format(100 - pct)
        elif t == "TOKENS_LIMIT" and lim.get("unit") == 6:
            # 周额度：仅返回已用百分比
            name = "周额度"
            pct = lim.get("percentage") or 0
            used = "已用 {}%".format(pct)
            remaining = "剩 {}%".format(100 - pct)
        else:
            continue
        rows.append({
            "name": name,
            "used": used,
            "remaining": remaining,
            "next_reset": fmt_ts(lim.get("nextResetTime")),
            "details": details,
        })
    return rows


def print_plain(level, rows):
    """纯文本输出（人类可读）"""
    print("套餐等级:", level)
    for r in rows:
        line = "{} | {} | {} | 下次重置: {}".format(r["name"], r["used"], r["remaining"], r["next_reset"])
        if r["details"]:
            line += " | 分模型: " + r["details"]
        print(line)


def print_markdown(level, rows):
    """Markdown 表格输出，分模型明细附在表格下方"""
    print("你的 GLM Coding Plan 用量（套餐等级：{} 档）".format(level))
    print()
    print("| 限额维度 | 已用 | 剩余/进度 | 下次重置时间 |")
    print("|---------|------|----------|-------------|")
    for r in rows:
        print("| {} | {} | {} | {} |".format(r["name"], r["used"], r["remaining"], r["next_reset"]))
    details = [r for r in rows if r["details"]]
    if details:
        print()
        print("分模型明细：")
        for r in details:
            print("- {}: {}".format(r["name"], r["details"]))


def main():
    parser = argparse.ArgumentParser(description="智谱 GLM Coding Plan 用量查询（通过 ANTHROPIC_API_KEY 认证）")
    parser.add_argument("--markdown", action="store_true", help="以 Markdown 表格格式输出")
    args = parser.parse_args()

    # 仅从环境变量读取 Key，严禁在输出中打印 Key 明文
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        print("错误: 未设置环境变量 ANTHROPIC_API_KEY，请先 export 后重试", file=sys.stderr)
        return 1

    try:
        resp = fetch_usage(api_key)
    except urllib.error.HTTPError as e:
        # 尝试从错误响应体中提取接口的 msg 字段
        msg = ""
        try:
            body = json.loads(e.read().decode("utf-8"))
            msg = body.get("msg", "")
        except Exception:
            pass
        print("错误: API 返回 HTTP {}{}".format(e.code, "，{}".format(msg) if msg else ""), file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError) as e:
        print("错误: 网络请求失败: {}".format(e), file=sys.stderr)
        return 1
    except ValueError as e:
        print("错误: 响应不是合法 JSON: {}".format(e), file=sys.stderr)
        return 1

    # code 非 200 或 success 为 false 时，向用户展示接口返回的 msg
    if resp.get("code") != 200 or resp.get("success") is False:
        print("查询失败: {}（可能是 Key 无效、非 Coding Plan 套餐或网络问题）".format(resp.get("msg", "未知错误")), file=sys.stderr)
        return 1

    data = resp.get("data") or {}
    rows = parse_limits(data)
    if not rows:
        print("警告: 未解析到任何限额数据", file=sys.stderr)
        return 1

    if args.markdown:
        print_markdown(data.get("level", "未知"), rows)
    else:
        print_plain(data.get("level", "未知"), rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
