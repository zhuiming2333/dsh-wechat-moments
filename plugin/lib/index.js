/**
 * dsh-wechat-moments — 微信朋友圈插件
 *
 * 两条完全不同的通道，刻意分开：
 *
 *   读（feed / comments）  直连 WeChatAgent 的 reader API（本机 5031），
 *                          毫秒级返回，不碰桌面，永远不会打断正在用电脑的人。
 *
 *   写（post / reply）     微信桌面版的发布/评论没有可用接口，只能驱动 UI。
 *                          一轮要跑 30-90 秒（找窗口 → OCR 读屏 → 点击 → 校验），
 *                          远超一次工具调用的合理时长，所以这里只负责派发：
 *                          立刻返回 jobId，后台 PowerShell 子进程干活，
 *                          用 wechat_moments_job 查进度和结果。
 *
 * 写操作的实现全部复用已经真机验证过的 skill 脚本，插件本身不重复实现 UI 细节。
 *
 * @module dsh-wechat-moments
 */
import { defineTool } from '@deepseek-ai/dsh-tools'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import z from '@deepseek-ai/schemastery'

/** Stable Loader identity. */
const name = 'dsh-wechat-moments'

/** Tools are the only capability this plugin needs. */
const inject = ['tools']

/**
 * Shared config written by the installer's setup.ps1. Keeping every path,
 * token and wxid here means the same package runs unedited on any machine.
 */
const CONFIG_FILE = join(homedir(), '.dsh', 'wechat-moments.config.json')

function readSharedConfig() {
	for (const file of [CONFIG_FILE, join(process.cwd(), 'wechat-moments.config.json')]) {
		try {
			if (!existsSync(file)) continue
			return JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, ''))
		} catch { /* try the next candidate */ }
	}
	return {}
}

const SHARED = readSharedConfig()

/** This account's wxid; comments written by it are our own and never replied to. */
const OWN_WXID = String(SHARED.ownWxid || '')

/** The reply skill's ledger of already-answered comments. */
const REPLY_LEDGER = SHARED.workspace
	? join(SHARED.workspace, 'state', 'moments-replies.json')
	: join(homedir(), '.dsh', 'moments-replies.json')

const Config = z.object({
	/** WeChatAgent reader API base URL. */
	readerUrl: z.string().default(String(SHARED.readerUrl || 'http://127.0.0.1:5031')),
	/** Reader bearer token (lives in state/wechat-io-config.json as reader_token). */
	readerToken: z.string().default(String(SHARED.readerToken || '')),
	/** Directory holding wechat-moments-post.ps1 / wechat-moments-reply.ps1. */
	skillDir: z.string().default(String(SHARED.skillDir || join(homedir(), '.dsh', 'skills', 'wechat-moments-post'))),
	/** How many finished jobs to keep on disk. */
	jobRetention: z.number().default(40),
	/** Seconds a job may run before we call it stuck. */
	jobTimeoutSec: z.number().default(300)
})

// ---------------------------------------------------------------- reader API

function readerFetch(config, path, params = {}, timeoutMs = 12000) {
	const qs = new URLSearchParams()
	for (const [key, value] of Object.entries(params)) {
		if (value !== undefined && value !== null && value !== '') qs.set(key, String(value))
	}
	const suffix = qs.toString() ? `?${qs}` : ''
	const url = `${config.readerUrl.replace(/\/+$/, '')}${path}${suffix}`
	const controller = new AbortController()
	const timer = setTimeout(() => controller.abort(), timeoutMs)
	return fetch(url, {
		headers: { Authorization: `Bearer ${config.readerToken}` },
		signal: controller.signal
	})
		.then(async response => {
			clearTimeout(timer)
			const text = await response.text()
			if (!response.ok) throw new Error(`reader ${path} -> HTTP ${response.status}: ${text.slice(0, 200)}`)
			try {
				return JSON.parse(text)
			} catch {
				throw new Error(`reader ${path} returned non-JSON: ${text.slice(0, 200)}`)
			}
		})
		.catch(error => {
			clearTimeout(timer)
			if (error.name === 'AbortError') {
				throw new Error(`reader 超时（${timeoutMs}ms）。WeChatAgent 可能没在运行，或 reader 端口不是 ${config.readerUrl}。`)
			}
			if (error.message?.startsWith('reader ')) throw error
			throw new Error(`连不上 reader（${config.readerUrl}）：${error.message}。确认 WeChatAgent 在跑。`)
		})
}

function clip(value, max) {
	if (typeof value !== 'string') return value ?? ''
	return value.length <= max ? value : `${value.slice(0, max)}…`
}

function fmtTime(seconds) {
	if (!seconds) return '未知时间'
	return new Date(seconds * 1000).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false })
}

/**
 * The SNS timeline stores wxids, not names. `/api/v1/contacts` resolves a wxid
 * to the name WeChat actually prints, which is normally the remark name rather
 * than the nickname — so this is the only thing that matches what a person sees
 * on screen. Results are cached for the process lifetime: names rarely change
 * and the map keeps a 10-post feed at one round trip per stranger.
 */
const nameCache = new Map()

async function resolveName(config, username) {
	if (!username) return ''
	if (nameCache.has(username)) return nameCache.get(username)
	let name = ''
	try {
		const data = await readerFetch(config, '/api/v1/contacts', { keyword: username, limit: 5 }, 6000)
		const hit = (data.contacts ?? []).find(contact => contact.username === username)
		name = hit?.displayName ?? ''
	} catch {
		/* a name lookup failure must never take the feed down */
	}
	nameCache.set(username, name)
	return name
}

async function resolveNames(config, usernames) {
	const unique = [...new Set(usernames.filter(Boolean))]
	await Promise.all(unique.slice(0, 20).map(username => resolveName(config, username)))
	return username => nameCache.get(username) || username
}

function fmtFeedLine(post, index, lookup) {
	const body = clip((post.content ?? '').replace(/\s+/g, ' ').trim(), 160) || '（无正文）'
	const media = post.mediaCount ?? post.media_count ?? 0
	const mediaNote = media ? ` [${media} 张图]` : ''
	const who = lookup(post.username)
	return `${index + 1}. ${who} · ${fmtTime(post.createTime ?? post.create_time)}${mediaNote}\n   ${body}`
}

// --------------------------------------------------------------------- jobs

const jobRoot = () => join(homedir(), '.dsh', 'wechat-moments-jobs')

function jobDirOf(jobId) {
	return join(jobRoot(), jobId)
}

function pruneJobs(retention) {
	const root = jobRoot()
	if (!existsSync(root)) return
	let entries
	try {
		entries = readdirSync(root)
			.map(id => ({ id, path: join(root, id) }))
			.filter(entry => {
				try {
					return statSync(entry.path).isDirectory()
				} catch {
					return false
				}
			})
			.map(entry => {
				try {
					return { ...entry, mtime: statSync(entry.path).mtimeMs }
				} catch {
					return { ...entry, mtime: 0 }
				}
			})
			.sort((a, b) => b.mtime - a.mtime)
	} catch {
		return
	}
	for (const entry of entries.slice(Math.max(1, retention))) {
		try {
			rmSync(entry.path, { recursive: true, force: true })
		} catch {
			/* a running job's directory may be locked; skip it */
		}
	}
}

function readJob(jobId) {
	const dir = jobDirOf(jobId)
	if (!existsSync(dir)) return null
	const read = file => {
		try {
			return readFileSync(join(dir, file), 'utf8')
		} catch {
			return ''
		}
	}
	let status = { state: 'unknown' }
	const rawStatus = read('status.json').trim()
	if (rawStatus) {
		try {
			status = JSON.parse(rawStatus)
		} catch {
			/* half-written status: treat as running */
			status = { state: 'running' }
		}
	}
	const meta = (() => {
		const raw = read('meta.json').trim()
		if (!raw) return {}
		try {
			return JSON.parse(raw)
		} catch {
			return {}
		}
	})()
	const log = read('output.log')
	const startedAt = meta.startedAt ? Date.parse(meta.startedAt) : 0
	const ageSec = startedAt ? (Date.now() - startedAt) / 1000 : 0
	return { status, meta, log, ageSec }
}

function startJob(config, action, args) {
	pruneJobs(config.jobRetention)
	const jobId = `${action}-${randomUUID().slice(0, 8)}`
	const dir = jobDirOf(jobId)
	mkdirSync(dir, { recursive: true })
	const meta = { jobId, action, args, startedAt: new Date().toISOString(), skillDir: config.skillDir }
	writeFileSync(join(dir, 'meta.json'), JSON.stringify(meta, null, 2), 'utf8')
	writeFileSync(join(dir, 'status.json'), JSON.stringify({ state: 'queued', exitCode: 0, message: '', updatedAt: new Date().toISOString() }), 'utf8')

	// Args go through a file, never argv. PowerShell strips the double quotes out
	// of an argv JSON string, so ConvertFrom-Json then dies on `Invalid JSON
	// primitive`; writing UTF-8 to disk sidesteps quoting and the ANSI code page
	// entirely.
	writeFileSync(join(dir, 'args.json'), JSON.stringify({ ...args, skillDir: config.skillDir }, null, 2), 'utf8')

	const runner = join(import.meta.dirname ?? new URL('.', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'), 'runner.ps1')
	if (!existsSync(runner)) throw new Error(`runner.ps1 缺失：${runner}`)

	// Two-layer dispatch. DSH runs this process inside a Windows job object, and
	// a plain child dies with the tool call that started it — the job reports
	// success, the runner writes nothing, and the job sits at `queued` forever.
	// Handing the launch to Start-Process puts the runner outside that job, so it
	// survives after the tool returns.
	const launcher = [
		`Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(`,
		`'-NoProfile','-ExecutionPolicy','Bypass','-File',`,
		`'${runner.replace(/'/g, "''")}',`,
		`'-JobDir','${dir.replace(/'/g, "''")}',`,
		`'-Action','${action}'`,
		`)`,
	].join(' ')
	const child = spawn(
		'powershell',
		['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', launcher],
		{ stdio: 'ignore', windowsHide: true }
	)
	child.on('error', (error) => {
		writeFileSync(join(dir, 'status.json'), JSON.stringify({
			state: 'failed', exitCode: -1, message: `runner 启动失败: ${error.message}`, updatedAt: new Date().toISOString()
		}), 'utf8')
	})
	return { jobId, dir }
}

function renderJob(view) {
	const { status, meta, log, ageSec } = view
	const head = `job ${meta.jobId ?? '?'} · ${meta.action ?? '?'} · ${status.state}${status.exitCode ? ` (exit ${status.exitCode})` : ''} · ${ageSec.toFixed(0)}s`
	const args = meta.args && Object.keys(meta.args).length ? `\n参数: ${JSON.stringify(meta.args)}` : ''
	const body = log.trim() ? `\n\n${clip(log.trim(), 3000)}` : status.message ? `\n\n${status.message}` : ''
	return `${head}${args}${body}`
}

// ------------------------------------------------------------------- tools

/**
 * Every tool answers with exactly one text block. The output contract is
 * declared rather than implied: a tool that returns a value its declared schema
 * does not describe is rejected when the result is projected, which would throw
 * away work that had already been done.
 */
const TEXT_OUTPUT = {
	schema: {
		type: 'object',
		additionalProperties: false,
		properties: { text: { type: 'string', required: true } }
	},
	render: (_args, value) => [{ type: 'text', text: value.text }]
}

/** Shape one answer for TEXT_OUTPUT. */
function text(value) {
	return { text: String(value) }
}

function feedTool(config) {
	return defineTool({
		name: 'wechat_moments_feed',
		description: [
			'刷微信朋友圈，按时间倒序返回好友动态（发布者、时间、正文、图片数、tid）。',
			'只读 WeChatAgent reader API，不碰桌面，不会打扰正在用电脑的人。',
			'用于「看看朋友圈」「朋友圈有什么」「谁发了什么」。'
		].join(' '),
		parameters: {
			count: { type: 'integer', description: '返回几条，默认 10，最多 50。' },
			keyword: { type: 'string', description: '只留正文包含该关键字的动态。' }
		},
		output: TEXT_OUTPUT,
		async execute(args) {
			const limit = Math.min(Math.max(Number(args.count) || 10, 1), 50)
			const data = await readerFetch(config, '/api/v1/sns/timeline', { limit, offset: 0 })
			let posts = Array.isArray(data.posts) ? data.posts : []
			const keyword = (args.keyword ?? '').trim()
			if (keyword) posts = posts.filter(post => String(post.content ?? '').includes(keyword))
			if (!posts.length) {
				return text(keyword ? `朋友圈里没有正文包含「${keyword}」的动态。` : '朋友圈暂时没有动态。')
			}
			const shown = posts.slice(0, limit)
			const lookup = await resolveNames(config, shown.map(post => post.username))
			const lines = shown.map((post, index) => fmtFeedLine(post, index, lookup))
			return text(`朋友圈最新 ${lines.length} 条：\n\n${lines.join('\n\n')}`)
		}
	})
}

function commentsTool(config) {
	return defineTool({
		name: 'wechat_moments_comments',
		description: [
			'列出自己朋友圈动态下**还没有回复**的评论，带动态 id、评论 id、谁说的、说了什么。',
			'只读 reader API，不动桌面。拿到的 objectId + commentId 可以直接喂给 wechat_moments_reply。',
			'用于「看看朋友圈有没有人评论」「谁评论了」。'
		].join(' '),
		parameters: {
			count: { type: 'integer', description: '最多列几条，默认 20，最多 50。' },
			posts: { type: 'integer', description: '扫自己最近几条动态，默认 5，最多 20。' }
		},
		output: TEXT_OUTPUT,
		async execute(args) {
			const postCount = Math.min(Math.max(Number(args.posts) || 5, 1), 20)
			const limit = Math.min(Math.max(Number(args.count) || 20, 1), 50)
			const data = await readerFetch(config, '/api/v1/sns/mine', { limit: postCount })
			const posts = Array.isArray(data.posts) ? data.posts : []
			const comments = Array.isArray(data.comments) ? data.comments : []
			const byTid = new Map(posts.map(post => [String(post.tid), post]))

			const pending = comments.filter(comment => {
				if (comment.isLike) return false
				// OWN_WXID comes from the shared config; empty means "unknown", not "matches everything".
				if (OWN_WXID && comment.fromUsername === OWN_WXID) return false
				return String(comment.content ?? '').trim().length > 0
			})

			const ledger = readReplyLedger()
			const fresh = pending.filter(comment => !ledger.has(`${comment.feedId}:${comment.commentId}`))

			if (!fresh.length) {
				return text(`最近 ${posts.length} 条动态下没有待回复的评论（已回的不再列）。`)
			}
			const lines = fresh.slice(0, limit).map((comment, index) => {
				const post = byTid.get(String(comment.feedId))
				const postBody = clip((post?.content ?? comment.postContent ?? '').replace(/\s+/g, ' ').trim(), 60) || '（无正文）'
				return `${index + 1}. ${comment.fromNickname ?? comment.fromUsername}：${clip(String(comment.content ?? '').trim(), 120)}\n   动态：${postBody}\n   objectId=${comment.feedId}  commentId=${comment.commentId}`
			})
			return text(`待回复 ${fresh.length} 条（已回过的自动跳过）：\n\n${lines.join('\n\n')}\n\n回复用 wechat_moments_reply，传 objectId 和 commentId。`)
		}
	})
}

/**
 * The reply skill keeps a ledger of what it already answered, keyed
 * `<feedId>:<commentId>`. Reading it here keeps the pending list honest without
 * asking the UI anything. The file is written with a UTF-8 BOM, which
 * JSON.parse rejects, so strip it before parsing.
 */
function readReplyLedger() {
	const answered = new Set()
	try {
		const data = JSON.parse(readFileSync(REPLY_LEDGER, 'utf8').replace(/^\uFEFF/, ''))
		for (const key of Object.keys(data)) answered.add(key)
	} catch {
		/* an unreadable ledger just means nothing is filtered out */
	}
	return answered
}

function postTool(config) {
	return defineTool({
		name: 'wechat_moments_post',
		description: [
			'发一条带图的朋友圈。微信发布没有接口，只能驱动桌面 UI，一轮 30-90 秒。',
			'所以这里**立刻返回 jobId**，不阻塞对话；随后用 wechat_moments_job 查结果。',
			'注意：执行期间会真的操作鼠标键盘，请不要同时使用这台电脑。图片必须给本机绝对路径。'
		].join(' '),
		parameters: {
			image: { type: 'string', required: true, description: '配图的本机绝对路径（jpg/png）。朋友圈必须带图。' },
			text: { type: 'string', description: '配文。可以留空，但带一句话更好。' },
			dryRun: { type: 'boolean', description: '只演练坐标流程，不真的点「发表」。' }
		},
		output: TEXT_OUTPUT,
		async execute(args) {
			const image = String(args.image ?? '').trim()
			if (!image) throw new Error('image 必填：朋友圈必须配一张图。')
			if (!existsSync(image)) throw new Error(`图片不存在：${image}`)
			const { jobId } = startJob(config, 'post', { image, text: args.text ?? '', dryRun: args.dryRun === true })
			return text(`已派发发朋友圈任务：${jobId}\n后台正在驱动微信界面，约 30-90 秒。用 wechat_moments_job jobId=${jobId} 查结果。`)
		}
	})
}

function replyTool(config) {
	return defineTool({
		name: 'wechat_moments_reply',
		description: [
			'回复自己朋友圈动态下的某一条评论。同样要驱动桌面 UI，一轮 30-90 秒，所以立刻返回 jobId。',
			'objectId / commentId 从 wechat_moments_comments 拿。脚本会校验弹出的回复框写的是不是对的人，对不上就一个字都不发。',
			'执行期间会真的操作鼠标键盘，请不要同时使用这台电脑。'
		].join(' '),
		parameters: {
			objectId: { type: 'string', required: true, description: '动态 id（comments 结果里的 objectId）。' },
			commentId: { type: 'string', required: true, description: '要回复的那条评论 id。' },
			text: { type: 'string', required: true, description: '回复内容。短一点，像人说的话。' },
			dryRun: { type: 'boolean', description: '只走流程到输入框，不真的发送。' }
		},
		output: TEXT_OUTPUT,
		async execute(args) {
			const objectId = String(args.objectId ?? '').trim()
			const commentId = String(args.commentId ?? '').trim()
			// 别叫 text —— 会遮蔽模块顶部的 text() 输出辅助函数。
			const replyText = String(args.text ?? '').trim()
			if (!objectId || !commentId) throw new Error('objectId 和 commentId 都要给，从 wechat_moments_comments 的结果里取。')
			if (!replyText) throw new Error('text 不能为空。')
			const { jobId } = startJob(config, 'reply', { objectId, commentId, text: replyText, dryRun: args.dryRun === true })
			return text(`已派发回复任务：${jobId}\n后台正在驱动微信界面，约 30-90 秒。用 wechat_moments_job jobId=${jobId} 查结果。`)
		}
	})
}

function jobTool(config) {
	return defineTool({
		name: 'wechat_moments_job',
		description: [
			'查一个后台朋友圈任务（发帖 / 回复）的进度和结果，返回状态、日志尾部。',
			'不传 jobId 就列出最近的几个任务。',
			'状态 running 表示还在跑，done 表示成功，failed 表示失败（日志里通常写清了原因）。'
		].join(' '),
		parameters: {
			jobId: { type: 'string', description: '任务 id，wechat_moments_post / reply 返回的那个。不传则列出最近任务。' }
		},
		output: TEXT_OUTPUT,
		async execute(args) {
			const jobId = String(args.jobId ?? '').trim()
			if (!jobId) {
				const root = jobRoot()
				if (!existsSync(root)) return text('还没有任何朋友圈任务。')
				const entries = readdirSync(root)
					.filter(id => {
						try {
							return statSync(join(root, id)).isDirectory()
						} catch {
							return false
						}
					})
					.map(id => ({ id, mtime: statSync(join(root, id)).mtimeMs }))
					.sort((a, b) => b.mtime - a.mtime)
					.slice(0, 10)
				if (!entries.length) return text('还没有任何朋友圈任务。')
				const lines = entries.map(entry => {
					const view = readJob(entry.id)
					return `- ${entry.id}  ${view?.status?.state ?? 'unknown'}  ${view?.meta?.action ?? ''}  ${view ? view.ageSec.toFixed(0) + 's' : ''}`
				})
				return text(`最近 ${lines.length} 个任务：\n${lines.join('\n')}`)
			}

			if (!/^[a-z]+-[0-9a-f]{8}$/.test(jobId)) throw new Error(`jobId 格式不对：${jobId}`)
			const view = readJob(jobId)
			if (!view) throw new Error(`找不到任务 ${jobId}`)
			const timedOut = view.status.state === 'running' && view.ageSec > config.jobTimeoutSec
			const message = renderJob(view) + (timedOut ? `\n\n⚠ 已经跑了 ${view.ageSec.toFixed(0)}s，超过 ${config.jobTimeoutSec}s，可能卡住了。看看微信窗口是不是被别的窗口挡住，或者前台被抢走。` : '')
			if (view.status.state === 'failed') throw new Error(message)
			return text(message)
		}
	})
}

// --------------------------------------------------------------------- life

function apply(ctx, config) {
	ctx.tools.register(feedTool(config))
	ctx.tools.register(commentsTool(config))
	ctx.tools.register(postTool(config))
	ctx.tools.register(replyTool(config))
	ctx.tools.register(jobTool(config))
}

export { Config, apply, inject, name }
