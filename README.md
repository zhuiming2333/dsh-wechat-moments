# wechat-moments for DSH

> **开源地址：[github.com/zhuiming2333/dsh-wechat-moments](https://github.com/zhuiming2333/dsh-wechat-moments)** （MIT）
>
> 这里只是打包快照，最新版、issue、更新都以仓库为准。
> 懒得看文档？直接跳到 [INSTALL.md](INSTALL.md) 跑一条命令。

给 [DeepSeek-Harness](https://github.com/deepseek-ai)（DSH）用的**微信朋友圈**插件 + 技能包。

装完你能在对话里直接说：

- 「**看看我朋友圈有什么**」 → 读时间线
- 「**发条朋友圈，配这张图**」 → 自动点微信 UI，发出去
- 「**有没有人评论我**」 → 列出待回复评论
- 「**回一下那条评论**」 → 自动定位、输入、发送

发帖和回复走**桌面 UI 自动化**（PowerShell + Win32 + Windows OCR），读数据走
**WeChatAgent 的 reader API**（解密后的本地 SQLCipher 库）。

---

## 它长什么样

| 工具 | 做什么 | 走哪条路 |
|---|---|---|
| `wechat_moments_feed` | 读朋友圈时间线 | reader API（只读） |
| `wechat_moments_comments` | 列出待回复评论 | reader API（只读） |
| `wechat_moments_post` | 发一条带图朋友圈 | UI 自动化（30–90 秒，异步） |
| `wechat_moments_reply` | 回复某条评论 | UI 自动化（30–90 秒，异步） |
| `wechat_moments_job` | 查异步任务进度 | 本地 job 目录 |

发帖 / 回复是异步的：工具立刻返回 `jobId`，后台跑 PowerShell 脚本，
再用 `wechat_moments_job` 轮询问结果。

---

## 安装

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

**不需要手工改任何文件、填任何 token。** 脚本会自己探测：

1. 扫盘找 WeChatAgent 的 workspace
2. 从 `state\wechat-io-config.json` 读 reader 地址和 token
3. 问 reader 要本账号 wxid
4. 给 `reader-api.py` 注入朋友圈只读路由
5. 装技能脚本到 `~\.dsh\skills\wechat-moments-post`
6. 装插件到 `~\.dsh\profiles\desktop`
7. 写共享配置 `~\.dsh\wechat-moments.config.json`
8. 自检三项

装完**重启 WeChatAgent**、**重启 DSH** 就生效。

详细步骤和排错见 [INSTALL.md](INSTALL.md)。

---

## 前置条件

- Windows 10 / 11
- 微信 PC 版 4.1.x，已登录
- WeChatAgent 已安装且 reader API 在 `5031` 端口活着
- DSH 桌面端至少启动过一次

---

## 设计要点（踩过坑的地方）

### 窗口尺寸不写死
发帖前把微信主窗口统一成 980×900（屏幕小时按工作区自动缩），所有坐标在运行时
`GetWindowRect` 现算。换一台分辨率不同的机器也能跑。

### 绿色「发表」按钮按连通域找，不按行找
按钮上是**白字**，白字会把绿色横条切成碎段 —— 按「最长绿色 run」扫永远扫不到，
于是回退到猜坐标，就会点歪点到图片上。改成 4px 网格 + BFS 连通域，白字被网格跨过去。

### 相册窗口不属于 Weixin 进程
「我的朋友圈」相册是 CEF 渲染的，class 是 `Chrome_WidgetWin_0`，属于 `WeChatAppEx`
进程，标题还是「微信」。按「Weixin 进程 + Qt51514 class + 标题=朋友圈」过滤永远找不到。

### 资料卡是独立顶层窗口，有两种尺寸
328×335 和 492×503 都会出现。尺寸上限设窄了会把大卡滤掉，导致「以为卡没弹出 →
再点头像 → 把卡关掉」的死循环。

### 回复入口是「昵称右边、时间戳左边」那块空白
点昵称会弹个人资料卡（错），点时间戳没反应（错），点两者之间的空白才弹回复框。

### 安全闸：占位字必须对得上才发
回复框弹出后占位字是 `回复 <显示名>`。脚本拿它和目标显示名比相似度，不够就
**一个字都不发**、直接退出。宁可不回，也不能回到别人头上。

### 显示名 ≠ 数据库昵称
DB 里叫 `真由理`，界面上印的是备注名 `南华`。按 DB 昵称去界面找永远找不到，
所以先调 `/api/v1/contacts` 拿 `displayName` 再定位。

### 永远不要发 Esc
按 Esc 会把微信整片窗口关掉，白屏重启，正在跑的流程全废。

### DSH 在 Windows 作业对象里
`spawn(..., {detached: true})` 的子进程一创建就被回收（spawn 报成功、进程从未运行）。
必须两层派发：`spawn` → `powershell -Command` → `Start-Process`。

---

## 目录结构

```
setup.ps1                    一键安装（自动探测，无占位符）
INSTALL.md                   详细安装说明 + 6 类常见问题
注意事项.md                   使用前必读的坑
plugin/                      DSH 插件
  package.json
  cordis.patch.yml
  lib/index.js               5 个工具 + 异步 job 派发
  lib/runner.ps1             调 skill 脚本的薄壳
reader/                      给 WeChatAgent 的 reader 补丁
  patch-reader.py            幂等注入，锚点不匹配时拒绝写入
  sns_routes.py              自包含的 SNS 只读路由
skills/wechat-moments-post/  PowerShell 技能脚本
  wechat-moments-post.ps1    发帖
  wechat-moments-reply.ps1   回复评论
  moments-inbox.ps1          看有没有人评论
  bili-share-to-moments.ps1  把 B 站视频发朋友圈
  wx_ocr_probe.ps1           OCR 窗口文字
  SKILL.md                   技能说明（给模型看）
```

---

## 为什么读数据还要依赖 WeChatAgent

`sns.db` 是 SQLCipher 加密的，密钥由 WeChatAgent 用 Windows DPAPI 解出
（`decryptKey = "userdpapi:..."`），再在它自己的 Python 进程里解密分页读取。

**写**（发帖 / 回复）完全不依赖它 —— 那是纯 UI 自动化。

想彻底去掉这个依赖，需要在 Node 里重做 SQLCipher 分页解密
（`PRAGMA key = "x'<key_hex><salt_hex>'"`，密钥 =
`PBKDF2-HMAC-SHA512(passphrase, salt, 256000, 32)`）+ DPAPI 绑定。当前没做。

---

## 已知限制

- **正文短于 4 字的动态**在相册里没法靠正文定位，脚本直接报错退出（不盲目滚动）。
- **界面已无但 DB 还有的评论**：脚本会在详情页滚 8 段后放弃，不会错发。
- 评论者的显示名如果被 OCR 读成 1 个字（如「源」→「0」），定位会退化到按正文兜底。
- 依赖中文 OCR，非中文界面未测。

---

## License

MIT
