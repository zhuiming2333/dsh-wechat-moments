#!/usr/bin/env python3
"""给 WeChatAgent 的 reader-api.py 打上「朋友圈只读」路由。

背景
----
reader-api.py 是 WeChatAgent 自己写出来的脚本，程序更新 / 重启时会**整个被覆盖**，
所以直接把代码内联进去，改动迟早会丢（本项目实测丢过三次）。

这里改成：朋友圈逻辑全部放在独立的 sns_routes.py 里，本脚本只负责在 reader-api.py
里插两处「挂钩」：

  1. Reader.__init__ 末尾  -> import sns_routes; sns_routes.install(self)
  2. do_GET 的 else: 之前   -> 6 条 /api/v1/sns/* 路由

补丁是**幂等**的：已经打过就跳过，可以反复执行。原文件会先备份成
reader-api.py.bak-<时间戳>。

用法
----
    python patch-reader.py                 # 自动找同目录下的 reader-api.py
    python patch-reader.py <reader-api.py> # 指定路径
    python patch-reader.py --check         # 只检查，不写入
"""

import argparse
import pathlib
import re
import shutil
import sys
import time

# ---------------------------------------------------------------- 两处挂钩

INIT_ANCHOR = "        for connection in connections:\n            connection.close()\n"

INIT_BLOCK = """
        # --- 朋友圈只读路由（由 patch-reader.py 注入；逻辑在 sns_routes.py）---
        # 放在 try 里：朋友圈读不了不应该拖垮整个 reader 进程。
        try:
            import sns_routes
            sns_routes.install(self)
        except Exception as error:
            self.sns_error = '%s: %s' % (type(error).__name__, error)
"""

GET_ANCHOR = """                else:
                    self.respond({'success': False, 'error': 'Not found'}, 404)"""

GET_BLOCK = """                elif url.path == '/api/v1/sns/timeline':
                    self.respond({'success': True, 'posts': reader.sns_timeline(limit)})
                elif url.path == '/api/v1/sns/mine':
                    self.respond(dict({'success': True}, **reader.sns_mine(limit)))
                elif url.path == '/api/v1/sns/usernames':
                    self.respond(dict({'success': True}, **reader.sns_usernames()))
                elif url.path == '/api/v1/sns/stats':
                    self.respond(dict({'success': True}, **reader.sns_stats()))
                elif url.path == '/api/v1/sns/schema':
                    self.respond(dict({'success': True}, **reader.sns_schema()))
                elif url.path == '/api/v1/sns/debug':
                    self.respond(dict({'success': True}, **reader.sns_debug()))
                else:
                    self.respond({'success': False, 'error': 'Not found'}, 404)"""

MARK_INIT = "sns_routes.install("
MARK_GET = "/api/v1/sns/timeline"


def find_reader(explicit):
    if explicit:
        return pathlib.Path(explicit)
    here = pathlib.Path(__file__).resolve().parent
    for candidate in (here / "reader-api.py", here.parent / "reader-api.py"):
        if candidate.is_file():
            return candidate
    return None


def patch(text):
    """就地注入两处挂钩。返回 (新文本, 做了什么)"""
    actions = []

    if MARK_INIT in text:
        actions.append("init: 已存在，跳过")
    elif INIT_ANCHOR in text:
        text = text.replace(INIT_ANCHOR, INIT_ANCHOR + INIT_BLOCK, 1)
        actions.append("init: 已注入")
    else:
        actions.append("init: ✗ 找不到锚点（reader-api.py 结构变了？）")

    if MARK_GET in text:
        actions.append("route: 已存在，跳过")
    elif GET_ANCHOR in text:
        text = text.replace(GET_ANCHOR, GET_BLOCK, 1)
        actions.append("route: 已注入")
    else:
        actions.append("route: ✗ 找不到锚点（reader-api.py 结构变了？）")

    return text, actions


def main():
    parser = argparse.ArgumentParser(description="给 reader-api.py 注入朋友圈路由")
    parser.add_argument("path", nargs="?", help="reader-api.py 路径")
    parser.add_argument("--check", action="store_true", help="只检查，不写入")
    args = parser.parse_args()

    target = find_reader(args.path)
    if not target or not target.is_file():
        print("找不到 reader-api.py，请把路径作为参数传入。", file=sys.stderr)
        return 2

    original = target.read_bytes()
    # 保留原有换行风格
    text = original.decode("utf-8")

    new_text, actions = patch(text)
    for line in actions:
        print(" ", line)

    failed = any("✗" in a for a in actions)
    if failed:
        print("\n有锚点没找到，未写入。请确认 reader-api.py 是 WeChatAgent 原版。", file=sys.stderr)
        return 1

    if new_text == text:
        print("\n已经是最新状态，无需改动。")
        return 0

    if args.check:
        print("\n--check：需要打补丁，但未写入。")
        return 0

    backup = target.with_suffix(target.suffix + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(target, backup)
    target.write_text(new_text, encoding="utf-8")
    print("\n已写入 %s" % target)
    print("备份    %s" % backup)
    print("\n下一步：重启 WeChatAgent 的 reader 进程，然后验证")
    print("  curl -H 'Authorization: Bearer <token>' http://127.0.0.1:5031/api/v1/sns/stats")
    return 0


if __name__ == "__main__":
    sys.exit(main())
