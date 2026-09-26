# 接口：进程、HTTP、`/ubus`、`/cgi-bin/luci` 与内部契约

本文是 molly 对外（和对内）所有接口的权威定义：怎么启动、HTTP 层的通用语义与上限、
三条路由各自的契约、以及接口层与数据层之间那个**唯一的窄接口**。
契约的权威来源与验证方式见 §7；每条契约都有对应的断言，见 [`testing.md`](testing.md)。

## 1. 进程接口

```bash
molly [--listen HOST:PORT] [--docroot PATH] [--menu-dir PATH]
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--listen` | `0.0.0.0:8080` | **只接受数字地址**（`0.0.0.0:8080`、`[::]:8080`）；不做 DNS 解析，主机名直接报错退出 |
| `--docroot` | `/www` | 静态文件根目录；启动时去掉尾部 `/` |
| `--menu-dir` | `/usr/share/luci/menu.d` | LuCI 菜单目录（`*.json`）；同样去尾部 `/` |
| `--luci-cgi` | 空 | 把 `/cgi-bin/luci` 交给子进程执行（如 `/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc`，复刻 uhttpd 的 `ucode_prefix` 接线，ADR 0003 的 T1）。留空 = 用内置的 Odin dispatcher（§5） |
| `-h` / `--help` | — | 打印用法并正常退出 |

- **参数错误**（未知参数、缺参数、地址无法解析、监听失败）：stderr 打印原因 + 用法，**退出码 2**。
- **启动输出**（stdout）：`[molly] 监听 …`、`[molly] docroot: …`、`[molly] menu.d: …`，
  以及一行过渡期警告 `WARN: transitional mode - ubus objects still provided by device rpcd`（决策 7）。
- **信号**：启动即忽略 `SIGPIPE`（客户端提前断开不能让进程被杀，风险 R3）；P2 不处理
  `SIGTERM`/`SIGHUP`（优雅退出与重载属 P3）。
- **多 listener**：当前只支持一个 `--listen`；上游 uhttpd 是 `0.0.0.0` + `::` 双 listener，
  双栈支持待真机确认（风险 R2）。

## 2. HTTP 层的通用契约

### 2.1 状态码

| 码 | 何时出现 |
|---|---|
| 200 | 命中；`/ubus` 的 POST 即使业务报错也回 200（上游在 invoke 前就发了头） |
| 400 | 请求目标不以 `/` 开头、`Content-Length` 非数字、百分号编码非法或解码出控制字符、`/ubus` 用了 GET/POST/OPTIONS 之外的方法 |
| 403 | 规范化后含 `..` 段（路径逃逸） |
| 404 | 静态文件不存在 / 目录无 `index.html`；`/cgi-bin/luci` 未命中菜单；`GET /ubus` 与 `GET /ubus/<非 list\|subscribe>`；`POST /ubus/<非 call>` |
| 405 | 静态文件与 `/cgi-bin/luci` 上的非 GET/HEAD |
| 411 | `Transfer-Encoding: chunked`（不支持），或 POST 无 `Content-Length` |
| 413 | 请求头超 8KB，或 `Content-Length` 超 64KB |
| 500 | `GET /ubus/list` 查询失败（正文是 ubus 自己的错误码，不是 JSON-RPC 码） |
| 501 | 命中菜单但 `action.type` 不是 `view`（`cbi`/`form`/`template`/`function`）；`GET /ubus/subscribe/*` |
| 503 | 并发连接超过 32（响应带 `Connection: close`） |

### 2.2 头语义

- 响应恒带 `Content-Length`（HEAD 也带，只是没有 body）。
- `Content-Type`：静态文件按扩展名（`mime.odin`）；`/ubus` 与占位页分别是
  `application/json`、`text/html; charset=utf-8`。
- `Connection`：HTTP/1.1 默认 `keep-alive`，HTTP/1.0 默认 `close`；超额连接回 `close`。
- keep-alive 下一条连接可承载多个请求，也支持管道（POST 带 body 紧接 GET）。

### 2.3 上限（`src/http/limits.odin`）

| 常量 | 值 | 类别 |
|---|---|---|
| `MAX_HEAD_BYTES` | 8 KiB | 自定（待真机校准，风险 R7） |
| `MAX_HEAD_COUNT` | 64 | 自定 |
| `MAX_BODY_BYTES` | 64 KiB | **契约类**：对齐上游 `UH_UBUS_MAX_POST_SIZE` |
| `MAX_CONNECTIONS` | 32 | 自定；一连接一线程，32 × 128KB 栈 ≈ 4MB |
| `READ_TIMEOUT` / `WRITE_TIMEOUT` | 10 s | 自定；慢客户端不能占住线程槽位 |

## 3. 路由表

`handle`（`src/main.odin`）按下列顺序分派，全部用**带边界的前缀匹配**
（`/ubus` 匹配 `/ubus` 与 `/ubus/…`，但不匹配 `/ubus.html`）：

| 顺序 | 前缀 | 入口 | 备注 |
|---|---|---|---|
| 0 | — | `http.normalize_path` | 400 / 403 在这里终结，之后 handler 才能安全拼路径 |
| 1 | `/ubus` | `handlers.serve_ubus` | 见 §4 |
| 2 | `/cgi-bin/luci` | `handlers.serve_luci` | 见 §5；必须排在静态文件之前，否则真实文件会被抢 |
| 3 | 其余 | `handlers.serve_static` | docroot + path；目录 → 追加 `/index.html`；非普通文件 → 404 |

## 4. `/ubus` 契约

会话：新式取请求头 `Authorization: Bearer <sid>`（大小写不敏感，`ubus.c:120-137`），
旧式取 `params[0]`；两者都缺省时用哨兵 `00000000000000000000000000000000`。
**`ubus_rpc_session` 出现在 `params` 里一律拒绝**（`-32602`），不做剔除（`ubus.c:578-582`）。

### 4.1 GET

| 请求 | 响应 |
|---|---|
| `GET /ubus/list` | 200，正文 `{"<对象路径>":{"<方法名>":{"<参数名>":"<类型>"}}}`；类型只允许 `boolean/number/string/array/object/unknown` 六个取值 |
| `GET /ubus/list/<path>` | 200，正文是该对象的签名（**没有**外层对象名） |
| `GET /ubus/list/<未知>` | **500**，正文 `{"code":<ubus errno>,"message":"<ubus 文案>"}`（`ubus.c:249-253`、`:210-213`） |
| `GET /ubus`、`GET /ubus/<其它>` | 404，空正文 |
| `GET /ubus/subscribe/*` | 501（SSE 需要 uloop 事件线程，决策 8） |

### 4.2 POST：旧式 `POST /ubus`

正文是 JSON-RPC（对象或数组，数组 = 批请求）：

- `{"jsonrpc":"2.0","id":N,"method":"call","params":[sid,对象,方法,参数表]}` →
  `{"jsonrpc":"2.0","id":N,"result":[0,{"echo":{"object":…,"method":…,"sid":…}}]}`；
  ubus 侧非 0 返回码时 `result` 为 `[ret, …]`。
- `{"method":"list"}`（无 params）→ `"result":[路径…]`；带 params 时 → 被查到对象的签名表（查不到的忽略）。
- `id` 原样回显；缺 `id` 回 `null`。
- 正文是标量 / `null` / 非法 JSON → `-32700`；`jsonrpc` 不是 `"2.0"`、缺 `method`、
  `params` 不足四项或类型不符 → `-32700`；未知 `method` → `-32601`。
- 空数组正文 → 回 `[]`。

### 4.3 POST：新式 `POST /ubus/call/<path>`

正文是对象，`method` 直接是 ubus 方法名，路径就是对象：

- 成功 → `{"jsonrpc":"2.0","id":N,"result":{…}}`；无回复数据 → `"result":null`
  （**没有**旧式的外层 `[ret, {...}]`）。
- `params` 必须是对象（`null` 视为失败）→ 否则 `-32602`；无 `params` 时传空参数表。
- **错误优先级**：对象不存在（`-32000`）排在校验参数（`-32602`）之前（对齐上游「先 `ubus_lookup_id` 再校验」）。
- 对象存在但方法未知 → 回 ubus 自己的返回码：`{"code":3,"message":"Method not found"}`。

### 4.4 错误码表

| 触发 | 码 | 文案 |
|---|---|---|
| 正文非法 / 标量 / `jsonrpc` 不符 / `params` 结构不符 | `-32700` | `Parse error` |
| 未知方法 | `-32601` | `Method not found` |
| `params` 不是表、或带 `ubus_rpc_session` | `-32602` | `Invalid parameters` |
| 对象不存在 | `-32000` | `Object not found` |
| 本机故障（连不上 ubus / 内存不足 / 请求发不出去） | `-32603` | `Internal error` |
| ubus 侧非 0 返回码 | 原样 | `{"code":<ret>,"message":"<ubus_error_message(ret)>"}` |

`-32600`（`Invalid request`）在表里有定义，但当前没有路径会回它——`parse_json_rpc` 的初值语义
让这些情形都落到 `-32700`（与上游一致）。

### 4.5 `OPTIONS` 与其它方法

- `OPTIONS /ubus` → 200 + `application/json` + `Content-Length: 0`（CORS 预检）。
- `HEAD`、`PUT`、`DELETE`、其它 → 400（上游 ubus 插件只认 GET/POST/OPTIONS）。

### 4.6 示例

```bash
# 列对象（形状与 `ubus list -v` 对齐）
curl -s http://127.0.0.1:8080/ubus/list

# 旧式：结果恒为 [ret, {...}]
curl -s -X POST http://127.0.0.1:8080/ubus \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","list",{}]}'

# 新式：会话来自 Authorization 头，结果是对象
curl -s -X POST http://127.0.0.1:8080/ubus/call/session \
  -H 'Authorization: Bearer 00000000000000000000000000000000' \
  -d '{"jsonrpc":"2.0","id":1,"method":"list","params":{}}'
```

**已知偏差**：请求体超 64KB 时 molly 回 HTTP 413，而上游 ubus 插件回 200 + `-32700` 并关连接。
这是 HTTP 层的既有决策（`MAX_BODY_BYTES` 是契约类的，映射方式不是）。

## 5. `/cgi-bin/luci` 契约

### 5.1 PATH_INFO

`/cgi-bin/luci` **之后**的部分才是菜单路径（上游 CGI 约定）：

| 请求 | 菜单路径 | 行为 |
|---|---|---|
| `/cgi-bin/luci`、`/cgi-bin/luci/` | `""` | 从菜单树 root 走 `firstchild` |
| `/cgi-bin/luci/admin/status/overview` | `/admin/status/overview` | 逐段下降 |

- 只接受 `GET` / `HEAD`，其它方法 → 405。
- 菜单目录读不到（不存在 / 无权限）→ **全部 404**（不缓存失败，下次请求重试）。
- 尾部 `/` 与查询串在此之前已被 HTTP 层处理掉。

### 5.2 分派结果

| 情况 | 响应 |
|---|---|
| 命中且 `action.type == "view"` | 200 + 占位页（见 §5.3） |
| 命中但 `action.type` 不是 `view`（`cbi` / `form` / `template` / `function` / `call`） | 501，正文 `not implemented: action.type=<t> view=<path> menu=<请求路径>` |
| 未命中（含 `satisfied == false` 的节点） | 404 |

501 的正文**故意带命中信息**：真实 menu.d 里非 `view` 的 action 占相当比例（413 条路径中
`view` 311 / `function` 31 / `alias` 21 / `template` 6 / `call` 1，`firstchild` 43 是中间层），
只回一句 `not implemented` 无法判断落到了哪个节点（真机实测踩过）。渲染这些 action 属 P3-8。

`action` 取自下钻结束后的节点；**有剩余段**（通配层收下 `request_args`）且该节点有
`wildcardaction` 时用它，否则用 `action`（上游 `dispatcher.uc:1006-1011`）。

### 5.3 占位页结构（脚本可断言）

```html
<!DOCTYPE html>…<p class="banner">ACL 未实施：P2 占位页，没有认证与权限校验，P3 由 molly 自持 acl.d 接管</p>
<h1>{title}</h1>
<dl>
  <dt>action.type</dt><dd>{type}</dd>
  <dt>view</dt><dd>{path}</dd>
  <dt>depends (shown, not enforced)</dt><dd>{depends 原文 JSON}</dd>   <!-- 仅当该节点有 depends -->
  <dt>request_args</dt><dd>{args，以 " / " 连接}</dd>                  <!-- 仅当有剩余段 -->
</dl>
```

- `title` 为空时回落到 `action.path`。
- `depends` 只展示**不执行**（ACL 属 P3）；页面上的 `depends.acl` 出现即证明这件事可见。
- 所有插值都做 HTML 转义（`request_args` 是彻头彻尾的客户端输入）。

### 5.5 CGI 模式（`--luci-cgi`，ADR 0003 的 T1）

给了 `--luci-cgi` 时，§5.1–§5.3 的**内置 dispatcher 不再参与**：整个 `/cgi-bin/luci` 前缀按
CGI 规范交给子进程（设备上是 `/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc`），方法不限，
由脚本自己判定。

**请求 → 环境变量**（`src/handlers/cgi_exec.odin` 的 `build_cgi_env`）：

| 变量 | 取值 |
|---|---|
| `REQUEST_METHOD` | `GET`/`HEAD`/`POST`/`PUT`/`DELETE`/`OPTIONS`，其它 → `UNKNOWN` |
| `SCRIPT_NAME` | 恒为 `/cgi-bin/luci` |
| `PATH_INFO` | 前缀**之后**的部分（裸前缀时为空串） |
| `QUERY_STRING` | 目标串里 `?` 之后的部分（原样，不解码） |
| `REQUEST_URI` | 原始目标串（含查询串） |
| `SERVER_PROTOCOL` | `HTTP/1.0` / `HTTP/1.1`（按请求版本） |
| `GATEWAY_INTERFACE` / `SERVER_SOFTWARE` | `CGI/1.1` / `molly` |
| `DOCUMENT_ROOT` / `REMOTE_ADDR` | `--docroot` 的值 / 对端地址 |
| `CONTENT_LENGTH` / `CONTENT_TYPE` | 请求体长度（GET 时为 `0`）/ 请求头里的类型（有则给） |
| `HTTP_<NAME>` | 其余全部请求头，名字大写、`-` → `_`（`Content-Length`/`Content-Type`/`Transfer-Encoding`/`Connection` 不走这条） |

**子进程响应 → HTTP 响应**（`parse_cgi_response`）：

- 头块与 body 之间用 `\r\n\r\n` 分隔（同时容忍 `\n\n`）；缺 `Content-Type` 视为脚本错误 → **500**。
- `Status: <code> [reason]` 透传状态码（molly 的 `Status` 枚举里没有的码也照原样发，只补常见码的短语）；
  没有 `Status:` 时是 200。非标准的 `HTTP/1.1 200 OK` 起始行也容忍。
- 其余头（`Location` / `Set-Cookie` / `Cache-Control` …）**原样透传**。
- `Content-Length` 与 `Connection` 由 molly 重算 / 决定，脚本给的同名头被忽略。
- 请求体由一个短命线程写进子进程 stdin（避免「子进程先回响应、父进程写 body 卡死管道」）；
  `HEAD` 有头无体；keep-alive 语义与其它路径一致。

**验收**：`./tests/cgi_smoke.sh`（30 项，用桩脚本覆盖环境、body 透传、64KB、状态与头透传、
缺 `Content-Type` → 500、HEAD、keep-alive）。设备上的等价验收：把 `--luci-cgi` 换成真实的
`/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc`，与原厂 uhttpd 做 golden 对比。

### 5.4 菜单语义

`menu.d` 的建树、`depends.fs`/`depends.uci` 判定、通配与 firstchild 竞选全部对齐上游
`dispatcher.uc`（提交 `d6167ea`），逐条对照与行号见
[`architecture.md`](architecture.md) §7 与 `.ai-memory/r8-menu-sample.md`；
一致性由 `.ai-memory/r8_probe.py`（`不一致条目: 0 / 11`）与
`tests/http_smoke.sh` 的 dispatcher 分节共同钉住。

## 6. 内部契约：接口层 ↔ 数据层之间唯一的窄接口

`src/backend/` 对外只有三个 proc（契约原文写在 `backend.odin` 头部注释里）：

```odin
// ubus 对象/签名列表。path == "" 列全部，否则列该对象。
list_objects(path: string, alloc: mem.Allocator) -> (json: string, err: int, ok: bool)

// 一次 ubus 调用；**不含** JSON-RPC 信封（信封是 handler 的事）。
call_object(obj_path, method, params_json, sid: string, alloc: mem.Allocator) -> Call_Result

// 一个 config 的全部 section（菜单 depends.uci 的唯一数据来源）。
uci_config_sections(config: string, alloc: mem.Allocator) -> (sections: []Uci_Section, ok: bool)
```

约定：

- **判定逻辑不在数据层**：`ok == false` 只表示「读不到」，语义解释（例如「0 个 section」
  「对象不存在」）由 `src/luci` 与 `handlers` 决定。
- **内存**：返回的字符串一律指向调用方给的 `alloc`（每请求 arena），两个实现都**不得**
  返回需要调用方 `free` 的堆内存。
- **`libuci`/`libubus` 不是线程安全的**：linux provider 用全局单例 + `sync.Mutex` 串行化；
  持锁期间不写 socket（慢客户端不会占住总线）。
- `Uci_Section{name, type_name, anonymous, options: []Uci_Option{name, is_list, values}}`
  与 ucode 的 `s['.type']` / `s[option]` 一一对应（详见 `backend.odin` 顶部注释）。

## 7. ubus 对象契约：`session`（P3-2，molly 自持）

molly 从 P3-2 起**自己提供** ubus 对象。设备上接管的前提是 rpcd 已停
（`/etc/init.d/rpcd stop`）——同一时刻只有一个进程能持有同名对象；注册失败只打一行日志，
不影响其它功能。权威来源是钉点源码 `rpcd@e37ed9d814699098eb7e26c8b33c054840782dfb`
的 `session.c`（ImmortalWrt 25.12.2 base feed）。实现 `src/backend/session.odin`
（平台无关），linux 侧的注册与 blobmsg⇄JSON 桥在 `src/backend/linux.odin`。

### 7.1 方法与回复

| 方法 | 入参（JSON） | 成功回复 | 失败码 |
| --- | --- | --- | --- |
| `create` | `timeout?`（秒，默认 300） | 会话 dump（含 `acls`） | — |
| `list` | `ubus_rpc_session?` | 带 sid：该会话 dump；不带 sid：**数组**（偏离 1） | 4 |
| `get` | `ubus_rpc_session`、`keys?` | `{"values":{…}}` | 2 / 4 |
| `set` | `ubus_rpc_session`、`values` | 无回复数据（偏离 2） | 2 / 4 |
| `unset` | `ubus_rpc_session`、`keys?` | 无回复数据（不给 `keys` = 清空） | 2 / 4 |
| `destroy` | `ubus_rpc_session` | 无回复数据 | 2 / 4 / 6（哨兵会话） |
| `access` | `ubus_rpc_session`、`object?`、`function?`、`scope?` | 带 `object`+`function`：`{"access":bool}`；否则：ACL 表 | 2 / 4 |
| `grant` / `revoke` | `ubus_rpc_session`、`scope?`（默认 `ubus`）、`objects?:[[object,function],…]` | 无回复数据 | 2 / 4 |
| `login` | `username`、`password`、`timeout?` | 会话 dump（含 `acls`） | 2 / 6 |

会话 dump（`session.c:224-244`）：

```json
{ "ubus_rpc_session": "<32 位十六进制>", "timeout": 300, "expires": 299,
  "acls": { "<scope>": { "<object>": ["<function>", "…"] } },
  "data": { "<key>": "任意 JSON 值" } }
```

状态码与 §4.4 的 ubus 码表是同一套：2 = `INVALID_ARGUMENT`、3 = `METHOD_NOT_FOUND`、
4 = `NOT_FOUND`、6 = `PERMISSION_DENIED`。

### 7.2 语义要点

- **sid**：`/dev/urandom` 取 16 字节，转 32 位小写十六进制（`session.c:150-176`）。
- **超时**：默认 300 秒，每次访问续期；`expires` 是**剩余秒数**（`session.c:233`）。
- **哨兵会话** `000…0`：进程启动时自动建立，永不过期、不可销毁
  （`session.c:806-807`、`:1380-1390`）。HTTP 路径上无 `Authorization` 头时用的就是它。
- **ACL**：`scope → (object, function)`；匹配 = 前缀剪枝 + `fnmatch`（`*`/`?`/`[…]`，
  `session.c:131-147`）。`revoke` 不带 `objects` 清空整个 scope，`grant` 不带则是
  `INVALID_ARGUMENT`。
- **`login`**：读 `/etc/config/rpcd` 的 `config login` section，找 `username` 精确匹配的
  那条，再校验 `password`：`$p$<user>` = 引用 `/etc/shadow` 里该用户的 hash，
  否则 `crypt(password, hash) == hash`；没有匹配的 section 一律 `PERMISSION_DENIED`
  （`session.c:819-924`、`:1152-1214`）。
- **sid 注入**：设备/HTTP 层把会话 id 作为 `ubus_rpc_session` 追加进对象入参
  （`linux.odin` 的 `call_object` 用 `blobmsg_add_string`，darwin 路由用等价实现）。

### 7.3 已知偏离（真机 golden 对比时要核对）

1. `list` 不带 sid：上游对每个会话**各回一条**（N 条回复），JSON-RPC 信封只能装一条，
   molly 回数组。HTTP 路径上总是带 sid，实际取不到这条分支。
2. `set` / `unset` / `destroy`：上游**不回数据**，molly 回一个空表（信封里是 `{}`）。
3. 过期是**惰性**的：下一次访问时清理，上游用 uloop 定时器到点销毁。可观测行为一致
   （过期会话查不到），内存回收时机不同。
4. **ACL 来源不完整**：本轮只有 `grant`/`revoke`。`/usr/share/rpcd/acl.d/*.json` 与
   login section 的 `read`/`write` 组加载属 **P3-6**——登录成功但 `acls` 为空，
   P3-6 之前不要拿登录态去跑需要 ACL 的调用。
5. **会话不落盘**：上游把会话 freeze 到 `/var/run/rpcd/sessions/<id>`，重启后 thaw 恢复；
   molly 重启即所有会话失效。P3-9 收尾时评估。

## 8. ubus 对象契约：`uci`（P3-3，S1 只读 + S2 delta）

权威来源：`rpcd@e37ed9d8` 的 `uci.c`（15 个方法，`uci.c:1766-1784`）。实现
`src/backend/uci_object.odin`（平台无关），linux 的注册与 blobmsg ⇄ JSON 桥在 `linux.odin`。

### 8.1 已实现（S1）

| 方法 | 入参（JSON） | 成功回复 | 失败码 |
| --- | --- | --- | --- |
| `configs` | 无 | `{"configs":["network","system",…]}` | 9 |
| `get` | `config`（必需）、`section?`、`option?`、`type?`、`match?` | 见下 | 2 / 4 / 6 |
| `changes` | `config?` | 带 config：`{"changes":[[type,section,name?,value?]…]}`；不带：`{"changes":{<config>:[…]}}` | 2 / 4 / 6 |
| `commit` / `revert` | `config`（必需） | 无回复数据 | 2 / 4 / 6 / 8 |
| `set` | `config`、`values`（必需）、`section` 或 `type`/`match` 至少一个 | **无回复数据** | 2 / 4 / 6 / 8 |
| `add` | `config`、`type`（必需）、`name?`、`values?` | `{"section":"<section 名>"}` | 2 / 4 / 6 / 8 |
| `delete` | `config`、`section` 或 `type`/`match` 至少一个、`option?`/`options?` | **无回复数据** | 2 / 4 / 6 / 8 |
| `rename` | `config`、`section`、`name`（必需）、`option?` | **无回复数据** | 2 / 4 / 6 / 8 |
| `order` | `config`、`sections`（必需，数组） | **无回复数据** | 2 / 4 / 6 / 8 |
| `apply` | `rollback?`(bool)、`timeout?`(int，默认 60s) | **无回复数据** | 2 / 4 / 5 / 6 / 8 |
| `confirm` | 无（会话来自 sid） | **无回复数据** | 2 / 5 / 6 |
| `rollback` | 无（会话来自 sid） | **无回复数据** | 2 / 4 / 5 / 6 |
| `reload_config` | 无 | **无回复数据** | 8（darwin）/ 0 |
| `state` | 同 `get` | 同 `get`，但读**已提交态**（savedir 换 `/var/state`） | 2 / 4 / 6 / 8 |

`get` 的三种回复形态由 ptr 的层级决定（`uci.c:638-654`）：

```json
// package 级：{"values": {"<section>": {…, ".index": N}}}
{ "values": { "lan": { ".anonymous": false, ".type": "interface", ".name": "lan",
                       ".index": 0, "proto": "static", "dns": ["1.1.1.1"] } } }
// section 级：同样的键，但没有 .index
{ "values": { ".anonymous": false, ".type": "interface", ".name": "lan", "proto": "static" } }
// option 级：键是 value
{ "value": "static" }
```

- `.index` 是 section 在**整份配置**里的序号（`uci.c:588-590`：先自增再筛选，被筛掉的也占号）。
- 匿名 section 的键是它的 section 名（真机上是 libuci 生成的 `cfgXXXXXX`）。
- `section` 支持扩展形式 `@type[idx]`（同类型 section 里的第 idx 个，`uci.c:396-397`）。
- `type` / `match` 只在 package 级生效：`type` 必须相等；`match` 的每个键去 section 里找同名
  option，值为字符串时按空格/制表符**切词**比较、为数组时逐元素比较（`uci.c:415-499`）；
  「一个键命中就够，缺席的键不否决」（`empty || match`）。
- 权限：`session.access("uci", <config 名>, "read")`（`uci.c:311-337`）——molly 直接复用
  session 的 ACL 引擎，所以**没授权就是 6**；而且上游顺序是「先 ACL、后 `uci_load`」，
  未授权的 config 名即使不存在也先回 6。
- `configs` 上游**不做** ACL 检查（方法表里它是唯一没有策略的）。

### 8.1.1 S2 的 delta 语义（`changes` / `commit` / `revert` / `state`）

- **每会话一个 delta 目录**：`/var/run/rpcd/uci-<sid>`（`RPC_UCI_SAVEDIR_PREFIX`，`uci.h`）；
  没有 sid（内部调用）时是 `/tmp/.uci`（`uci.c:288-303`）。
- `changes` 枚举 libuci 的 `p->saved_delta`（`uci.c:1250-1251`），每条渲染成
  `[type, section, name?, value?]`（`uci.c:1189-1222`）：type ∈ `add`/`remove`/`set`/`rename`/
  `order`/`list-add`/`list-del`；`order` 的 value 是**数字**；没有 section 的条目整条丢掉。
  **不带 `config`** 时逐 config 做读权限过滤、没有 delta 的跳过，最后返回 0（不是游标状态）。
- `commit` = `uci_load` → `uci_commit(ctx, &p, false)`（写完清掉 delta）→ 触发
  `service.event`（`{"type":"config.change","data":{"package":<config>}}`，`uci.c:1304-1321`）。
- `revert` = `uci_lookup_ptr(package)` → `uci_revert`（`uci.c:1353-1360`）。
- `state` 与 `get` 共用实现，只差 savedir —— `state` 切到 `/var/state` 读已提交态。
- 两者都要 **write** 权限（`uci.c:327-337`），`changes`/`state` 要 read 权限；
  ACL 检查在平台能力**之前**（与上游顺序一致）：未授权时 `commit` 是 6 而不是 8。
- 会话销毁（含惰性过期）时清掉它的 delta 目录（`uci.c:1739-1746` 的回调）。

### 8.1.2 S3 的写语义（`set` / `add`）

- **`save` 不等于落盘**：`set`/`add` 只把改动写进**该会话的 delta 文件**
  （`/var/run/rpcd/uci-<sid>`），`/etc/config` 要等 `commit` 才动。所以写操作是可回滚的
  （`revert` 丢掉 delta，`changes` 能看到未提交的改动）。
- `set` 的两条校验：`values` 必须是表，且 `section`/`type`/`match` 至少要有一个；
  给了 `section` 还要过 `uci_verify_section`（扩展形式 `@type[idx]` 合法，
  `lan[0]` 这种不合法）。参数校验**先于** ACL 与平台能力。
- `set` 的 `values` 每个键按 `merge_set` 语义（`uci.c:806-872`）：
  数组 → 先删旧 option 再逐个 `add_list`；标量 + 现有 list → 先删再 set；
  标量且值**没变** → 什么都不做（避免造无用 delta）；值类型不支持（浮点/对象）→ `2`。
- `add` 的 `values` 语义**不同**（`uci.c:757-787`）：数组直接 `add_list`（不删旧值）、
  标量直接 `set`（不比旧值）。
- **错误聚合相反**：`add` 是「首个错误优先」（`uci.c:743-746` 等），
  `set`/`delete`/`order` 是「最后一个错误覆盖」（`uci.c:913`、`:932`）——
  同一个 `values` 表里有多个坏键时，两者返回的码可能不同。
- 一个 section 都没命中（`type`/`match` 没匹配上任何 section）→ `4`（`uci.c:937-938`）。
- 具名 section 用 `uci_set`（`ptr.value = type`）创建，匿名用 `uci_add_section`，
  返回的 `{"section": …}` 是 libuci 生成的名字（`cfgXXXXXX`）。

### 8.1.3 S3 的写语义（`delete` / `rename` / `order`）

- `delete` 的三种形态由参数决定（`uci.c:1042-1049`）：给了 `options`（数组）→ 逐个删、
  **一个都没删到**才回 `4`；给了 `option`（字符串）→ 删具名、找不到回 `4`；
  两个都没给 → **删整个 section**。
- 没给 `section` 时按 `type`/`match` 遍历命中项；**一个 section 都没命中 → `4`**。
  上游用 `uci_foreach_element_safe` 边走边删（删 section 会释放元素），molly 这边是快照，
  所以先把命中项的名字克隆出来再删 —— 行为一致，内存安全。
- `rename`：`name` 过 `uci_verify_name`（**不**校验 `section` 的语法）；
  `(给了 option 但找不到该 option) || 找不到 section` → `4`（`uci.c:1114-1118`）。
- `order`：数组元素**只认字符串**（其它 → `2`）、`section` 找不到 → `4`，两者都是
  **首个错误优先**（`uci.c:1158-1175`）；位置计数只对**成功**的项递增（`uci.c:1177`）。
- 这三个方法的**必需参数校验在 ACL 之前**，而 `type`/`section`/`name` 的语法校验在
  ACL **之后**（与上游顺序一致）：未授权 + 非法 section 得到的是 `6`，不是 `2`。

### 8.1.4 S4 的 apply 系（`apply` / `confirm` / `rollback` / `reload_config`）

机制（`uci.c:1443-1734`）：**改配置 → 立即生效 → 60 秒内必须确认，否则自动回滚**。

- `apply {rollback:true, timeout:N}`：
  1. 把 `/etc/config/<c>` 备份到 `/var/run/rpcd/snapshot-files/`，把该会话的 delta
     （`/var/run/rpcd/uci-<sid>/<c>`）备份到 `/var/run/rpcd/snapshot-delta/`；
  2. 逐个 config 提交（`uci_load` + `uci_commit` + 触发 `config.change` 事件）→ **真的生效**；
  3. 记下发起者 sid 并起一个 N 秒（默认 60）的定时器；期间 `commit`/`revert` 一律 `6`。
- `confirm`：发起者在窗口内确认 → 清快照 + 停定时器 + 清除 pending（`5` = 没有待确认的 apply、
  `6` = 会话不是发起者）。
- `rollback`：主动回滚（用快照覆盖 `/etc/config` 并重新提交）；`apply {rollback:true}` 到期时
  由定时器做同一件事。回滚期间「不合并 delta」（用 `/dev/null` 当 delta 目录，
  `uci.c:1524-1525`），否则恢复旧配置会被当前未提交的改动污染。
- 想回滚的那个会话如果**已经不存在**了，只恢复 `/etc/config`，不再恢复 delta
  （`uci.c:1513-1522`）——这样「会话没了」不会把半截状态写回去。
- `apply` 只能处理**有 delta 文件**的 config：一个可用的 delta 都没有 → `5`（NO_DATA）；
  会话目录不存在 → `4`（NOT_FOUND）。
- `reload_config`：fork 一个子进程，`sleep(2)`（等这次 RPC 的响应先发出去）后
  `execv("/sbin/reload_config")`，父进程立刻回 `0`（`uci.c:1720-1734`）。

### 8.2 实现状态

15 个方法在 **linux 上全部实现**。darwin（macOS 开发/测试环境）只实现不依赖 libuci
的部分：`configs`/`get`/`changes` 走假数据，`state`/`commit`/`revert` 与五个写操作、
`apply` 系回 `NOT_SUPPORTED(8)`，`apply` 会因为「该会话没有 delta 目录」先回 `4`。

**已定：写路径先只在 linux 上实现**——darwin 侧不另做一份 uci 读写替身，所以 macOS 上只能
验到「回 8」。设备上接管这个对象后，它**不会**改动 `/etc/config`。

副作用（S3 之前）：未实现的方法不做 ACL 检查（先进 switch 就回 8），未授权调用 `set`
得到的是 8 而不是 6；S3 落地时写方法要补 `write_access` 检查（`uci.c:327-337`）。

### 8.3 与 rpcd 的已知差异

1. **`apply` 系未实现**（见 8.2）：它们仍回 `8`。五个写操作（`set`/`add`/`delete`/
   `rename`/`order`）已实现，但只在 linux 上生效（darwin 回 8），且真机行为**尚未验证**。
2. `match` 的值只认 string / 整数 / bool（C 的 `rpc_uci_format_blob` 没有浮点分支）；
   负数按原值打印，C 用 `%u` 打印无符号值（`uci.c:356-374`）。
3. 名称校验的扩展形式只认纯数字下标，C 的 `strtol` 还接受前导空白与 `+`（`uci.c:207`）。
4. darwin 假数据里匿名 section 的 `name` 是空串（fixtures 的既有约定），真机上是
   `cfgXXXXXX`——真机 golden 对比时注意键名差异。
5. **每会话短命 context**（S2 的实现选择）：上游用**一个** uci_context，每次调用把它的
   delta 搜索路径整表替换掉（`rpc_uci_replace_savedir`，`uci.c:264-303`）——那要直接改
   `struct uci_context` 的内部（`delta_path`），而 `delta_path` 不在公开头文件里
   （`uci.h` 只给不透明句柄）。molly 改成**每个会话一个短命 context**（用完 free）：
   新 context 的 delta 路径天然只有我们要的那一个，没有跨会话串味，也不用碰内部结构。
   代价是每次调用多一次 `uci_alloc_context`（相对 `uci_load` 的解析开销可忽略）。
6. **不在启动时清理历史 delta 目录**（上游 `rpc_uci_purge_savedirs`，`uci.c:1749-1764`）。
   sid 是 32 位随机十六进制，撞不上，所以残留目录只是垃圾不会串味；P3-9 收尾时补。
7. darwin 的 `changes` 返回一组**固定**假 delta（`FAKE_DELTA`，见 `darwin.odin`），
   只为让形状在 macOS 上能被断言；`state`/`commit`/`revert`/`set`/`add` 在 darwin 上回 8。
8. **写路径与 apply 系尚未在设备上验证**：`uci_set`/`uci_add_list`/`uci_delete`/
   `uci_rename`/`uci_reorder_section`/`uci_add_section`/`uci_save`/`uci_commit` 只有
   `./build.sh --target` 的编译保证；真机验证方式是「**备份 `/etc/config` 后用副本**
   对着 `uci` CLI 逐条比对」，apply 系还要验「窗口内 confirm 与超时回滚」两条路径。
9. **确认窗口用线程而非 uloop 定时器**：上游是 `uloop_timeout`（跑在服务线程的事件循环里），
   molly 用「自清理线程 + sleep + 代际号」——可观测行为一致（到点回滚、confirm 取消），
   少一个 C 结构体绑定；同一时刻最多一个 apply 待确认，线程数有界。
10. **列目录用 `os.read_dir` + 显式过滤**（跳过 dotfile 与空文件），不是上游的
   `glob(GLOB_PERIOD)`（那个会把 `.`/`..` 也算进结果，所以 rpcd 里有 `gl_pathc < 3` 这种
   拐弯判断）。效果等价：一个可用的 delta 文件都没有 → `5`。

## 9. 契约的权威来源与验证方式

| 契约 | 权威来源 | molly 的验证 |
|---|---|---|
| `/ubus` 各形态、错误码、会话来源 | 上游 uhttpd 的 `ubus.c`（25.12.2 对应提交） | `tests/http_smoke.sh` 的 `/ubus` 两节 + `-32000/-32601/-32700/-32602` 断言 |
| dispatcher 语义 | `modules/luci-base/ucode/dispatcher.uc`（luci `d6167ea`） | `tests/http_smoke.sh` 的 dispatcher 节 + `src/luci/menu_test.odin` + `.ai-memory/r8_probe.py` |
| HTTP 层上限与 keep-alive | uhttpd 行为（部分自定，风险 R7） | `tests/http_smoke.sh` 的「上限与错误码」「keep-alive」「管道请求」节 |
| 静态文件与 MIME | uhttpd 行为 | `tests/http_smoke.sh` 静态节 + `src/http/mime_test.odin` |
| `uci` 对象（S1：`configs`/`get` 的回复形状、`.index`、`match`/`type`、ACL 钩子；S2：`changes` 的三形态、`state`/`commit`/`revert` 的状态码、savedir 清理；S3：五个写操作的参数校验、写计划与错误聚合；S4：apply 系的中性路径（5/4/2 与状态码顺序）） | `rpcd@e37ed9d8` 的 `uci.c` | `src/backend/uci_object_test.odin` + `uci_write_test.odin`（11 用例组）+ `tests/http_smoke.sh` 的「P3-3 uci 对象」节（36 项） |
| `session` 对象（10 方法、状态码、dump 形状、ACL 匹配） | `rpcd@e37ed9d8` 的 `session.c` | `src/backend/session_test.odin`（10 用例）+ `tests/http_smoke.sh` 的「P3-2 session 对象」节（13 项） |
| 真机 golden 对比 | 原厂固件响应样本 | **待第 7 步**（替换前须先在设备上抓全量样本存档） |

其它文档：[`build-and-run.md`](build-and-run.md)（配置与部署运行）、
[`testing.md`](testing.md)（三层测试与执行流程）、[`architecture.md`](architecture.md)（分层与依赖规则）。
