# 安装说明

> **开源地址：[github.com/zhuiming2333/dsh-wechat-moments](https://github.com/zhuiming2333/dsh-wechat-moments)** （MIT）
>
> 这里只是打包快照，最新版、issue、更新都以仓库为准。

整个安装只有一个命令。**不需要手工改任何文件、填任何 token。**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

---

## 它会自动做什么

| 步骤 | 做的事 | 如果失败 |
|---|---|---|
| 1 | 找 WeChatAgent 的 workspace（含 `state\wechat-io-config.json` 的目录） | 用 `-Workspace "路径"` 手动指定 |
| 2 | 从里面读 reader 地址和 token | 用 `-ReaderUrl` / `-ReaderToken` 指定 |
| 3 | 问 reader 要本账号 wxid（`/api/v1/sns/mine`） | 发过朋友圈就能拿到 |
| 4 | 给 `reader-api.py` 注入朋友圈只读路由，放好 `sns_routes.py` | 用 `-NoPatch` 跳过 |
| 5 | 装技能脚本到 `%USERPROFILE%\.dsh\skills\wechat-moments-post` | — |
| 6 | 装 DSH 插件到 `%USERPROFILE%\.dsh\profiles\desktop`（vendor + node_modules） | 用 `-NoProfile` 跳过 |
| 7 | 写共享配置 `%USERPROFILE%\.dsh\wechat-moments.config.json` | — |
| 8 | 自检：reader 路由 / 技能脚本 / 配置文件 三项 | 看最后的红字 |

脚本是**幂等**的，失败修好后可以重复跑。

---

## 前置条件

1. **微信 PC 版**（4.1.x）已登录，且**主窗口**能正常打开。
2. **WeChatAgent** 已安装并运行，reader API 在 `5031` 端口活着。
   自检：`curl -H "Authorization: Bearer <token>" http://127.0.0.1:5031/api/v1/sns/stats`
3. **DSH 桌面端**至少启动过一次（否则没有 `profiles\desktop` 目录）。
4. **微信窗口尺寸不限** —— 发帖脚本会自己把窗口统一成 980×900（屏幕小时按工作区自动缩），
   所有坐标都在运行时现算，不依赖你原来的窗口大小。
5. **屏幕分辨率**建议 ≥ 1280×800；**显示缩放** 100%~150% 都能工作。

---

## 装完之后必须做两件事

1. **重启 WeChatAgent 的 reader 进程**，让第 4 步的补丁生效
   （重启 WeChatAgent 会自己拉起 reader）。
2. **重启 DSH 桌面端**，让插件加载。

然后新开一个对话，说「看看朋友圈」，或直接让我调 `wechat_moments_feed`。

---

## 装完怎么自测

```powershell
# 1. reader 朋友圈路由活没活
$token = (Get-Content "$env:USERPROFILE\.dsh\wechat-moments.config.json" -Raw | ConvertFrom-Json).readerToken
curl.exe -H "Authorization: Bearer $token" http://127.0.0.1:5031/api/v1/sns/stats

# 2. 看有没有待回复的评论（纯只读，不动桌面）
powershell -File "$env:USERPROFILE\.dsh\skills\wechat-moments-post\wechat-moments-reply.ps1" -List
```

第 2 条能列出「本账号: wxid_xxx」和动态列表，就说明配置全部正确。

---

## 常见问题

### `找不到 workspace（含 state\wechat-io-config.json 的目录）`
WeChatAgent 装在非默认位置。找一下这个文件：

```powershell
Get-ChildItem -Path C:\,D:\,E:\ -Filter wechat-io-config.json -Recurse -Depth 4 -ErrorAction SilentlyContinue
```

它的上两级（`...\data\workspace`）就是答案，传给 `-Workspace`。

### `拿不到 reader token`
`state\wechat-io-config.json` 里的 `reader_token` 字段是空的。打开 WeChatAgent
设置页重新生成一次，或手工传给 `-ReaderToken`。

### `补丁失败：✗ 找不到锚点`
说明你的 `reader-api.py` 结构和我们的不一样（WeChatAgent 版本不同）。
补丁脚本会在有 `✗` 时**拒绝写入**，不会弄坏原文件。这种情况：

1. 打开 `reader-api.py`，找到 `Reader.__init__` 的末尾（`for connection in connections: connection.close()` 之后）
2. 手工加一行：`import sns_routes; sns_routes.install(self)`
3. 找到 `do_GET` 里的 `else: self.respond({'success': False, 'error': 'Not found'}, 404)`
4. 在它前面加路由判断——直接抄 `patch-reader.py` 里的 `GET_BLOCK` 常量

### `reader /api/v1/sns/stats 不可用`
补丁打了但 reader 进程没重启。重启 WeChatAgent 即可。

### DSH 里看不到 5 个工具
- 确认 DSH 真的重启过（不是只重载窗口）
- 检查 `%USERPROFILE%\.dsh\profiles\desktop\package.json` 里
  `dsh.profile.bundles` 数组有 `dsh-wechat-moments`
- 检查 `%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml` **不要**也有
  `dsh-wechat-moments` 的 insert（会插两次，报错）

### 发帖点到了图片而不是「发表」
旧版本的已知问题，已经修好：绿色按钮改成 4px 网格连通域检测（不再被白字切断），
并且点击前会验证微信窗口真的在前台。确认你用的是这版 `wechat-moments-post.ps1`。

### 回复发给了别人
安全闸会拦：回复框的占位字必须是「回复 <目标显示名>」，相似度不够就一个字都不发。
如果这类情况频繁出现，多半是界面显示名和 DB 昵称不一样 —— 脚本已经优先用显示名。
