"""朋友圈（SNS）只读路由 —— 独立模块，避免每次 reader-api.py 被覆盖就丢失。

reader-api.py 里只需两处挂钩：

    import sns_routes
    ...
    sns_routes.install(reader)          # Reader 初始化之后

    # do_GET 的 elif 链里
    elif url.path == '/api/v1/sns/timeline':
        self.respond({'success': True, 'posts': reader.sns_timeline(limit)})
    elif url.path == '/api/v1/sns/stats':
        self.respond(dict({'success': True}, **reader.sns_stats()))

数据来源：`<account>/db_storage/sns/sns.db`。

**必须在 reader 进程内读** —— 微信进程持有锁，外部直连会报
`sqlcipher_page_cipher: hmac check failed for pgno=1` 或 `file is not a database`。
reader 启动时已经用 DPAPI 解出 passphrase 并通过 verify，这里直接复用。

**不依赖 nt_decrypt 里的 SNS 辅助函数** —— 那些函数（get_sns_timeline /
get_sns_usernames / parse_sns_content）在上游更新时会被删掉，这里自己解析 XML。

两个关键事实（都是踩出来的）：

1. `SnsTimeLine.content` 里存的是 **GBK 字节**，不是 UTF-8。
   按 UTF-8 解会得到乱码，必须按 GBK 解。
2. `tid` 是负数（Snowflake 风格），`ORDER BY tid DESC` 拿到的是**最老**的，
   排序非得用 XML 里的 `<createTime>` 不可。
"""

import re
import time

CACHE_TTL = 30.0

_CDATA_OPEN = '<![CDATA['
_CDATA_CLOSE = ']]>'

_ENTITIES = (
    ('&lt;', '<'), ('&gt;', '>'), ('&quot;', '"'),
    ('&apos;', "'"), ('&amp;', '&'),
)


def _to_bytes(blob):
    if isinstance(blob, (bytes, bytearray)):
        return bytes(blob)
    return str(blob).encode('utf-8', 'surrogateescape')


def _as_text(blob):
    """先按 UTF-8 严格解；不合法再退回 GBK。

    同一个库里两种编码都存在（老动态是 GBK，新动态是 UTF-8），
    所以不能写死一种。GBK 中文几乎不可能是合法 UTF-8，用严格解码做判别很可靠。
    """
    if isinstance(blob, str):
        return blob
    raw = _to_bytes(blob)
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError:
        return raw.decode('gbk', 'ignore')


def _unescape(value):
    value = (value or '').strip()
    if value.startswith(_CDATA_OPEN) and value.endswith(_CDATA_CLOSE):
        value = value[len(_CDATA_OPEN):-len(_CDATA_CLOSE)]
    for src, dst in _ENTITIES:
        value = value.replace(src, dst)
    return value.strip()


def _tag(text, name):
    match = re.search(r'<%s>(.*?)</%s>' % (name, name), text, re.S)
    return match.group(1) if match else ''


def parse_content(blob):
    """从 SnsDataItem/TimelineObject XML 里取 createTime / 正文 / 图片数。"""
    if not blob:
        return {'createTime': 0, 'content': '', 'mediaCount': 0}
    text = _as_text(blob)
    try:
        created = int(_tag(text, 'createTime'))
    except (TypeError, ValueError):
        created = 0
    return {
        'createTime': created,
        'content': _unescape(_tag(text, 'contentDesc')),
        'mediaCount': text.count('<media>'),
    }


def install(reader):
    """给 reader 对象补 SNS 方法。重复调用安全。"""
    if getattr(reader, '_sns_installed', False):
        return reader

    import nt_decrypt as nt
    from nt_common import derive_database_key

    reader.sns_db = reader.account / 'db_storage' / 'sns' / 'sns.db'
    reader._sns_cache = {}
    reader._sns_installed = True

    # ---------------- 基础 ----------------

    def _cursor(raw=True):
        """打开 sns.db，返回 (conn, cursor)。

        密钥要按**这个文件自己的**文件头 salt 派生 —— 直接拿配置里那份
        key/salt 去开，只有 message_0.db 对得上。

        raw=True 时 text_factory=bytes，因为 content 列是 GBK 字节，
        必须先拿到原始字节再按 GBK 解码。
        """
        if not reader.sns_db.exists():
            raise RuntimeError('sns.db 不存在：%s' % reader.sns_db)
        key, salt = derive_database_key(
            str(reader.sns_db), '', '', reader.passphrase
        )
        conn, cur = nt.connect_nt_db(str(reader.sns_db), key, salt)
        if raw:
            conn.text_factory = bytes
        return conn, cur

    def _text(value):
        if isinstance(value, (bytes, bytearray)):
            return _as_text(value)
        return value or ''

    def _tables(cur):
        return {_text(row[0]) for row in cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table';").fetchall()}

    def _own():
        return getattr(reader, 'own_wxid', None) or ''

    def _cached(key, fn):
        item = reader._sns_cache.get(key)
        if item and (time.monotonic() - item[0]) < CACHE_TTL:
            return item[1]
        value = fn()
        reader._sns_cache[key] = (time.monotonic(), value)
        return value

    # ---------------- 路由 ----------------

    def sns_usernames():
        """好友 wxid 列表（SnsTopItem_1 的 username 列）。"""
        def load():
            conn, cur = _cursor()
            try:
                if 'SnsTopItem_1' not in _tables(cur):
                    return []
                rows = cur.execute(
                    'SELECT DISTINCT username FROM SnsTopItem_1 '
                    'WHERE username IS NOT NULL;'
                ).fetchall()
                names = [_text(r[0]) for r in rows if _text(r[0])]
            finally:
                conn.close()
            own = _own()
            if own and own not in names:
                names.append(own)
            return names
        return _cached('usernames', load)

    def sns_timeline(limit=100):
        """朋友圈时间线，按 createTime 倒序。"""
        conn, cur = _cursor()
        try:
            if 'SnsTimeLine' not in _tables(cur):
                return []
            rows = cur.execute(
                'SELECT tid, user_name, content FROM SnsTimeLine;'
            ).fetchall()
        finally:
            conn.close()

        posts = []
        for tid, user_name, blob in rows:
            parsed = parse_content(blob)
            posts.append({
                'tid': str(tid),
                'username': _text(user_name),
                'content': parsed['content'],
                'create_time': parsed['createTime'],
                'createTime': parsed['createTime'],
                'media_count': parsed['mediaCount'],
                'mediaCount': parsed['mediaCount'],
            })
        posts.sort(key=lambda p: p['createTime'], reverse=True)
        return posts[:int(limit or 100)]

    def sns_stats():
        """统计。

        **列名不一样**：SnsTopItem_1 用 `username`，SnsTimeLine 用 `user_name`
        —— 写错就 OperationalError。好友数数 SnsTopItem_1，
        动态数和自己的动态数数 SnsTimeLine（SnsTopItem_1 里没有自己的动态）。
        """
        own = _own()
        conn, cur = _cursor(raw=False)
        try:
            tables = _tables(cur)
            total_posts = 0
            my_posts = 0
            if 'SnsTimeLine' in tables:
                total_posts = cur.execute('SELECT COUNT(*) FROM SnsTimeLine;').fetchone()[0]
                if own:
                    my_posts = cur.execute(
                        'SELECT COUNT(*) FROM SnsTimeLine WHERE user_name = ?;',
                        (own,),
                    ).fetchone()[0]
            total_friends = 0
            if 'SnsTopItem_1' in tables:
                total_friends = cur.execute(
                    'SELECT COUNT(DISTINCT username) FROM SnsTopItem_1 '
                    'WHERE username IS NOT NULL;'
                ).fetchone()[0]
        finally:
            conn.close()
        return {
            'totalPosts': total_posts,
            'totalFriends': total_friends,
            'myPosts': my_posts,
            'dbPath': str(reader.sns_db),
        }

    def sns_mine(limit=50):
        """自己发的动态 + 其下的评论，用于回复评论流程。

        三个坑，全部踩过：
        1. 时间线函数不返回 tid，没法跟评论表关联 —— 所以这里直接查表。
        2. `tid` 是负数（Snowflake 风格），`ORDER BY tid DESC` 拿到的是**最老**的，
           排序必须用 XML 里的 createTime。
        3. 评论在 **SnsMessage_tmp3**，`feed_id` 就是动态的 `tid`；
           `content` 为空的行是**点赞**，不是评论。
        """
        own = _own()
        if not own:
            return {'posts': [], 'comments': []}
        conn, cur = _cursor()
        try:
            rows = cur.execute(
                'SELECT tid, user_name, content FROM SnsTimeLine WHERE user_name = ?;',
                (own,),
            ).fetchall()

            posts = []
            for tid, user_name, blob in rows:
                parsed = parse_content(blob)
                posts.append({
                    'tid': str(tid),
                    'username': _text(user_name),
                    'content': parsed['content'],
                    'createTime': parsed['createTime'],
                    'mediaCount': parsed['mediaCount'],
                })
            posts.sort(key=lambda p: p['createTime'], reverse=True)
            posts = posts[:int(limit or 50)]

            comments = []
            if 'SnsMessage_tmp3' in _tables(cur):
                for post in posts:
                    for r in cur.execute(
                        'SELECT from_username, from_nickname, content, create_time, '
                        'comment_id, is_relative_me FROM SnsMessage_tmp3 '
                        'WHERE feed_id = ? ORDER BY create_time;',
                        (post['tid'],),
                    ).fetchall():
                        body = _text(r[2])
                        comments.append({
                            'feedId': post['tid'],
                            'postContent': post['content'][:80],
                            'fromUsername': _text(r[0]),
                            'fromNickname': _text(r[1]),
                            'content': body,
                            'isLike': not body.strip(),
                            'createTime': r[3],
                            'commentId': r[4],
                            'isRelativeMe': r[5],
                        })
            return {'posts': posts, 'comments': comments}
        finally:
            conn.close()

    def sns_schema():
        """表名 / 列名 / 行数，用于排查字段名变动。"""
        conn, cur = _cursor(raw=False)
        try:
            tables = [_text(r[0]) for r in cur.execute(
                "SELECT name FROM sqlite_master WHERE type='table';").fetchall()]
            out = {}
            for table in tables:
                cols = [r[1] for r in cur.execute(
                    'PRAGMA table_info([%s]);' % table).fetchall()]
                n = cur.execute('SELECT COUNT(*) FROM [%s];' % table).fetchone()[0]
                out[table] = {'rows': n, 'columns': cols}
            return out
        finally:
            conn.close()

    def sns_debug():
        """评论表取样：看 feed_id 到底长什么样、能不能对上 tid。"""
        conn, cur = _cursor()
        try:
            msgs = cur.execute(
                'SELECT feed_id, from_username, from_nickname, content, create_time '
                'FROM SnsMessage_tmp3 ORDER BY create_time DESC LIMIT 8;'
            ).fetchall()
            recent = cur.execute(
                'SELECT tid, user_name, content FROM SnsTimeLine LIMIT 8;'
            ).fetchall()
            return {
                'messages': [[_text(v) for v in row] for row in msgs],
                'recent': [
                    {
                        'tid': str(t),
                        'username': _text(u),
                        'createTime': parse_content(c)['createTime'],
                        'content': parse_content(c)['content'][:40],
                    }
                    for t, u, c in recent
                ],
            }
        finally:
            conn.close()

    reader.sns_usernames = sns_usernames
    reader.sns_timeline = sns_timeline
    reader.sns_stats = sns_stats
    reader.sns_mine = sns_mine
    reader.sns_schema = sns_schema
    reader.sns_debug = sns_debug
    return reader
