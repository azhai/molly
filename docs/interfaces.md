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
| `--luci-cgi` | 空 | 把 `/cgi-bin/luci` 交给子进程执行（设备上填 `/www/cgi-bin/luci`，复刻 uhttpd 的 CGI 形态，ADR 0003 的 T1；**不是** `/usr/bin/ucode …/uhttpd.uc`，见 §5.5）。留空 = 用内置的 Odin dispatcher（§5） |
| `-h` / `--help` | — | 打印用法并正常退出 |

- **参数错误**（未知参数、缺参数、地址无法解析、监听失败）：stderr 打印原因 + 用法，**退出码 2**。
- **启动输出**（stdout）：`[molly] 监听 …`、`[molly] docroot: …`、`[molly] menu.d: …`，
  以及**逐对象**的注册诊断（rpcd 还占着同名对象时会出现；P3-9 起不再有整行的
  「transitional mode」警告）。
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
| 501 | 命中菜单但 `action.type` 不是 `view`（`cbi`/`form`/`template`/`function`） |
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
| `GET /ubus/subscribe/<path>` | SSE：`200` + `text/event-stream`；ACL 不过或对象不存在时是 `200` + `application/json` + `{"code":…}`（详见 §4.7） |

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

### 4.7 `GET /ubus/subscribe/<path>`（SSE，P3-7）

权威来源 `/tmp/uhttpd-ubus.c:373-424`（`uh_ubus_handle_get_subscribe`），逐条对齐：

1. sid 从 `Authorization: Bearer` 取（`:380`），缺失回退哨兵 `0000…`。
2. ACL 点是**伪方法** `:subscribe`（`:382`）——不是 `call` 的方法名，别混用。
   不过 → `200` + `application/json` + `{"code":-13,"message":"Permission denied"}`
   （`uh_ubus_posix_error`：posix **负码**，与 `/ubus/call` 的 `-32002` 不是一个体系）。
3. 对象不存在（上游 `ubus_lookup_id`）→ `200` + json + `{"code":4,"message":"Not found"}`。
4. 成功 → `200` + `Content-Type: text/event-stream`，随后是事件帧：
   ```
   event: <method>\ndata: <json>\n\n
   ```
5. 客户端断开 → 注销订阅（`:366-371`）。

**molly 的实现差异**（都不是可观测的语义差异，但 golden 对比时要看）：

| 项 | 上游 | molly |
| --- | --- | --- |
| 通知回调在哪个线程 | uloop 单线程，直接写 socket | ubus 线程回调 → **每订阅一根管道** → HTTP 线程 poll（ADR 0001 第 3 条） |
| 正文分帧 | chunked（`ops->chunk_printf`） | 裸流（无 `Content-Length`，`Connection: close`） |
| 心跳 | 无（靠 uhttpd 的连接超时） | 每 30s 一条注释帧 `: heartbeat\n\n` |
| `retry:` 行 | 配了 `-e` 才发 | 不发（没有对应选项） |
| 写端满了 | 单线程下会阻塞 | 非阻塞，**丢事件**（不把 ubus 线程卡死） |
| subscriber 的粒度 | 每条 SSE 连接一个（`du` 是 per-client 的） | 按 **对象路径**一个（发布本来就按 path 匹配） |
| 命令通道（HTTP → ubus 线程） | 不存在（单线程） | HTTP 线程排命令，ubus 线程在 `uloop_run_timeout(100)` 的间隙排空；ADR 0001 写的是「把命令管道挂进 uloop」，这里是轮询——少一个 uloop fd 绑定，命令延迟 ≤ 100ms |

**linux 侧（S2）的实现要点**：`src/backend/linux.odin` 里每个被订阅的 path 对应一个
`ubus_subscriber`；通知回调（`proc "c"`，**没有 context、不能分配**）只把
`(path, method, json)` 搬进一条定长环形槽，由 ubus 线程主循环排空并调
`event_bus_publish`——所以发布路径上没有任何分配。
`ubus_unregister_subscriber` 是 `static inline`（`libubus.h:329-335`，.so 里没有符号），
按源码复刻在 `bindings/ubus.odin`（与 `ubus_add_uloop` 同一套路）。

订阅上限 32（与 HTTP 的并发连接上限一致），满了按 `UNKNOWN_ERROR` 回。
darwin 的事件源是 `molly.probe` 的 `emit` 方法（**测试专用**，真机没有）。

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
| **无会话** 且路径上出现过 `auth.login` 的节点（P3-6 收尾） | **403** + `X-LuCI-Login-Required: yes` + 登录提示页（见 §5.3）；上游在这一步渲染主题的登录表单（`dispatcher.uc:930-960`），molly 只对齐状态码与响应头 |

登录判定按上游两条语义实现（顺序也一致：**先判登录，再判 404**）：

- **最后者胜**：`ctx.auth = node.auth || ctx.auth`（`ctx_append`，`dispatcher.uc:463`）——更深的
  节点只要带 `auth`（哪怕没有 `login`）就把前面的顶掉。所以 `/cgi-bin/luci/admin` 要登录，
  而 `/cgi-bin/luci/admin/uci/apply_rollback`（自带的 `auth` 里没有 `login`）不要。
- **firstchild 的 login 模式**：`login = !session && (login_allowed || child.auth?.login)`
  （`:593`）——无会话时 ACL 缺组的子节点也进竞选，否则真实 menu.d 上整棵 `/admin` 子树都
  不可见，用户看到的是一片 404，而上游是要把他导到登录页的。

501 的正文**故意带命中信息**：真实 menu.d 里非 `view` 的 action 占相当比例（413 条路径中
`view` 311 / `function` 31 / `alias` 21 / `template` 6 / `call` 1，`firstchild` 43 是中间层），
只回一句 `not implemented` 无法判断落到了哪个节点（真机实测踩过）。渲染这些 action 属 P3-8。

`action` 取自下钻结束后的节点；**有剩余段**（通配层收下 `request_args`）且该节点有
`wildcardaction` 时用它，否则用 `action`（上游 `dispatcher.uc:1006-1011`）。

### 5.3 占位页结构（脚本可断言）

```html
<!DOCTYPE html>…<h1>{title}</h1>
<dl>
  <dt>action.type</dt><dd>{type}</dd>
  <dt>view</dt><dd>{path}</dd>
  <dt>depends</dt><dd>{depends 原文 JSON}</dd>                        <!-- 仅当该节点有 depends -->
  <dt>readonly</dt><dd>yes|no</dd>
  <dt>request_args</dt><dd>{args，以 " / " 连接}</dd>                  <!-- 仅当有剩余段 -->
</dl>
<!-- 只读会话额外一行：<p class="banner read-only">read-only：本会话对这条路径只有 read 权限（depends.acl）</p> -->
```

- `title` 为空时回落到 `action.path`。
- `depends` 的 `fs`/`uci` 由 `satisfied` 决定、`acl` 按会话现算（见 §11.2）——三部分都真的执行。
- `readonly` 反映本会话对**这条路径**上节点的 `depends.acl` 是否只有 read（上游
  `resolved.node.readonly`，`dispatcher.uc:1002-1003`）。
- 所有插值都做 HTML 转义（`request_args` 是彻头彻尾的客户端输入）。

登录提示页（§5.2 最后一行那个 403 的正文；同样可断言）：

```html
<!DOCTYPE html>…<h1>Login required</h1>
<dl>
  <dt>login</dt><dd>required (no session)</dd>
  <dt>path</dt><dd>{请求路径，空路径显示为 "/"}</dd>
  <dt>hint</dt><dd>POST /ubus 调 session.login 取 sid，再带 Cookie: sysauth_http=<sid></dd>
</dl>
```

它存在的理由是可诊断：设备上没有它时，无会话访问 `/cgi-bin/luci/**` 就是一片裸 404，
看不出「是要登录」还是「路径不存在」（2026-09-27 实测踩过）。

### 5.5 CGI 模式（`--luci-cgi`，ADR 0003 的 T1）

给了 `--luci-cgi` 时，§5.1–§5.3 的**内置 dispatcher 不再参与**：整个 `/cgi-bin/luci` 前缀按
CGI 规范交给子进程，方法不限，由脚本自己判定。

**设备上填什么**：`/www/cgi-bin/luci`（LuCI 安装的 CGI 兜底脚本，`#!/usr/bin/env ucode` +
`dispatch(request(getenv(), read, write))`，复刻 uhttpd 的 CGI 形态）。

**别填 `/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc`**（曾写在 README/`-h` 里，2026-09-27 纠正）：
那个文件是 uhttpd **进程内** 加载的 ucode **模板**——首行是 `{%`（ucode 的模板块标记）、
定义 `global.handle_request(env)`、收发走 uhttpd 注入的 `uhttpd.recv`/`uhttpd.send`。它必须在
uhttpd 进程里按模板编译，单独 execve 必然立即语法错：

```
Syntax error: Expecting expression            （第 1 行 `{%`）
Syntax error: Imports may only appear at top level   （`import dispatch from 'luci.dispatcher';`）
Syntax error: Unexpected token  Expecting '}'  （`};`）
```

症状就是浏览器每个 `/cgi-bin/luci/**` 都得到 **500**，正文 `invalid CGI response (exit 1): ""`，
而那四条语法错在 **molly 的 stderr** 里（子进程 stderr 继承 molly 的 stderr）。

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
- 子进程没给出合法响应（无输出、或缺 `Content-Type`）时正文是
  `invalid CGI response (<exit N>|<signal N>|unknown exit status): "<stdout 前 200 字节>"` ——
  带上**退出码**是为了区分「脚本自己退出（配置/语法问题）」与「被信号杀掉（崩溃）」；
  子进程的 stderr 继承 molly 的 stderr，报错细节在那里（见下面那段配置陷阱）。
- `Status: <code> [reason]` 透传状态码（molly 的 `Status` 枚举里没有的码也照原样发，只补常见码的短语）；
  没有 `Status:` 时是 200。非标准的 `HTTP/1.1 200 OK` 起始行也容忍。
- 其余头（`Location` / `Set-Cookie` / `Cache-Control` …）**原样透传**。
- `Content-Length` 与 `Connection` 由 molly 重算 / 决定，脚本给的同名头被忽略。
- 请求体由一个短命线程写进子进程 stdin（避免「子进程先回响应、父进程写 body 卡死管道」）；
  `HEAD` 有头无体；keep-alive 语义与其它路径一致。

**验收**：`./tests/cgi_smoke.sh`（31 项，用桩脚本覆盖环境、body 透传、64KB、状态与头透传、
缺 `Content-Type` → 500、脚本无输出 → 500 且正文带退出码、HEAD、keep-alive）。
设备上的等价验收：把 `--luci-cgi` 换成真实的 `/www/cgi-bin/luci`，与原厂 uhttpd 做 golden 对比。

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
  返回需要调用方 `free` 的堆内存。linux 的 ubus handler 也照此办：每次调用起一个
  `Dynamic_Arena` 并把 `context.allocator` 一并指过去（见 `docs/architecture.md` §4 的
  「每次请求的内存」）——**别**把默认（堆）分配器当请求 arena 用，那样每次调用都会漏。
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
4. **ACL 来源已完整**（P3-6 补上）：登录时按 `/usr/share/rpcd/acl.d/*.json` 与 login
   section 的 `read`/`write` 组加载；默认/哨兵会话只吃 `unauthenticated` 组。
   匹配细节与 `/ubus` 的前置校验见 §11。
5. **会话不落盘**：上游把会话 freeze 到 `/var/run/rpcd/sessions/<id>`，重启后 thaw 恢复；
   molly 重启即所有会话失效。P3-9 收尾时评估。

## 8. ubus 对象契约：`uci`（P3-3，15 方法全实现：S1 只读 / S2 delta / S3 写操作 / S4 apply 系）

权威来源：`rpcd@e37ed9d8` 的 `uci.c`（15 个方法，`uci.c:1766-1784`）。实现
`src/backend/uci_object.odin`（平台无关），linux 的注册与 blobmsg ⇄ JSON 桥在 `linux.odin`。
**写路径（写操作 / `commit` / `revert` / apply 系）只在 linux 上实现**，darwin 侧
provider 不做 savedir 与写事务，对应方法回 `8`。

### 8.1 方法契约（15 个方法）

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

## 9. ubus 对象契约：`file`（P3-4，8 方法全实现）

权威来源：`rpcd@e37ed9d8` 的 `file.c`（8 方法）。实现 `src/backend/file_object.odin`
（平台无关），linux 的注册在 `linux.odin`；darwin 的 `/ubus/call/file` 路由走同一实现
（`realpath` 绑定在 `bindings/libc.odin`（linux）与 `libc_darwin.odin`（darwin））。

### 9.1 方法

| 方法 | 权限名 | 入参 | 成功回复 | 备注 |
| --- | --- | --- | --- | --- |
| `read` | `read` | `path`、`base64?` | `{"data":…}` | 空/读不到 → `5`；≥256KB → `8` |
| `write` | `write` | `path`、`data`（缺 → 2）、`append?`、`mode?`、`base64?` | **无回复数据** | 默认 `O_TRUNC`；`mode` 只在建新文件时生效（`& 0777`，默认 0666） |
| `list` | `list` | `path` | `{"entries":[…]}` | 每条目 **lstat**；符号链接带 `target`（`name`+stat，坏链 `type:"broken"`） |
| `lstat` | `list` | `path` | `{"path":…, stat…}` | **不解析符号链接**（看链接本身） |
| `stat` | `list` | `path` | `{"path":…, stat…}` | 跟随符号链接 |
| `md5` | `read` | `path` | `{"md5":"<32 hex>"}` | 只对普通文件，其它 → `8` |
| `remove` | `write` | `path` | **无回复数据** | **不解析符号链接**（unlink no-follow）；目录 → 递归，**每个条目单独过 write ACL**（`file.c:792`） |
| `exec` | `exec`（路径对象）或**整条命令行字符串** | `command`、`params?`、`env?` | `{"code":N,"stdout?":…,"stderr?":…}` | 见下 |

**权限名按方法各不相同**（照抄上游，`file.c:512/664/734/756/829`）：
`read`/`md5` → `"read"`、`write`/`remove` → `"write"`、`list`/`stat`/`lstat` → `"list"`。
注意 `stat`/`lstat` 用的也是 `"list"` 而不是 `"read"`——这是上游的实际行为，改「合理化」了 golden 就对不上。

**`exec` 的语义**（`file.c:846-1203`）：
- `command` 缺 → `2`；PATH 查找不到 → `4`（无 `PATH` 环境时用 `/bin:/usr/bin:/sbin:/usr/sbin`）。
- **带会话的调用不允许 `env`**（`file.c:1047`，先于 ACL/查找）→ `6`。
- ACL 两层：先查可执行文件路径（PATH 解析后）`session.access("file", <exe>, "exec")`；
  不过再把**整条命令行**（`"exe arg1 arg2…"`，≤1024B、≤255 参数）当作第二个对象查一次——
  所以 ACL 既可以授权「该可执行文件带任意参数」，也可以授权「这条精确命令行」。
- 子进程：stdin → `/dev/null`，stdout/stderr → 两条管道，`execv`（**不做 shell 拼接**）；
  参数数组里非字符串条目跳过。
- 超时 120s（`RPC_EXEC_DEFAULT_TIMEOUT`，`exec.h:27`）→ `SIGKILL` + `7`（TIMEOUT）；
  单条流输出超 64KB → `8`。
- 回复：`code` 是退出码（被信号杀死 → `0xff`，上游此值未定义）；`stdout`/`stderr` 仅在
  非空时出现。

stat 类回复的字段（`file.c:634-651`）：`type`（`file`/`directory`/`symlink`/`fifo`/`socket`/
`block`/`char`/`unknown`）、`size`、`mode`（**完整 st_mode**，含类型位）、`atime`/`mtime`/`ctime`
（epoch 秒）、`inode`（截到 32 位）。

### 9.2 路径与权限核心（所有方法共用，`file.c:180-359`）

1. **文本规范化**（`file.c:189-248`，纯函数 `file_canonicalize_path`）：折掉重复 `/`、`/./`、
   `/../`（`..` 后接 `/` 或结尾时折叠）与结尾 `/`；空路径 → `2`。
2. **ACL 检查**（`file.c:180-187`）：`session.access("file", <规范化路径>, "read"/"write")`
   ——复用 session 的 ACL 引擎，按路径做前缀 + `fnmatch` 匹配。
3. **符号链接复查**（`file.c:261-359`）：`realpath` 解析后与文本路径比较，不同则对
   **解析后的路径再查一遍 ACL**。不做第三步的话，授权目录里放个指向 `/etc/shadow` 的
   符号链接就能绕过授权。悬空符号链接（realpath 失败）→ `6`。

`read` 的成功回复：`{"data": "…", "size": N}`（`base64` 时 `data` 是编码后的文本）；
路径不存在 → `4`，无权限 → `6`，缺 `path` → `2`。

### 9.3 已知偏离（真机 golden 对比时核对）

1. `exec` 是**同步**实现（在 ubus/HTTP 线程里等到进程退出，最长 120s）；上游用 uloop +
   ubus 延迟回复异步回包、不阻塞其它请求。调用方可观测行为一致，服务端并发行为不同。
   输出超限时 molly 会 `SIGKILL` 子进程，上游不杀（请求照样完成）。
2. `stat` 类回复**没有** `uid`/`gid`/`user`/`group`（上游用 `getpwuid`/`getgrgid` 补用户名；
   Odin 的 `File_Info` 不含 uid/gid）——Luci 的文件浏览主要用 type/size/mode，需要时在
   真机 golden 对比后补 libc 绑定。
3. `write` 用 `os.sync`（fsync 单文件），**没有**上游的全局 `sync()`；`mode` 参数只影响
   新建文件（与上游一致），权限位映射用 Odin `Permissions` 的位号（与 unix 位一一对应）。
4. `read`/`md5` 整文件读入内存：`md5` 没有大小上限（上游流式 `md5sum`），超大文件行为不同。
5. ENOTDIR → `2`（与上游 `rpc_errno_status` 一致）；`list` 对普通文件回 `2` 而不是 `9`。

## 10. ubus 对象契约：`luci-rpc`（P3-5，6 方法全实现）

权威来源：`luci@d6167ea` 的 `libs/rpcd-mod-luci/src/luci.c`（6 方法，`luci.c:2033-2040`）。
**对象名是 `luci-rpc`**。实现 `src/backend/luci_object.odin`（平台无关），linux 的注册在
`linux.odin`、darwin 的 `/ubus/call/luci-rpc` 路由在 `darwin.odin`。

### 10.1 方法契约（文件/解析驱动的 3 个方法）

| 方法 | 入参 | 成功回复 | 失败码 |
| --- | --- | --- | --- |
| `getBoardJSON` | 无 | `/etc/board.json` 的内容原样（provider 提供） | 9 |
| `getDHCPLeases` | `family?`（0/4/6；其它整数 → 2） | `{"dhcp_leases":[…]}` / `{"dhcp6_leases":[…]}` | 2 |
| `getDUIDHints` | 无 | `{ "<duid>" 或 "<duid>%<iaid>": {interface?, duid, iaid?, hostname?, macaddr?} }` | — |

`getDUIDHints`（`luci.c:1831-1900`）：只取 **v6 且有 duid** 的租约，按 `duid`（无 iaid）或
`duid%iaid` 键去重；回复是以该键为键的**对象**，字段序 interface?/duid/iaid?/hostname?/macaddr?。
复用 S1 的 leasefile 发现与解析，**可移植**（darwin 也能端到端测）。

- **这两个方法没有 ACL 检查**（policy 无 session 字段，handler 也不查）。
- `getBoardJSON` 失败（打不开/非 JSON/空对象）→ `9`。
- `getDHCPLeases`：family **类型不符**（如字符串）按 blobmsg policy 规则当作缺省 0，
  而不是 `2`；只有整数值不在 {0,4,6} 才回 `2`。
- leasefile 发现（`luci.c:394-473`）：uci `dhcp` 的 `dnsmasq`/`odhcpd` section 的
  `leasefile` option；没有对应 section → 回退 `/tmp/dhcp.leases`、`/tmp/odhcpd.leases`；
  打不开的文件跳过。
- 行格式与 `expires` 语义见计划 P3-5 节。两个关键点：**dnsmasq 的 ts==0 是永久（-1），
  odhcpd 的 ts==0 是过期（0）**；`01:` 前缀的 clientid 只在行内 MAC 解析失败时才兜底
  （上游 `if (!ea)`）。
- 每条回复按序：`expires`（-1 与过期都渲染成 0）、`interface?`、`hostname?`、`macaddr?`、
  `duid?`、`iaid?`、`ipaddr`/`ip6addr`（只回第一个地址）。

### 10.2.1 已实现（S2b，linux-only）

`getNetworkDevices`（`luci.c:648-896`）：逐 `/sys/class/net` 条目生成一张表（键是设备名）：
`name`、bridge 族的 `bridge`/`ports`/`id`/`stp`（brif 目录存在时）、`master`、`wireless`、
`up`、`mtu?`、`qlen?`、`devtype`（uevent 的 DEVTYPE=，缺省 "ethernet"）、
`ipaddrs[]`/`ip6addrs[]`（getifaddrs：address/netmask/remote?/broadcast?）、
`mac?`/`type`/`ifindex`/`parent?`（AF_PACKET，第一个匹配项）、
`stats`（十个 u64 计数器）、`flags`（七个位）、`link`（speed?/duplex?/carrier/changes/up_count/down_count）。

实现细节与偏离：
- 新绑定 `getifaddrs`/`freeifaddrs`（`bindings/libc.odin`，linux-only）。
- **iwinfo 字段未实现**（上游 dlopen libiwinfo 给无线设备加 hwmodes/crypto 等）——
  无线设备的 golden 对比会缺这些键，S2b′ 补。
- sysfs 文件打不开时按空串处理（与上游 readstr 一致，个别字段因此有上游同款的怪值，
  如 bridge 无 stp_state 时 stp=1）。
- darwin 回 `8`（无 sysfs；与 uci 写路径同一决策）。

### 10.2.2 已实现（S2c，linux-only）

`getWirelessDevices`（`luci.c:1098-1190`）：**对 netifd `network.wireless status` 的代理**
——`ubus_lookup_id("network.wireless")` + `ubus_invoke("status")`，把结果重塑为
「radio 名 → 该 radio 的字段」：跳过 `iwinfo` 键、`interfaces` 数组逐条去掉 `iwinfo`、
其余原样。netifd 对象不存在 → `4`（上游 `:1187`）。

实现细节与偏离：
- molly 用**同步** `ubus_invoke`（`bindings.ubus_invoke_fd`，在 ubus 服务线程里等回包）；
  上游用 async + `defer_request` 延迟回复（避免在方法回调里重入 uloop）。调用方可观测
  行为一致，服务端并发行为不同。
- **iwinfo（S2b′/S2c′）已实现**：`src/backend/iwinfo.odin` 运行时 dlopen
  `/usr/lib/libiwinfo.so*` + dlsym（`iwinfo_backend`/`iwinfo_close`/`iwinfo_format_hwmodes`
  与六张名字表），按接口（`phy_only=false`）与 radio（`phy_only=true`）两次取字段：
  signal/noise/channel/country/phy/txpower(+offset)/frequency(+offset)、`hwmodes`+`hwmodes_text`、
  `htmodes`、`hardware{id[],name}`、station 级的 quality/quality_max/bitrate/mode/ssid/bssid、
  `encryption{enabled, wep[]|wpa[]+authentication[], ciphers[]}`。
  **注意**：iwinfo 只在 `getWirelessDevices` 里用，`getNetworkDevices` 不调它。
- **版本敏感 + 失效保护**：`struct iwinfo_ops` 的字段顺序与名字表长度随 iwinfo 版本变
  （本实现按 iwinfo master 的 `include/iwinfo.h` 对齐）。为保证**绝不吐垃圾**：
  `ops.name` 必须是已知后端名（wext/nl80211/madwifi/wl/unknown），且 hwmodes 位不越过
  80211 表、mode 落在 OPMODE 表内——任一不满足就当作「没有 iwinfo」，一个字段都不加
  （与上游 dlopen 失败同路）。真机 golden 对比要专门核对这条。
- linux-only；darwin 回 8（darwin 的 provider 直接返回，不碰 iwinfo）。

### 10.2.3 已实现（S2d，linux-only）

`getHostHints`（`luci.c:1192-1828`）：五源按优先级合并（**数字越大越靠前**）——
netlink 邻居表 10、`/etc/ethers` 50、dhcp 租约 100、getifaddrs 200、uci 静态租约 250。
回复是以 **MAC 文本为键**的对象：`{ipaddrs:[v4 文本], ip6addrs:[v6 文本], name?}`；
同族地址按（prio DESC，地址字节 ASC）排序，同一地址保留优先级更高者。

实现细节与偏离：
- **netlink 用裸 socket**（`RTM_GETNEIGH` dump + 自己解 nlmsghdr/ndmsg/nlattr），不引
  libnl——少一个设备端运行时依赖。过滤：family v4/v6，`state & ~NUD_NOARP != 0`。
- **rrdns**（`network.rrdns` `lookup`）同步调用补主机名：v6 只在缺主机名时填、v4 **覆盖**；
  对象不存在时静默跳过（与上游 `invoke` 失败同样继续）。
- **照抄的上游行为**：uci 静态租约的 `ip` **实际从不生效**——上游类型判断写成
  `!= UCI_TYPE_STRING`（`:1499-1503`），正常 STRING 选项必然走 else → 不添加地址；
  所以静态租约只贡献 MAC + hostname。golden 对比会看到这一点。
- linux-only（netlink/ifaddrs）；darwin 回 8。

**S2b 的修正**：`sockaddr_ll` 的字段偏移第一版写错了（把 `sll_protocol` 当 `hatype`、
`ifindex` 取错位置）——真实布局是 family 0-1 / protocol 2-3 / ifindex 4-7 / hatype 8-9 /
pkttype 10 / halen 11 / addr 12-19（`linux/if_packet.h`），S2d 实现 ifaddrs 来源时发现并
一并修正（同一次提交）。

### 10.3 已知偏离（真机 golden 对比时核对）

1. IPv6 地址校验是**宽松**的（至少两个冒号 + hex），上游 `inet_pton` 严格——只影响
   「跳过非法行」的判定，租约文件是机器写的。
2. `duid2ea` 只实现了 DUID-LLT（`00010001`，len 28）与 `00030001`（len 20）两种；
   上游 switch 里可能还有其它 case，真机 golden 发现后补。
3. 输出超限、缓冲行为等 blobmsg/ustream 细节不适用（molly 直接回 JSON 文本）。

## 11. 入站 ACL（P3-6，molly 自持 `/usr/share/rpcd/acl.d/*.json`）

权威来源：`rpcd@e37ed9d8` 的 `session.c`（`rpc_login_setup_acls` `:1112-1125`、ACL 匹配引擎）
与上游 uhttpd 的 `ubus.c`（`json_errors` `:80-106`、`uh_ubus_allowed`）。实现分两层：
`src/backend/session.odin`（**S1**：acl.d 加载 + 匹配）、
`src/handlers/ubus_http.odin`（**S2**：`/ubus` 入口的前置校验）。

### 11.1 S1：acl.d 的加载与匹配

- **加载时机**：`login` 成功后按登录 section 的 `read`/`write` 组列表加载；**默认/哨兵会话**
  （没有 login section）只加载 `unauthenticated` 组——所以 `login` 本身也要先过前置校验。
- **组名匹配**：`fnmatch`（`luci-n*` 命中 `luci-network`）；`!` 前缀取反（`!luci-base`
  即使出现在 read 列表里，问 write 也被拒）；**write 蕴含 read**。
- **一份 acl.d 里两种形态都要认**：
  - 表形态 `"ubus": { "file": [ "list" ] }` → scope `ubus`、object `file`、functions = 列表；
  - 数组形态 `"uci": [ "system", "luci" ]` → scope `uci`、object = 数组元素、
    function 就是权限名（`read`/`write`）。
- **`access-group` 元 scope**（`session.c:1101-1103`）：组名自身也被授一条，供反查。
- ACL 与 `grant`/`revoke` 写进**同一张表**（`scope → object → [function]`）——
  `session.access` 不带 `object` 时回的就是这张表。

### 11.2 S2：`/ubus` 的前置校验（fail-closed）

上游 uhttpd 的顺序，逐条对齐：

1. 对象查找失败 → `-32000`；
2. `uh_ubus_allowed(sid, <对象>, <方法>)` 不过 → `-32002`（`Access denied`）；
3. 才轮到参数表校验 → `-32602`。

判定委托 session 的 ACL 引擎（scope `"ubus"`，object = ubus 对象名、function = 方法名）。
**fail-closed**：会话表里查不到 sid（例如已销毁）一律 `-32002`，不是放行。

与对象层 `6` 的区别：`-32002` 是**入口层**拒绝（HTTP 上是 JSON-RPC 的 `error.code`），
`6` 是**对象自己**的 `session.access` 拒绝（如 `uci`/`file` 各自的权限名检查）。

### 11.3 第三层：dispatcher 的 `depends.acl` 裁树（P3-6 收尾）

上游把 `depends.acl` 折进 `node.satisfied` / `node.readonly`（`apply_tree_acls`，`:435-445`），
但 molly 的菜单树是**跨请求缓存**的（`g_cache` + arena），会话相关的状态不能写在节点上——
所以改成**每请求按 sid 现算**（`src/luci/menu.odin` 的 `node_visible` / `node_acl_missing`）：

| 会话对要求的组 | 上游 | molly（`/cgi-bin/luci`） |
| --- | --- | --- |
| 一个都没拿到 | `check_acl_depends` → `null`，`satisfied=false`（裁出菜单） | 该节点**对本会话不可见**：直接请求 → `404`；`firstchild` 竞选跳过它 |
| 只有 read | `false`，节点保留、`readonly = true` | 可见；页面 `<dt>readonly</dt><dd>yes</dd>` + 只读提示横幅 |
| 任一组有 write | `true` | 正常（`readonly=no`） |

- **会话来源**：LuCI 写的 cookie（`sysauth_http` / `sysauth_https`，上游 `:963-966`），由
  `src/handlers/cgi_luci.odin` 解析后交给 `luci.dispatch`；没有 cookie 就是「无会话」。
- **判权口径**：路径上所有节点的组名取**并集**（上游 `ctx.acls`），其中**任一**有 write 就不算
  只读（上游 `check_acl_depends` 返回的是 `writable`）。
- **`firstchild` 当选的那条支路**也并进并集（上游 `resolve_firstchild` 里的 `ctx_append`）。
- **授权按键精确命中**：`access-group` 的名字就是 acl.d 的文件名，不套 `fnmatch`（上游查的是
  acl dump 映射的键）。
- 判定入口是 `backend.session_acl_level(sid, groups)`，三态 `Missing` / `Read_Only` / `Writable`
  与上游 `null` / `false` / `true` 一一对应。

### 11.4 测试与 fixture

`tests/fixtures/acl.d/`（darwin 的 `session_acl_dir()` 指向它）三个文件：
`unauthenticated.json`（真机同款：只授 `session` 的 `access`/`login`）、
`luci-base.json`（真机 `luci-base` 的裁剪版）、`smoke-full.json`（**测试专用组，真机不存在**：
把 `/ubus` 的前置校验放行，好让既有断言继续验各对象的对象级语义）。

单元：`src/backend/session_test.odin` 的 `test_session_login_test_permission`
（组列表判定：`fnmatch`、`!` 取反、write 蕴含 read）、`test_session_load_acls_from_fixtures`
（表/数组两种形态）、`test_session_default_session_acls`（哨兵会话只有 unauthenticated）；
`src/luci/menu_test.odin` 的 `test_acl_prunes_and_readonly`、
`test_acl_first_child_skips_and_marks_readonly`（同一棵缓存树、不同会话给出不同可见性/只读）、
`test_login_required_without_session` / `test_login_not_required_with_session` /
`test_auth_login_last_node_wins`（无会话 → 登录提示；有会话 → 照 ACL 解析；`ctx.auth` 最后者胜）。

`tests/http_smoke.sh` 的 dispatcher 节：带 cookie 的登录会话用 `-b "sysauth_http=$P2SID"`；
**无 cookie（= 要登录）**验 403 + `X-LuCI-Login-Required` + 提示页正文与路径；**缺组**则用
默认/哨兵会话（有会话但没权限，因而不触发登录分支）验 404 与 firstchild 跳过；再用撤销 write
的只读会话验 `readonly=yes`。

### 11.5 已知偏离（真机 golden 对比时核对）

1. **缺组时的状态码**：上游在「节点已经被算进 `ctx.path`」这个角上会回 `403 Forbidden`
   （`dispatcher.uc:996-1000`）；molly 把缺组一律当「节点不可见」→ `404`。上游下降时
   `!satisfied` 就 `break`，所以那条 403 分支实际上很难走到；molly 的模型里两者同源，
   语义更自洽。真机 golden 对比时留意这个差异。
2. **登录页的正文**：上游 `:930-960` 会先拿表单里的 `luci_username` / `luci_password` 试登录
   （成功则 `Set-Cookie` 并继续去目标页），拿不到会话才回 403 + `X-LuCI-Login-Required: yes`
   + 主题的 `sysauth` 登录表单。molly 的内置 dispatcher **只认既有 cookie**（登录表单与
   `Set-Cookie` 属 `--luci-cgi` 的 ucode 侧，ADR 0003）：状态码与响应头对齐上游，
   正文换成可断言的登录提示页（§5.3）——golden 对比时差异只在正文。
3. **测试专用组**：`smoke-full.json` 在真机上不存在，golden 对比时会看到差异。
4. **ACL 的存储格式**：molly 沿用 JSON 化的 `acls`（上游是 blobmsg 数组），
   对 `session.access` 的可观测结果一致。
5. **写单元测试时不要用 fixture 的 root 登录去断言「未授权 = false」**：root 的
   `read/write = '*'`（与真机 `rpcd.config` 的默认值一致）在 P3-6 起会把 acl.d 里的
   **全部**组加载进来，包括测试专用的 `smoke-full`（`ubus: *`）——那样任何 `access`
   都是 `true`。要测「acl.d 驱动的窄 ACL」，用 `acl_test_login` 自己构造窄列表
   （见 `session_test.odin` 的 `test_session_acl_grant_revoke_access`）。

## 12. 契约的权威来源与验证方式

| 契约 | 权威来源 | molly 的验证 |
|---|---|---|
| `/ubus` 各形态、错误码、会话来源 | 上游 uhttpd 的 `ubus.c`（25.12.2 对应提交） | `tests/http_smoke.sh` 的 `/ubus` 两节 + `-32000/-32601/-32700/-32602` 断言 |
| dispatcher 语义（建树、`depends.fs`/`uci`、firstchild、通配、alias、**`depends.acl` 裁树与只读**、**`auth.login` → 403 + 登录提示**） | `modules/luci-base/ucode/dispatcher.uc`（luci `d6167ea`） | `tests/http_smoke.sh` 的 dispatcher 节 + `src/luci/menu_test.odin` + `.ai-memory/r8_probe.py` |
| HTTP 层上限与 keep-alive | uhttpd 行为（部分自定，风险 R7） | `tests/http_smoke.sh` 的「上限与错误码」「keep-alive」「管道请求」节 |
| 静态文件与 MIME | uhttpd 行为 | `tests/http_smoke.sh` 静态节 + `src/http/mime_test.odin` |
| `luci-rpc` 对象（6 方法：board/leases/duid/network/wireless/host hints） | `luci@d6167ea` 的 `luci.c` | `src/backend/luci_object_test.odin`（4 用例组）+ `tests/http_smoke.sh` 的「P3-5 luci-rpc 对象」节（17 项）；S2b/c/d 三个设备绑定方法只能交叉编译 + 设备验证 |
| `file` 对象（8 方法、各方法的权限名、符号链接复查、exec 的两层 ACL） | `rpcd@e37ed9d8` 的 `file.c` | `src/backend/file_object_test.odin`（2 用例组）+ `tests/http_smoke.sh` 的「P3-4 file 对象」节（26 项） |
| `uci` 对象（S1：`configs`/`get` 的回复形状、`.index`、`match`/`type`、ACL 钩子；S2：`changes` 的三形态、`state`/`commit`/`revert` 的状态码、savedir 清理；S3：五个写操作的参数校验、写计划与错误聚合；S4：apply 系的中性路径（5/4/2 与状态码顺序）） | `rpcd@e37ed9d8` 的 `uci.c` | `src/backend/uci_object_test.odin` + `uci_write_test.odin`（11 用例组）+ `tests/http_smoke.sh` 的「P3-3 uci 对象」节（36 项） |
| `session` 对象（10 方法、状态码、dump 形状、ACL 匹配） | `rpcd@e37ed9d8` 的 `session.c` | `src/backend/session_test.odin`（11 用例）+ `tests/http_smoke.sh` 的「P3-2 session 对象」节（13 项） |
| 入站 ACL（acl.d 两种形态与加载、`!` 取反、`/ubus` 前置校验顺序与 `-32002`、dispatcher 的 `depends.acl` 裁树与只读、无会话 → 403 + 登录提示） | `rpcd@e37ed9d8` 的 `session.c` + 上游 uhttpd 的 `ubus.c` + `dispatcher.uc` 的 `check_acl_depends` / `resolve_firstchild` / `:930-960` | `src/backend/session_test.odin`（3 用例）+ `src/luci/menu_test.odin`（5 用例，含 3 个登录判定）+ `tests/http_smoke.sh` 的 `/ubus`、P3-2、dispatcher 三处 ACL/登录断言 |
| 真机 golden 对比 | 原厂固件响应样本 | **待第 7 步**（替换前须先在设备上抓全量样本存档） |

其它文档：[`build-and-run.md`](build-and-run.md)（配置与部署运行）、
[`testing.md`](testing.md)（三层测试与执行流程）、[`architecture.md`](architecture.md)（分层与依赖规则）。
