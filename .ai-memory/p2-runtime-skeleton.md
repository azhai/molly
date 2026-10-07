# P2：Odin 版 LuCI 替换层 —— 运行时骨架

## Context（为什么做这件事）

目标是**用 Odin 复刻 ImmortalWrt 的 LuCI**，替换服务端三层：uhttpd（HTTP + `/ubus` JSON-RPC + CGI）、rpcd（ubus 上的 `session`/`uci`/`file`/`luci` 对象，提供认证/会话/ACL）、ucode dispatcher（菜单树 → 路径解析 → ACL → 渲染）。复用不动的部分：`/etc/config`（uci）、ubusd 消息总线、`/www` 静态文件。

目标设备 NetCore N60 Pro（MT7986A / 4×Cortex-A53 / 512MB RAM / 128MB SPI-NAND），系统 ImmortalWrt 25.12.2（aarch64_cortex-a53、musl、动态链接），内存目标 <2MB RSS。

P0/P1 已完成：工具链跑通（`toolchain/setup.sh` 交叉编译出四个库、SONAME 与设备一致）、Odin 绑定 libuci/libubus 可用、obj + zig cc 两段式链接产出合规 aarch64 ELF（`spike/01-toolchain/`）。

**运行时行为尚未在真机验证**（用户已同意暂缓，无设备）。于是 P2 的核心矛盾是：不能依赖设备，又必须能验证。解决办法是把 HTTP/路由/dispatcher 做成平台无关代码，在 **macOS 原生**上跑通、只用假数据替换 uci/ubus。这就是本计划的中心思想。

## 已验证的事实（都有实证，实施时不必重新探索）

| 结论 | 证据 |
|---|---|
| Odin **没有** HTTP 库，必须自己写 HTTP/1.1 | `core/net/http` 不存在；`core:net` 只有 socket |
| `core:net` 服务端够用 | `listen_tcp(Endpoint, backlog)`、`accept_tcp(TCP_Socket, options)`、`recv_tcp`/`send_tcp`、`close`、`set_option(Reuse_Address)`；`Socket_Option` 含 `Receive_Timeout`/`Send_Timeout` |
| 超时在 Linux 侧**有实现** | `core/net/socket_linux.odin:382` 处理 `.Send_Timeout, .Receive_Timeout` |
| `core:encoding/json` 可用（marshal/unmarshal） | `core/encoding/json/{marshal,unmarshal}.odin` |
| 线程并发可用 | `thread.create_and_start_with_poly_data(data, fn, ...)`；musl pthread 默认栈 128KB，故「一连接一线程」内存可接受 |
| SIGPIPE 需自设 | `core:sys/posix/signal_libc.odin` 提供 `signal`/`SIGPIPE`/`SIG_IGN` |
| `#+build` 语法：单行逗号 = OR，多行 = AND | `core/net/interface_posix.odin:1` 是 `darwin, openbsd, netbsd`；`socket_others.odin:1-6` 用六行表达 AND |
| `ubus_invoke` 不可用，须用 `ubus_invoke_fd(..., -1)` | 已有 spike 实证 |
| `blobmsg_format_json` 是 static inline，须用 `blobmsg_format_json_with_cb(attr, list, nil, nil, -1)` | `libubox/blobmsg_json.h:31` vs `:35` |
| **`libblobmsg_json.so.20260213` 已在我们 sysroot 里，且导出所需符号** | `llvm-nm -D` 见 `blobmsg_add_json_from_string`、`blobmsg_format_json_with_cb`；SONAME = `libblobmsg_json.so.20260213` |
| `struct blob_buf` 布局 = `{^blob_attr head; fn(^blob_buf,c.int)->bool grow; c.int buflen; rawptr buf}`，aarch64 上 32 字节 | `libubox/blob.h:64-69` |
| 忽略 SIGPIPE：`posix.signal(posix.Signal.SIGPIPE, auto_cast posix.SIG_IGN)` | `signal_libc.odin:32` 签名 `signal(Signal, proc "c" (Signal))`；`SIG_IGN :: rawptr(uintptr(1))`（:113），必须 `auto_cast` |
| `net.parse_endpoint` 返回 `(Endpoint, ok: bool)`，**只接受数字地址、不做 DNS** | `core/net/addr.odin:390`。所以 `--listen` 不能收主机名 |
| lld 默认按 `--as-needed` 处理 `-l`：未被引用的库不进 `DT_NEEDED` | 第 1 步产物只有 `libc.so`；加 `-Wl,--no-as-needed` 诊断链接后四个库的 SONAME 全部正确出现在 NEEDED 里，证明 `build.sh` 的库列表与顺序无误 |
| 工作线程的默认 context：`init_context=nil` 时用 `runtime.default_context()`（堆分配器），线程退出时**不会**销毁 temp_allocator | `thread.odin:592-620`。所以工作线程里可以安全用堆，但用 `temp_allocator` 就要自己收尾——本项目改为每连接私有 arena |
| `dynamic_arena_init` 的默认 `block_allocator` 是 `context.allocator` | `mem/allocators.odin:1659` |
| **枚举上的 `switch` 里写 `case:` 默认分支不算「已覆盖」**，编译报 `Unhandled switch cases` | 最小复现：`switch e { case .A: …; case: … }` 报 `B/C unhandled`；`#partial switch` 才通过。所以第 3 步改用 `if/else` 表达「其余情况」，别在这上面浪费时间 |
| Odin 不允许给 proc 参数重新赋值（`raw = raw[:cut]` 报 `Cannot assign to 'raw' which is a procedure parameter`） | 同上，改用本地变量 |
| 惯用的零拷贝字节↔字符串转换是 `transmute(string)(byte_slice)` | `core/encoding/base64/base64.odin:138`；`transmute([]byte)(str)` 在本项目 `send_raw` 里已在用 |
| **uhttpd 的 REST API 会话来源是 `Authorization: Bearer <sid>`，不是 `Ubus-Session`** | upstream `ubus.c` 的 `uh_ubus_get_auth()`：只认 `authorization` 头且要求 `Bearer ` 前缀，否则回退到 32 个 0。openwrt-devel 邮件列表里的真实请求也带 `Authorization: Bearer 3653e6...`（2020-08-18） |
| `GET /ubus/list` 的正文形状：`{"<对象路径>":{"<方法名>":{"<参数名>":"<类型>"}}}`，类型取值只有 `boolean/number/string/array/object/unknown` | `ubus.c:602-656`（`uh_ubus_list_cb`，`add_object = !path`，逐字映射表在 :630-649）；外层再 `blob_for_each_attr` 拷进同一 JSON（`uh_ubus_handle_get_list` :240-259） |
| `GET /ubus/list/<path>` 的正文形状：就是该对象的签名本身 `{"<方法名>":{...}}`，**没有**外层对象名包一层 | 同上，`add_object = !path` 为假时不开外层 table |
| `GET /ubus/list` 出错的响应是 500 `Ubus Protocol Error` + `{"code":<err>,"message":"<ubus_strerror>"}`（**没有** jsonrpc 包裹） | `ubus.c:249-253` + `uh_ubus_ubus_error` :210-213 |
| 旧式 `POST /ubus` 与 `POST /ubus/` 都算旧式（尾斜杠等价） | `ubus.c:912-917` |
| 旧式 `result` 恒为数组 `[ret, {...}]`，**错误与空结果也是**（错误在 ret 里，不在 `error` 字段） | `uh_ubus_request_cb` :375-389 |
| 旧式 `method:"call"` 要求 `params` 正好是 `[sid, obj, func, table]` 四项且都在，缺一即 parse error；`method:"list"` 另走 `uh_ubus_send_list`（`params` 不是数组 → `result` 是对象名数组；是数组 → `result` 是详细表） | `parse_call_params` :725-754、`uh_ubus_handle_request_object` :790-817、`uh_ubus_send_list` :658-694 |
| 新式 `POST /ubus/call/<对象路径>`：body 是 JSON-RPC，`method` 直接是 ubus 方法名，`params` 是参数表；sid 来自 `Authorization` 头 | `uh_ubus_call` :860-904。成功回 `{"jsonrpc","id","result":{...}}`，失败回 `{"jsonrpc","id","error":{"code":ret,"message":ubus_strerror}}`（:495-515） |
| 上游在每次 invoke 前会调 `session.access` 做前置 ACL 校验（除非 `ubus_noauth`） | `uh_ubus_allowed` :224-237。**P2 不做**（决策 7），P3 换成 molly 自持 acl.d |
| JSON-RPC 错误码表：parse -32700 / invalid request -32600 / method not found -32601 / invalid params -32602 / internal -32603 / object not found -32000 / session not found -32001 / access denied -32002 / timeout -32003 | `ubus.c:80-93` |
| `/ubus` 上非 GET/POST/OPTIONS 的方法一律 400；`OPTIONS` 回 200 + `application/json` + `Content-Length: 0`；`GET /ubus`、`GET /ubus/<非 list\|subscribe>` → 404 空 body | `ubus.c:336-352`（GET）、`uh_ubus_handle_post` :906-932、`uh_ubus_handle_request` :977-996 |

被复刻的契约（不要自己发明，已有上游实证）：
- 旧式：`POST /ubus`，`{"jsonrpc":"2.0","id":1,"method":"call","params":["<sid>","<obj>","<method>",{...}]}` → `result` 恒为 `[ubus返回码, {...}]`；未认证 sid = 32 个 0。
- 新式 RESTful：`GET /ubus/list`、`GET /ubus/list/<path>`、`POST /ubus/call/<path>`（`method` 直接是 ubus 方法名）、`GET /ubus/subscribe/<path>`（SSE）；会话取 `Authorization: Bearer <sid>` 头，无该头则回退到 32 个 0（上游 `uh_ubus_get_auth`）。**注意：不是 `Ubus-Session` 头**，早先的计划写错了，已按上游源码更正。
- 错误：`{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"Access denied"}}`。
- LuCI：`PATH_INFO` 是 `/cgi-bin/luci` 之后的路径；菜单来自 `/usr/share/luci/menu.d/*.json`；前端资源在 `/www/luci-static/`；cookie `sysauth_http`（http）/`sysauth`（https）。

## 目录结构（产品代码放仓库根，与 `spike/`、`toolchain/` 平级）

```
build.sh                     构建入口：--host（macOS 原生）/ --target（aarch64）
src/main.odin                参数解析、装配、启动、信号处理、路由分发（handle）
src/http/uri.odin            URI 路径规范化：拦 .. / %2e%2e / NUL（安全边界）
src/http/server.odin         监听、accept 循环、连接上限、线程生命周期
src/http/request.odin        HTTP/1.1 请求解析状态机
src/http/response.odin       响应生成、keep-alive、Connection 语义
src/http/limits.odin         各类上限常量（头大小/个数、body、超时）
src/http/mime.odin           扩展名 → Content-Type
src/handlers/static.odin     /www 静态文件
src/handlers/ubus_http.odin  /ubus（旧式）+ /ubus/list|call（新式）
src/handlers/cgi_luci.odin   /cgi-bin/luci dispatcher
src/luci/menu.odin           读 menu.d/*.json → 菜单树
src/luci/render.odin         占位页渲染（P2 范围）
src/backend/backend.odin     共享类型 + 跨平台 proc 契约说明
src/backend/linux.odin       #+build linux  —— 真 libuci/libubus/libblobmsg_json
src/backend/darwin.odin      #+build darwin —— 假数据
src/backend/bindings/*.odin  仅 linux：uci / ubus / blobmsg / libc 的 foreign import
tests/http_smoke.sh          本地 curl 验收脚本
tests/fixtures/menu.d/*.json macOS 测试用的菜单 fixture
tests/fixtures/www/          macOS 测试用的 docroot（index.html / luci-static/*）
```

**与规划的结构偏差**（第 3 步实施后记录）：路径规范化没有单独放 `src/router.odin`，而是放进叶子包 `src/http/uri.odin`——它是纯 URI 处理、且所有 handler 都要用，放在 `http` 里才不会出现「main ↔ handlers 互相 import」。路由分发留在 `main.odin` 的 `handle`（规范化 → `/ubus` → `/cgi-bin/luci` → 静态文件，共四个分支）。**第 6 步已确认不再拆出 `router.odin`**：两个前缀 handler 都自带内部路由（`/ubus` 的 GET/POST/OPTIONS 分流、`/cgi-bin/luci` 的 kind 分流），`handle` 只剩四次「前缀判断 + 转交」，再包一层只会增加一层跳转而没有消除重复。

`spike/01-toolchain/` **冻结不动**，作为工具链回归基准（出问题时可二分定位是工具链还是产品代码）；只把已验证的 `uci_ptr` 布局与两段式链接配方搬进 `src/backend/bindings/` 与 `build.sh`。

## 关键设计决策

1. **并发模型：一连接一线程 + 原子计数上限（默认 32，超额 503 + `Connection: close`）**。理由：`ubus_invoke_fd` 是阻塞调用，单线程 epoll 会被一次慢 ubus 调用拖住所有连接；musl 线程栈 128KB，32 连接的栈开销 <8MB，与 <2MB 基线目标不冲突（基线是空载 RSS）。代价见风险 R4。
2. **平台分层用 build tag + 同名 proc，不引入 vtable**。`src/backend/{linux,darwin}.odin` 提供同名同签名的 proc，共享层直接调用。签名漂移会在编译期暴露（因为 macOS 上每次构建都会走 darwin 那份）。避免为一个只有两个实现的分支引入间接层。
3. **ubus context 是全局单例 + `sync.Mutex` 串行化**（libubus 非线程安全）。持锁期间不写 socket，避免慢客户端拖住总线。
4. **ubus 的 JSON 互转直接用 libubox 现成函数**，不自己写 blobmsg 编解码：入参 `blobmsg_add_json_from_string(&buf, str)`，出参 `blobmsg_format_json_with_cb(attr, true, nil, nil, -1)`。请求 buf 与回复 buf 必须是两个 `blob_buf`（对齐 uhttpd 的做法）。`_with_cb` 返回 malloc 内存，**由调用方 `libc.free`**；回调里的 msg 只在回调内有效，必须在回调内就转成字符串。
5. **路由顺序**：路径规范化（拦 `..`、NUL、`%2e%2e`）→ 前缀 `/ubus`（`/ubus` 旧式；`/ubus/list`、`/ubus/call/`、`/ubus/subscribe/` 新式）→ 前缀 `/cgi-bin/luci` → 其余按 docroot `/www` 静态文件（`/luci-static/*` 天然落在 `/www/luci-static/*`，不需要别名）。
6. **P2 的 dispatcher 只做到**：读 menu.d → 建树 → 路径逐段下降 → 命中且 `action.type=="view"` 渲染占位页（标题 + view 路径 + 明确的「ACL 未实施」横幅）；`alias`/`firstchild` 支持回落；其它 type 与未命中分别 501 / 404。**认证、ACL、模板渲染全部留到 P3**。P2 也**不写** `/tmp/luci-indexcache`（避免与真 LuCI 的缓存格式冲突），只做进程内 mtime 失效缓存。
7. **过渡期显式标注**：P2 不注册任何 ubus 对象，`session`/`uci`/`file`/`luci` 仍由设备上的 rpcd 提供，molly 只做 HTTP 侧转发。启动时打印一行 `WARN: transitional mode - ubus objects still provided by device rpcd`，`README` 顶部加「阶段状态」表。P3 接手：注册这四个对象、把 ACL 校验从「转发给 rpcd」换成 molly 自持的 `/usr/share/rpcd/acl.d/*.json`。
8. **`/ubus/subscribe`（SSE）P2 返回 501**。它需要 uloop 事件线程，与「一连接一线程」模型不兼容，留到 P3 一并解决（见风险 R4）。

## 分步实施计划（按依赖顺序）

### 进度日志与续跑点

**续跑点（上下文重置后先读这一行）**：P2 第 1–6c 步已完成（门禁全绿 + `r8_probe.py` `不一致条目: 0 / 11`）；**P2 已移交 P3** —— P3 的计划与进展在 `.ai-memory/p3-luci-server.md`（P3-0 取证 / P3-1 R4 机制 / P3-8 渲染路线待拍板）；P2 第 7 步的真机项（RSS 压测、golden 对比、linux 侧 uci 遍历的运行期验证、非严格 JSON 的 ucode 容忍性）并入 P3-0 执行。设备已确认可达 **192.168.1.1**。本文件是计划 + 进展的唯一**权威**来源；`.trae/documents/p2-runtime-skeleton.md` 只是给外部工具看的镜像，两者不一致时以本文件为准（AGENTS.md §9）。

| 步骤 | 状态 | 最近一次门禁实测 |
|---|---|---|
| 1 构建骨架 | 已完成 | `./build.sh --host` / `--target` 通过；host 549KB、target 194,544B |
| 2 HTTP 层 | 已完成 | `./tests/http_smoke.sh` 通过 18，失败 0 |
| 3 静态文件 | 已完成 | 通过 35，失败 0；target 210,304B |
| 4 backend 分层 | 已完成 | 通过 52，失败 0；target 211,152B |
| 5a Linux 绑定 | 已完成 | 通过 52，失败 0；host 627,208B、target 215,136B |
| 5b JSON-RPC 协议层 | 已完成 | 通过 85，失败 0；host 824,328B、target 288,688B |
| 6 dispatcher 骨架 | 已完成 | 通过 108，失败 0；host 868,248B、target 307,920B（NEEDED 新增 `libuci.so.20250120`） |
| 6b dispatcher 语义对齐 | 已完成 | 探针 `不一致条目: 0 / 11`（基线 8/11）；smoke 通过 128 失败 0；host 871,320B、target 311,008B（五项 NEEDED） |
| 6c 三层架构文档 + 测试体系 | 已完成 | `./tests/unit.sh` 3 包 19 用例全绿；`docs/{testing,architecture,interfaces}.md` 三件套齐备；`AGENTS.md` §4.1 门禁含 unit |
| 7 真机联调 | 待设备 | — |

会话记录（新在前）：
- 2026-09-26 — **第 6c 步（后半）：架构与接口文档**。新增 `docs/architecture.md`（三层职责边界、模块清单、一次请求的调用链、六条单向依赖硬规则 + 三条可复核的 grep、build tag + 同名 proc 的分层机制、与上游语义的对应表、P2 边界）与 `docs/interfaces.md`（进程 CLI 与启动输出、HTTP 状态码/头语义/上限、路由表、`/ubus` 四个形态与错误码表、`/cgi-bin/luci` 的 PATH_INFO 与占位页结构、backend 窄接口、契约权威来源与验证方式）。两份文档的数据全部来自本次实际读过的代码与实测常量（`limits.odin`、`Status` 枚举、`ubus_http.odin` 的路由体、`main.odin` 的 `handle`）。顺带修掉 `handlers/ubus_http.odin` 头部注释的一处失实：`POST /ubus/subscribe/*` 实际走「/ubus/<非 call>」→ 404，只有 GET 该前缀才回 501（代码与 smoke 断言为准）。`README.md` 文档索引补两行。
  门禁复核（只改文档 + 一行注释，仍按 §4.2 重跑留痕）：`./tests/unit.sh` **通过 3 失败 0** → `./build.sh --host` 890,920B → `./tests/http_smoke.sh` **通过 128 失败 0** → `./build.sh --target` 313,152B → `r8_probe.py` **`不一致条目: 0 / 11`**。`architecture.md` §5 的三条依赖规则 grep 实测均为空（规则当前成立）。
  下一步：第 7 步真机联调（待设备）。
- 2026-09-26 — **第 6c 步（前半）：单元测试层 + testing.md**。
  1. 新增 `src/http/{uri,mime}_test.odin`、`src/luci/menu_test.odin`、`src/backend/backend_test.odin`（`@(test)` + `core:testing`，共 **19 个用例**：http 4 / luci 13 / backend 2），每条断言注明对应的上游 `dispatcher.uc` 行号；新增单命令入口 `tests/unit.sh`（按包跑 `odin test -collection:molly=src ...`，输出与门禁同格式）。
  2. **实测踩到的坑（已修）**：① `odin test` 默认 4 线程并行 → 共享全局 arena 会互相踩，表现为 `Segmentation_Fault` + `Backing array allocator must be initialized`；改为每个用例 `mk_arena()` / `defer drop_arena(ar)`。② `expect_value` 的第 4 个参数是 `#caller_location` 不是消息，传字符串编译报错。③ **`odin build` 也会类型检查 `@(test)` 过程体**（在测试体里写一个不存在的符号，`./build.sh --host` 立刻报 `Undeclared name`）——好处是测试不会静默腐烂，代价是 `--target` 也把它们编进对象文件。
  3. 文档：新增 `docs/testing.md`（三层测试的覆盖范围/判据/执行流程/覆盖边界、加用例的步骤）；`AGENTS.md` §4.1 门禁改为「unit → host → smoke（+ target）」，§10 与 Do/Don't 同步；`README.md` 加 `./tests/unit.sh` 与文档索引。
  4. 门禁实测（顺序 unit → host → smoke → target）：`./tests/unit.sh` **通过 3，失败 0（包数）**、19 用例全绿无泄漏 → `./build.sh --host` 891,032B → `./tests/http_smoke.sh` **通过 128 失败 0** → `./build.sh --target` 313,152B（NEEDED 仍五项）；`r8_probe.py` 仍 `不一致条目: 0 / 11`。
     **体积变化的原因**：`odin build` 会类型检查并编入 `@(test)` 过程体，所以 host 871,304 → 891,032B（+19.7KB）、target 311,008 → 313,152B（+2.1KB，`-o:size` 做了大部分死代码消除）。取舍已记录：保留「测试进 build」是为了让坏测试在编译期就暴露（`AGENTS.md` §4.1），代价是这几十 KB，与设备侧 <2MB RSS 目标无关。
  5. 下一步（6c 后半）：`docs/architecture.md` + `docs/interfaces.md`。
- 2026-09-26 — **第 6b 步落地**（按上游 `d6167ea` 的 `dispatcher.uc` 对齐 dispatcher 语义）：
  1. `src/luci/menu.odin`：`apply_spec` 改**逐键**处理（未知键 / 类型不符只跳过该键；未出现的键不再写默认值，同路径多文件变成逐键合并）；通配 action 独立成 `wildcard_action_type/path` + `has_wildcard_action`，并补回 `node.wildcard = hit_wildcard`（:395）；`check_depends` 族重写（fs 四类型 + object-AND / array-OR、uci 的 `true` / 具名 section / `@type` / option 值精确匹配、认不出的取值一律忽略 ⇒ 满足）；新增 `effective_action`（:1006-1011），`render.dispatch` 在**下钻结束后**用它取 action。
  2. `src/backend/`：契约把 `uci_has` 换成 `uci_config_sections`（新增 `Uci_Section` / `Uci_Option`）；darwin 假配置改成 section 表（含匿名 `@switch`、list 型 option、空 config）；linux 侧按 `uci.h:436-470` 的公开结构体 + `uci.h:552` 的 `uci_foreach_element` 语义遍历，`bindings/uci.odin` 新增 5 个结构体与 5 条 `#assert` 尺寸/偏移断言。
  3. 测试与证据：fixtures 与 smoke 同步（`badfield` 改 200 并按上游「只忽略该键」重写说明、`depends.fs/uci` 的字符串形式改 object 形式另加一条「非 object ⇒ 忽略」用例、新增 12 条 depends 与 2 条通配断言）；`r8_probe.py` 的 part A 从「静态量化旧语义偏差」改成「按新语义核对 + 列剩余偏差」。
  4. 三件套实测：`./build.sh --host` 871,320B → `./tests/http_smoke.sh` **通过 128 失败 0**（原 108：改写 4 条 + 新增 20 条）→ `./build.sh --target` 311,008B（NEEDED 五项，含 `libuci.so.20250120`）。`python3 .ai-memory/r8_probe.py` → **`不一致条目: 0 / 11`**（修复前 8/11），part A 剩余已知偏差 **7 / 413**（`luci-app-sms-tool-js` 尾逗号，待第 7 步）。
  5. **验证边界**：probe 与 smoke 只覆盖 darwin 侧；linux 侧 `uci_config_sections` 本步只做到编译 + 链接校验，`#assert` 保证的是结构体尺寸/偏移而非 libuci 运行期行为——运行期正确性属第 7 步。
  6. 文档同步：`README.md`（阶段表加 6b 行、`128 项`）、`docs/build-and-run.md`（`通过 128`、6b 覆盖行）。下一步 6c（三层架构文档 + 测试体系）。
- 2026-09-26 — R8 离线抽样（无设备）：按 25.12.2 `feeds.conf.default` 钉住的 luci 提交 `d6167ea` 取全部 138 个 menu.d JSON（413 条路径）与同一提交的 `dispatcher.uc`，逐条核对。**R8 结论：不成立** —— `dispatcher.uc:400-402` 的隐式中间层本就是 `satisfied: true`，molly 与上游一致（真实样本 8 例、合成探针 `imp/a/b` 实测一致）。但同段代码查出 4 类真实偏差（D1 schema 外键丢弃整条 / D2 `depends.fs` 的 array-任一、object-全部、`absent` 取反 / D3 `depends.uci` 逐 config 精确匹配 / D4 `wildcardaction` 与 `action` 分离），合成探针实测 **8/11 不一致**，真实样本受影响 **117/413**。据此新增 **6b 步**（修 dispatcher 语义），证据与修法见 `.ai-memory/r8-menu-sample.md`。本次只加分析脚本与文档，**未改产品代码**，故门禁沿用上一条 108/108。
- 2026-09-26 — 第 6 步 dispatcher 骨架落地并回写本文件：新增 `src/luci/{menu,render}.odin`、`src/handlers/cgi_luci.odin`、`src/backend/bindings/uci.odin`（第 1 步遗留验收项「NEEDED 出现 `libuci.so`」在此闭合）；改 `src/http/server.odin`（`menu_dir`）、`src/main.odin`（`--menu-dir` + 路由）、`src/backend/{backend,linux,darwin}.odin`（`uci_has` 契约与两实现）；新增 `tests/fixtures/menu.d/*.json` 与 23 条 smoke 断言。三件套实测：`./build.sh --host` 868,248B → `./tests/http_smoke.sh` 通过 108 失败 0 → `./build.sh --target` 307,920B。同批同步了 `README.md`（阶段表、`--menu-dir`、108 项）与 `docs/build-and-run.md`（五个 NEEDED、`--menu-dir`、第 6 步覆盖行），仓库文档与 `.trae/documents/` 镜像均已更新。
- 2026-09-26 — 文档回写后重跑 `./build.sh --host` + `./tests/http_smoke.sh` 复核，仍为 **通过 108，失败 0**（本次只改文档，重跑是为了留痕）；`--target` 未重跑（无代码改动，沿用本日 307,920B 那次）。
- 2026-09-26 — 全量回归取证（写文档前先验证命令可跑）：`./build.sh --host` 通过（824,328B）→ `./tests/http_smoke.sh` 通过 85 失败 0 → `./build.sh --target` 通过（288,688B，NEEDED 仍是 ubus / blobmsg_json / ubox / libc 四行）。同时新增 `README.md` + `docs/development-environment.md` + `docs/build-and-run.md`（中文单语），并在 `AGENTS.md` §8 登记这两个文档面的语言与同步规则。**代码未改动**。
- 2026-09-26 — 计划文档归位：把 `.ai-memory/p2-runtime-skeleton.md` 定为权威副本、`.trae/documents/` 保留为镜像，并把 `.ai-memory/` 从 git 暂存区移除（`AGENTS.md` §1.1、§9：工作记忆永不提交）。本次只改文档、未改代码，故门禁未重跑，上表沿用第 5b 收尾时的那次绿。
- 2026-09-26 — 第 5b 收尾并回写本文件；同会话窗口发生过一次上下文重置，本文件被重新回灌为完整状态（各步细节见本表下方条目）。

1. **构建骨架** —— **已完成**。`build.sh --host` / `--target` 均跑通；`--target` 在既有两段式上加了 `-lblobmsg_json`。
   产物与实测：`build/molly-host`（Mach-O arm64，549KB）在 `--listen 127.0.0.1:18080` 下 `curl -sv` 得 `HTTP/1.1 200 OK` + `Content-Length: 13`；`build/molly` 经 `llvm-readelf` 核验为 `ELF64 / EXEC / AArch64 / interpreter /lib/ld-musl-aarch64.so.1`，194,544 字节。
   **与验收原文的偏差**：第 1 步产物 NEEDED 里只有 `libc.so`，没有 uci/ubus/blobmsg——原因是 lld 默认 `--as-needed`，而第 1 步代码还没引用这些库的符号。用一次性诊断链接（加 `-Wl,--no-as-needed`）已证实四个库都能按正确 SONAME 进入 NEEDED，故该验收项在第 5 步首次真正调用这些符号时自然满足。
   新增源文件：`src/http/limits.odin`、`src/http/response.odin`、`src/http/server.odin`、`src/main.odin`。
2. **HTTP 层** —— **已完成**。新增 `src/http/request.odin`（解析器）、重写 `src/http/response.odin`（状态码 + `respond`）、`src/http/server.odin` 加 keep-alive 循环、`tests/http_smoke.sh`。
   验收：`tests/http_smoke.sh` **18/18 通过**（基本响应、keep-alive 复用、HTTP/1.0 默认关闭、HEAD 无 body、头超 8KB→413、chunked→411、POST 无 CL→411、CL 超 64KB→413、CL 非数字→400、非 `/` 开头→400、64KB body 可收、40 并发超额→503、压测后仍存活）。
   **实测踩到的坑（已修）**：`conn.consumed` 原写成 `head_end + body_len`，但 body 只有一部分来自 inbox、其余是直接读进 arena 的，导致第二个请求到来时 `remove_range(&inbox, 0, 65636)` 越界 panic 并杀掉进程——被「POST 64KB body」这个用例抓到。正确值是 `head_end + from_inbox`（`from_inbox` 才是真正从 inbox 拿走的那部分）。
3. **静态文件** —— **已完成**。新增 `src/http/uri.odin`（`normalize_path`：剥查询串 → 百分号解码 → 逐段压掉 `.`/空段/`..`，整函数只分配一次且在同一个 buffer 里就地压缩）、`src/http/mime.odin`（`content_type_for`，不区分大小写、不跨 `/`）；新增 `src/handlers/static.odin`（`serve_static`：非 GET/HEAD → 405；`os.stat` 缺失 → 404；目录 → 就地追加 `/index.html` 再 stat，非普通文件 → 404；其余读文件送出，零拷贝转换）。`main.odin` 的 `handle` 换成「规范化 → 分派」，启动时去掉 docroot 尾部 `/`。新增 fixture：`tests/fixtures/www/{index.html, luci-static/test.css, luci-static/sub/note.txt}`。
   验收：`tests/http_smoke.sh` **35/35 通过**（原 18 项保持，另加 17 项：静态文件 10 项、路径逃逸 6 项、管道请求 1 项）；`./build.sh --target` 仍正常，210,304 字节。
   **对第 2 步既有用例的两处修改（不是回归）**：`/` 现在走静态文件，非 GET/HEAD 一律 405，所以「POST 64KB body」「POST 小 body」的期望从 200 改成 405——这两条要看的是 body 被完整收下（不报 400/411/413），已在注释里写明。`tests/fixtures/www/index.html` 的内容特意写成 `hello, molly\n`（13 字节），让「Content-Length 13 / body hello, molly」两条断言继续成立。
   **新增的管道用例**：一条连接上 `POST`(body=5) 紧跟 `GET /index.html`，数回包里有几个 `HTTP/1.1`（应为 2）。这条直接盯第 2 步的 `conn.consumed` 记账，是本步最有价值的回归测试。
   **实测踩到的坑（已修）**：见「已验证的事实」新增的三行（枚举 switch 的 `case:` 不算覆盖、proc 参数不可赋值、`transmute(string)` 惯用法）。
   **实现决策**：符号链接用 `os.stat`（跟随）而非 `lstat`——与原厂 uhttpd 一致，且 `/www/luci-static` 下本来可能有链接；未收录扩展名回 `application/octet-stream`（不猜 `text/plain`）；所有「存在但不可读 / 类型不对」都回 404 而不是 403，避免泄露文件是否存在。
4. **backend 分层** —— **已完成**。新增 `src/backend/backend.odin`（跨平台契约说明；Odin 不允许「只声明不实现」的 proc，所以这份文件只有注释 + package）、`src/backend/darwin.odin`（`#+build darwin`，罐头 JSON）、`src/backend/linux.odin`（`#+build linux`，暂回 `ok = false`，第 5 步接真库）；新增 `src/handlers/ubus_http.odin`；`main.odin` 的 `handle` 插入 `/ubus` 前缀路由（`matches_prefix` 带边界）。
   验收：`tests/http_smoke.sh` **52/52 通过**（原 35 项保持，新增 17 项 `/ubus` 用例）；`./build.sh --target` 仍正常，211,152 字节，NEEDED 仍只有 `libc.so`（符合预期，第 5 步首次引用 uci/ubus 符号后才会补齐四个 SONAME）。
   **实现决策**：
   - `list_objects(path, alloc) -> (json, ok)`：`path == ""` 走全量分支、否则走单对象分支，正好对应上游 `add_object = !path` 那个开关。darwin 的假数据用**常量字符串拼接**（`FAKE_LIST :: "{\"file\":" + FILE_SIG + …`）生成，所以「全量里的 session」与「/ubus/list/session」永远逐字一致——smoke 里有一条正是断言这个一致性。
   - 假数据的形状严格按上游 `uh_ubus_list_cb` 的映射表（类型只有 boolean/number/string/array/object/unknown），并有测试卡住这六个取值。**假数据不代表设备契约**，只是结构样本。
   - `500` 正文暂用 JSON-RPC 错误表的 `-32603 Internal error`（上游 `uh_ubus_ubus_error` 回的是真实 ubus errno，但第 4 步的 backend 还没有 errno，不编造）。**第 5a 步已换成真实 errno**，见下。
   - 上游 ubus 插件只认 GET/POST/OPTIONS，其余（含 HEAD）一律 400；OPTIONS 回 200 + `application/json` + `Content-Length: 0`；`GET /ubus` 与 `GET /ubus/<非 list\|subscribe>` 回 404 空 body——全部照抄 `ubus.c:977-996` 与 `:336-352`。
   - `POST /ubus` 与 `POST /ubus/call/*` 第 4 步回 501，smoke 里断言 501 的用意是钉住「它们归 ubus 路由、不掉进静态文件的 405」；**第 5b 步已改成断言 JSON-RPC 响应**，见下。
   - `/ubus.html` 这类文件名：`matches_prefix` 要求前缀后紧跟 `/` 或字符串结束。加了 fixture `tests/fixtures/www/ubus-probe.txt` 专门测这个边界（裸 `has_prefix` 会把它抢走）。
   **上游契约的新增实证**：见「已验证的事实」最后 11 行（全部来自 upstream `ubus.c`，已下载核对）。其中最重要的一条是**会话来源应为 `Authorization: Bearer <sid>` 而不是 `Ubus-Session`**——原计划写错了，已同步更正「被复刻的契约」、第 5 步描述与本地验证命令。这条如果留到第 5 步才发现，会做出一个连不上的认证路径。
5. **Linux 绑定与 `/ubus`**（拆成 5a / 5b 两段做，因为绑定层的编译错误只能在 `--target` 下暴露）。

   5a. **Linux 绑定 + linux 侧真实现** —— **已完成**。
   新增 `src/backend/bindings/` 四文件（全部 `#+build linux`，因此 `--host` 构建完全不编译它们）：
   - `libc.odin`：只绑一个 `free`，用 `@(link_name="free") c_free`（加前缀是为了调用点自解释）。
   - `blob.odin`：blob 常量 / `Blob_Attr`(4B) / `Blob_Buf`(32B，含 `grow` 函数指针) / 手工字节序 swap / **static inline 复刻**（`blob_data`/`blob_id`/`blob_is_extended`/`blob_len`/`blob_raw_len`/`blob_pad_len`/`blob_next`，`.so` 里没有这些符号，已用 `llvm-nm -D` 核过）/ 迭代器三件套（`blob_iter`/`blob_iter_ok`/`blob_iter_next` + `blob_iter_data`，对应上游三个 `for_each` 宏的「初值/条件/步进」）。
   - `blobmsg.odin`：类型码常量、`Blobmsg_Hdr`(2B)、`Blobmsg_Policy`(16B)、`blobmsg_hdrlen`/`blobmsg_name`/`blobmsg_data`/`blobmsg_data_len`/`blobmsg_get_u32`/`blobmsg_get_string` 复刻、`blobmsg_open_*`/`close_*`/`add_string`/`add_u32`/`add_blob`、`blobmsg_format_json`。`blobmsg_parse` 与 `blobmsg_add_json_from_string`/`blobmsg_format_json_with_cb` 走 foreign（分属 libubox 与 libblobmsg_json）。
   - `ubus.odin`：`Ubus_Context`(空结构，只当指针)、`Ubus_Object_Data`(24B，回调用得到 path/signature 所以布局必须对)、两个回调类型、`ubus_connect`/`ubus_free`/`ubus_lookup`/`ubus_lookup_id`/`ubus_invoke_fd` 五个 foreign 声明。**故意不绑 `ubus_strerror`**（理由见下）。
   重写 `src/backend/backend.odin`：新增 14 个 `UBUS_STATUS_*` 常量 + 逐字抄 `libubus.c:26-41` 的 `UBUS_STATUS_TEXT` 表 + `ubus_error_message(code, alloc)`，以及新契约 `Call_Outcome`(Ok/Object_Not_Found/Internal) / `Call_Result{outcome, ret, reply}`；`list_objects` 签名改为三返回值 `(json, err, ok)`。
   重写 `src/backend/linux.odin`：全局 `g_lock: sync.Mutex` + 惰性 `g_ctx` + 三个全局 `blob_buf`（`g_tmp`/`g_acc`/`g_out`）；`list_cb` 逐行复刻 `ubus.c:602-656`；`call_data_cb` 复刻 `ubus.c:450-459`；`list_objects` 与 `call_object` 的真实现。
   改 `src/handlers/ubus_http.odin`：`ubus_list` 适配三返回值，新增 `ubus_error_body`（`{"code":%d,"message":"%s"}`），删掉硬编码的 `UBUS_INTERNAL_ERROR` 常量。
   改写 `src/backend/darwin.odin`：`list_objects` 三返回值（未知路径回 `UBUS_STATUS_NOT_FOUND`），新增假 `call_object`。
   验收：`./build.sh --host` 通过（627,208 字节）且 `./tests/http_smoke.sh` **52/52 通过**（无回归；`/ubus` 相关断言只查状态码与 Content-Type，不查 500 正文，所以「-32603 → code 4 "Not found"」的改动不影响它们）。`./build.sh --target` 编过并链接成功，产物 `build/molly` 215,136 字节，`llvm-readelf -d` 的 NEEDED 为 `libubus.so.20251202` / `libblobmsg_json.so.20260213` / `libubox.so.20260213` / `libc.so`。

   **已知偏差（第 1 步那条验收项在此处的结果）**：NEEDED 里**没有 `libuci.so`**——lld 默认 `--as-needed`，而 P2 至今没有任何代码引用 uci 符号，所以被丢掉。这是预期行为，不是链接缺陷：第 6 步 dispatcher 读到 `/etc/config` 时会自动出现。第 1 步用 `-Wl,--no-as-needed` 做的一次性诊断已证明四个库都能按正确 SONAME 进入，故该验收项不必再改动。

   **实测踩到的坑（5a，全部已修）**：
   - `proc "c"` 回调体内**没有隐式 context**，所以在 `list_cb`/`call_data_cb` 里调用普通 Odin proc 会报 `'context' has not been defined within this scope`。修法：bindings 里所有非 foreign 的 proc 全部标成 `proc "contextless"`（它们本来也不碰分配）。这是 5a 最大的一类错误（占了报错的一半以上），且只在 `--target` 下暴露。
   - `^T(x)` 在 Odin 里被解析成「类型 + 调用」而不是 cast，指针 cast 必须写成 `(^T)(x)`（`blob_next`/`blob_iter`/`blob_iter_data` 三处）。
   - 整型混合运算不做隐式转换：`uintptr + uint`（`blob_next`）、`uint - uintptr`（`blobmsg_data_len`，需 `uint(end - start)`）都要显式转。
   - `linux.odin` 用了 `c.int` 但没 `import "core:c"`（绑定文件里有、这个文件里没有）。
   - 字符串拼接 `"` + method + `":` 非法（Odin 只允许**常量**字符串用 `+`），改 `fmt.aprintf`。
   - `type` 是 Odin 关键字：`blobmsg_add_field` 的形参改 `attr_type`、回调形参改 `msg_type`、`Blobmsg_Policy` 字段改 `type_code`。

   **实现决策（5a）**：
   - **不绑 `ubus_strerror`，改在共享层提供文案表**：libubus 的实现用的是 `static char err[32]`，在「一连接一线程」下多线程不安全；抄成常量表后两个平台给出逐字一致的文案，darwin 的假实现也不需要链 libubus。
   - **`call_object` 的契约不含 JSON-RPC 信封**：信封（jsonrpc/id/result/error、以及 -32700/-32600/-32601/-32602 这些纯协议错误）全归 handler，5b 做。
   - **params 走 `blobmsg_add_json_from_string` 而非逐项 `blobmsg_add_blob`**：`blobmsg_add_object`（`blobmsg_json.c:22-29`）是平铺键值、不套外层 table，与上游 `uh_ubus_send_request` 逐项拷贝的结果等价。至于 `ubus_rpc_session`：**上游不是「剔除」而是「拒绝」**——`ubus.c:578-582` 一旦发现客户端自带该键就回 -32602（对照源码更正了 5a 期间写在 `linux.odin` 注释里的错误表述）。因此由 handler 在 JSON 层提前回 -32602，见 5b。
   - **`ubus_invoke_fd` 的已知偏差**：它把「请求根本没发出去」和「远端返回 `UBUS_STATUS_INVALID_ARGUMENT`」合并成同一个返回值（上游走异步 API 能分开）。取舍：把 INVALID_ARGUMENT 判为本机故障（`.Internal`），其余错误码（NOT_FOUND/TIMEOUT/METHOD_NOT_FOUND…）作为远端返回码交给 handler。改用异步 API 需精确复刻 104 字节的 `struct ubus_request`（含 `list_head`），风险高收益小，故不采用。
   - **三个全局 buf 反复 `blob_buf_init` 不漏内存**：`blob_buf_init` 不 memset 也不 free 旧内存，而是复用 `buf->buf`（`blob.c:102-113`），只把 `head` 指回起点。上游 uhttpd 用的也是 static 全局 buf（`ubus.c:470/573/690`）。
   - **持锁范围**：`构造请求 → invoke → 格式化 JSON` 整段（上限 = `UBUS_TIMEOUT_MS` 30s）。持锁期间不写 socket，JSON 成型后才交给 HTTP 层，所以慢客户端不会占着总线。

   5b. **JSON-RPC 协议层** —— **已完成**。
   全量重写 `src/handlers/ubus_http.odin`（唯一改动的业务文件），逐条对齐 `/tmp/uhttpd-ubus.c`：
   - 路由：`GET` → `ubus_get`（`/ubus/list` 与 `/ubus/list/<path>` 走 list，`/ubus/subscribe/*` 仍 501）；`POST` → `ubus_post`（`path == "/ubus"` 走 `rpc_legacy`，`has_prefix("/ubus/call/")` 走 `rpc_rest`，其余 404 空 body）；`OPTIONS` → 200 + `application/json` + `Content-Length: 0`；其余方法 400。常量 `UBUS_PATH`/`UBUS_LIST_PATH`/`UBUS_LIST_PREFIX`/`UBUS_CALL_PREFIX`/`UBUS_SUBSCRIBE_PREFIX`/`UBUS_DEFAULT_SID`。
   - 会话：`auth_sid` 只认 `authorization` 头且值须以 `Bearer `（大小写不敏感）开头，否则回退哨兵 32 个 0；不做 trim（上游也不做）。
   - 旧式 `rpc_legacy`：`json.unmarshal` → 对象走 `legacy_one`；数组走批响应（`strings.builder` 拼 `[` + `,` 分隔 + `]`）；标量/null → -32700。`legacy_one` 取 `id`/`method`/`jsonrpc`，`jsonrpc != "2.0"` 或 `method` 缺失 → -32700（对齐 `parse_json_rpc` 的初值 err）；`method=="call"` 要求 `params` 是 ≥4 元数组且 `[sid,对象,方法,表]` 四项类型全对，否则 -32700；`method=="list"` 走 `legacy_list`（无 params → 路径数组；有 params → 逐路径查签名合并，查不到的忽略）；其余 method → -32601。
   - 新式 `rpc_rest`：正文必须是对象（否则 -32700），取 `id`/`jsonrpc`/`method`/`params`，`params` 走 `invoke`，路径来自 URL。
   - `invoke`（两形态共用）：有 `params` 时必须能 cast 成 `json.Object`（`null` 也算失败）且不含 `ubus_rpc_session`，否则 -32602；`json.unparse(..., {spec=.JSON, sort_maps_by_key=true})` 出参数字符串；调 `backend.call_object`；`.Object_Not_Found` → -32000、`.Internal` → -32603、`ret != 0` → `{"code":ret,"message":ubus_error_message(ret)}`；收尾按 `Rpc_Shape` 分叉——旧式回 `[0,reply]` / `[0]`，新式回 `result` 对象 / `null`。
   - `invalid_params_json` 先 `backend.list_objects(path)` 探存，保证 -32000 优先于 -32602（对齐上游「先 `ubus_lookup_id` 再校验 params」）。
   同时修 `src/backend/darwin.odin` 假回显串的花括号、改 `src/backend/linux.odin` 关于 `ubus_rpc_session` 的注释。

   **实测踩到的坑（5b，全部已修）**：
   - **致命运行时 bug（自第 4 步潜伏）**：所有 `fmt.aprintf` 的 JSON 格式串里单写 `{` 会输出 `%!(MISSING CLOSE BRACE)`，正文完全损坏。Odin 的 fmt 把 `{` 当 Python 风格动词起始符（`core/fmt/fmt.odin:702-734`），JSON 字面花括号必须双写 `{{` / `}}`。受影响的是 `ubus_error_body`（第 4 步就存在）与 darwin 假回显；现已全部双写并在 `ubus_error_body` 上方加注释说明原因。
   - `Enumerated array literals must only have 'field = value' elements`：`RPC_ERRORS` 枚举下标数组不能位置初始化，改 `.Parse = {...}` 指定式。
   - `Unhandled switch cases: Null i64 f64 bool string`：`switch v in root` 是联合 type switch，`case:` 默认分支不算覆盖，改 `#partial switch`。
   - `Missing return statement at the end of the procedure 'invoke'`：枚举 `switch shape` 不被视为「所有路径都返回」，改 `if shape == .Legacy {…}` + 无条件收尾 return。
   - `json.unmarshal` 把 JSON `null` 解析成 **nil union**（`unmarshal.odin:411-413`），无法与「没有 params 字段」区分，故 `invoke` 额外传 `has_params`。

   **实现决策（5b）**：
   - **envelope 用 `json.Value` + `json.unparse`，不用 `json.marshal`**：`unparse` 原生支持 `json.Value`，且 `sort_maps_by_key = true` 保证输出确定性（smoke 的批响应/数组断言依赖这一点）。
   - **错误一律 HTTP 200**：上游在 invoke 前就把 200 头与 Content-Type 发出去了（`ubus.c:851`、`:874`），唯一的例外是 GET list 的 500（那条回 ubus 自己的 errno，`ubus.c:315-317`）。
   - **请求体超 64KB 回 HTTP 413**：molly 的 HTTP 层在第 2 步就定了 413（对齐 `MAX_BODY_BYTES :: 65536` = 上游 `UH_UBUS_MAX_POST_SIZE`），而上游 ubus 插件回 200 + -32700 并关连接。这是第 2 步的既有决策，不在 5b 范围，保持现状。

   验收：
   - `./build.sh --host` 通过（824,360 字节，Mach-O arm64）；`./build.sh --target` 通过，`build/molly` 288,672 字节，`llvm-readelf -d` 的 NEEDED 仍为 `libubus.so.20251202` / `libblobmsg_json.so.20260213` / `libubox.so.20260213` / `libc.so`。
   - `./tests/http_smoke.sh` **85/85 通过**（第 4 步基线 52 项无回归，新增 33 项）。新断言按三段覆盖：旧式 POST（成功回显 object/method/sid、id 原样回、缺 id 回 null、-32000/-32601/-32700/-32602、非法正文、标量正文、`list` 两形态、批请求、空数组正文）、新式 POST /ubus/call（result 是对象、method 即 ubus 方法名、Bearer 进 sid、无 Authorization 用哨兵、无 params → 空表、-32000、未知方法 → ubus 码 3、params 非表/null → -32602、-32000 优先、非法正文）、POST 路由边界（`/ubus/nope` 404、`/ubus/call` 404、`PUT` 400、GET list 500 正文 `code=4`）。
   - 手工 curl 另验证了 20+ 种情形（含以上全部），输出与上游契约逐字一致，例如 `{"jsonrpc":"2.0","id":1,"result":[0,{"echo":{…}}]}`、`{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Object not found"}}`、`{"jsonrpc":"2.0","id":15,"error":{"code":3,"message":"Method not found"}}`、`{"code":4,"message":"Not found"}`。
   - 真机 `ubus list -v` 与 `/ubus/list` 一致 —— 待第 7 步。
6. **dispatcher 骨架**：menu.d 解析、建树、路径解析、占位页/404。 —— **已完成**
   验收：`/cgi-bin/luci/admin/status/overview` 出占位页；未知路径 404；`depends.acl` 只展示不执行。

   **上游语义（`modules/luci-base/ucode/dispatcher.uc` master，已抓源码逐条确认，实施时不必重新抓）**：
   - `build_pagetree()`（:276-347）：根节点 `{ action: { type: 'firstchild' } }`；读 `/usr/share/luci/menu.d/*.json`（P2 只需要这一个 glob）；每个文件是 `{ "<路径>": <spec>, … }`；路径按 `/[^\/]+/` 切段建 `children`；**段首字符为 `*` 时** `node.wildcard = true` 并 break；schema 只接受这些键且**类型须匹配**：`action`(object) / `auth`(object) / `cors`(bool) / `css`(string) / `depends`(object) / `order`(int) / `setgroup`(string) / `setuser`(string) / `title`(string) / `wildcard`(bool) / `firstchild_ineligible`(bool)；wildcard 时 action 存进 `wildcardaction`，否则存 `action`；`node.satisfied = check_depends(spec)`。上游还写 `/tmp/luci-indexcache`，**P2 不写**（决策 6），只做进程内 mtime 失效缓存。
   - `check_depends`（:225-250）：只处理 `depends.fs`（array/object，任一命中即可）与 `depends.uci`；`depends.acl` **不参与 satisfied**，只在 `apply_tree_acls` 里用（P2 不执行 ACL，只展示）。
   - `resolve_page(tree, request_path)`（:503-553）：逐段 `node = node.children?.[s]`，`!node?.satisfied` 就 break；遇 `node.wildcard` 且**下一段不匹配已存在且 satisfied 的子节点**时，把剩余段收进 `ctx.request_args` / `ctx.request_path` 并 break；循环后若 `node.action.type == 'firstchild'` 则调 `resolve_firstchild`。
   - `resolve_firstchild`（:467-502）：在所有 satisfied、有 `title`、且 `action` 是 object 的子节点里选权重最小者（`node_weight` = min(order ?? 9999, 9999)，`auth.login` 再 +10000），跳过 `firstchild_ineligible`；子节点 action 为 firstchild 时递归下降（须有孙节点才可当选）。
   - 命中但 `action.type != "view"` → P2 回 501；完全未命中 → 404；`alias` 需解析目标节点后回落。
   - AST 之外：LuCI 的 PATH_INFO 是 `/cgi-bin/luci` **之后**的路径；cookie 名 `sysauth_http`(http) / `sysauth`(https)；menu.d 的 title 多为未翻译英文原文。

   **实现清单（本步要落的文件）**：
   - 新增 `src/luci/menu.odin`：读 `menu.d/*.json` → 建树；node 含 `title`/`order`/`action{type,path}`/`depends`（原样保留供展示）/`wildcard`/`satisfied`/`firstchild_ineligible`；`children` 用 string-map；遍历输出需确定性。JSON 用 `core:encoding/json` 解析成 `json.Value` 后手工下降（照 `ubus_http.odin` 的 `#partial switch v in root` 写法）。
   - 新增 `src/luci/render.odin`：占位页 = 标题 + view 路径 + 显式「ACL 未实现」横幅。
   - 新增 `src/handlers/cgi_luci.odin`：`/cgi-bin/luci` dispatcher（PATH_INFO = 前缀之后的路径）。
   - `src/main.odin` 的 `handle`：把 `/cgi-bin/luci` 前缀插到 `/ubus` **之后**，复用现成的 `matches_prefix`（裸 `has_prefix` 会把 `/cgi-bin/luci.html` 抢走）；新增启动参数 `--menu-dir`（默认 `/usr/share/luci/menu.d`，host 测试传 `tests/fixtures/menu.d`），解析风格照现有的 `--listen`/`--docroot`。
   - 新增 `tests/fixtures/menu.d/*.json` 与 `tests/http_smoke.sh` 断言（沿用其 `check`/`status_of`/`header_of` helper）。
   - **`depends.uci` 是本步首次引用 uci 符号的地方**（第 1 步遗留验收项：`--target` 的 NEEDED 应出现 `libuci.so`）。做法：把 `spike/01-toolchain` 已验证的 `uci_ptr` 布局搬进 `src/backend/bindings/uci.odin`（`#+build linux`），darwin 侧用假配置，契约仍走 `src/backend/`。

   **验收（实测）**：
   - `./build.sh --host` 通过（868,248 字节）；`./tests/http_smoke.sh` **108/108 通过**（第 5b 基线 85 项无回归，新增 23 项 `/cgi-bin/luci` 断言）；`./build.sh --target` 通过，`build/molly` 307,920 字节。
   - `--target` 的 NEEDED 变为 `libuci.so.20250120` / `libubus.so.20251202` / `libblobmsg_json.so.20260213` / `libubox.so.20260213` / `libc.so` —— **第 1 步遗留验收项（NEEDED 应出现 uci）就此闭合**，且 `libuci.so.20250120` 与 `docs/development-environment.md` 记录的 `PKG_ABI_VERSION` 一致，不是新风险。
   - 三条验收原文逐条对照：`/cgi-bin/luci`、`/cgi-bin/luci/`、`/admin/status/overview`（含带查询串）出占位页（200 + `text/html; charset=utf-8`）；未知路径 404；占位页上 `depends (shown, not enforced)` 与「ACL 未实施」横幅同时出现，`depends.acl` 不参与 resolve。
   - 手工 curl 另核了非 view（`/admin/status/routes` → 501）、通配段（`/admin/status/logs/syslog` 200，剩余段进 `request_args`）、depends 两侧（`/hidden` 404 与 `/present` 200、`/ucimissing` 404 与 `/ucipage` 200）、白名单外键整条丢弃（`/badfield` 404）、POST → 405、HEAD 有完整头无 body、`/cgi-bin/luci-admin` 不被前缀抢走。
   - **缓存失效实测**：服务运行期间新建 `tests/fixtures/menu.d/zzz-live.json`（order 5）→ 首页立刻变为该新节点、`/cgi-bin/luci/live` → 200；删除后回到原首页、`/live` → 404。临时文件验证后已 `rm`。

   **实现决策（6）**：
   - **隐式中间层默认 `satisfied = true`**：`menu.d` 通常只写叶子路径（如 `admin/status/overview`），中间层 `admin`/`admin/status` 由 `descend` 隐式创建。上游 `luci-base.json` 里中间层确实各有一条 `firstchild` 声明，但不能假设所有包都这样；隐式层给 `true` 才不会把整条枝剪掉。代价：上游若靠「中间层 depends 不满足」来隐藏枝叶，P2 会多显示——已记在本步风险里，留给第 7 步用真实 `menu.d` 对比。
   - **`firstchild` 同权重按段名字典序**：上游 `ucode` 的排序依赖 JS 对象键序，P2 用 `slice.sort(names[:])` 把文件处理顺序与 `children` 遍历顺序都钉死，保证占位页与 smoke 断言确定性。
   - **缓存用一个 `mem.Dynamic_Arena` 整体销毁**：树里所有字符串/map/切片都分配在这个 arena 上，失效时 `dynamic_arena_destroy` + 重新 init 即可，不需要逐字段回收——代价是有效期内旧树的内存会一直占着（一棵真实 menu.d 的树只有几十 KB，与 <2MB 目标不冲突）。
   - **`depends` 原样保留 JSON 文本**：`json.unparse(..., {spec=.JSON, sort_maps_by_key=true})` 存成字符串，只用于占位页展示，不参与判定；判定走 `check_depends` 的 `fs`/`uci` 两条实际通道。
   - **`uci_has` 只在 `UCI_LOOKUP_COMPLETE` 时算命中**：`uci_lookup_ptr(..., extended=true)` 的 `flags` 里 `DONE` 只表示「查完了」，只有 `COMPLETE` 才表示「对象存在」——与上游 ucode 的 `uci.get` 语义一致。
   - **不写 `/tmp/luci-indexcache`**（决策 6）：保持与真 LuCI 的缓存文件互不干扰，代价是每次 molly 进程启动都要重读一遍 `menu.d`（本地 fixture 量级可忽略）。
   - **map 键必须手动 clone 到树 arena**：`node.children[seg]` 里的 `seg` 来自请求或临时分配，不 clone 会在 arena 销毁后悬垂——`descend` 里显式 `strings.clone(seg, alloc)`。

   **实测踩到的坑（6）**：本步**没有编译或运行时错误**，`--host` / smoke / `--target` 均一次通过。唯一需要补的是用例覆盖：手工 curl 时发现 `luci-base.json` 里唯一非 view 分支 `admin/system/reboot` 被 probe 文件覆盖成了 view（覆盖机制本身是被验证的特性），导致 501 分支没有实测覆盖——于是在 base 里新增 `admin/status/routes`（`type = cbi`，order 60）专门把 501 钉住。若将来再加「后处理文件覆盖」类用例，注意别把某个分支的唯一覆盖点吃掉。
6b. **dispatcher 语义对齐（离线抽样发现，待做）** —— 依据 `.ai-memory/r8-menu-sample.md`（方法、行号、实测输出都在那里）。

   抽样口径：25.12.2 `feeds.conf.default` 钉住的 luci 提交 `d6167ea` 的全部 `menu.d/*.json`（138 文件 / 413 路径）+ 同一提交的 `dispatcher.uc`。**R8 本身不成立**（隐式中间层上游就是 `satisfied: true`，`:400-402`），但同段代码查出 5 类偏差，合成探针实测 8/11 不一致，真实样本受影响 117/413：

   | 编号 | 上游语义（`dispatcher.uc`，同一提交） | molly 现状 | 真实样本影响 |
   |---|---|---|---|
   | D1 | `:406-408` `for k,t in schema if type(spec[k])==t → node[k]=spec[k]`：schema 外的键、类型不符的键**只忽略该键** | `apply_spec` 遇任一不合法键 **`return` 丢整条** | 13 条（`order` 写成 string 7 例、`title_hide` 4、`depends_comment` 1） |
   | D1b | 同上：**只覆盖 spec 里出现的键**，未出现的键保留前一份定义的值 | molly 用局部默认值把未出现的键清空（title=""、order=9999、has_depends=false…） | 1 条（`admin/modem` 被 `luci-app-3ginfo-lite` 与 `luci-app-modemband` 同时定义） |
   | D2 | `:171-196` `check_fs_depends`：条目 = `路径 → file/executable/directory/absent`（`directory` 要 `lsdir` 非空、`executable` 要 file + owner exec、`absent` 要 `stat == null`）；`:279-292` object=**全部**条目成立、array=**任一**备选成立 | 取键当路径、**任一存在**即满足、不看类型（`absent` 方向完全相反） | 58 条目（file 19 / executable 33 / directory 2 / absent 4） |
   | D3 | `:198-276`：`true` = config 有 ≥1 section；object = 全部 section 条目成立；section 键 `@<type>`（`:231`） = 任一该类型 section 满足；option 取值 `true` = 存在（`:202-206`）、string = 比对 section `.type`（`:199-201`）、object = 逐值精确匹配（值为数组时按成员判定，`:207-223`） | 取键任一 `uci_has` 命中即满足 | 74 条（68 条 `true`、5 条 object，5 条**全部**是 `@wifi-iface`/`@switch` + bool option；option 取值为 string/array 的真实用例 0） |
   | D4 | `:410-414` 存 `wildcardaction`；`:1010-1011` **有剩余段**时用它，否则用 `node.action` | 单字段，后处理的文件覆盖前者 | 19 条通配路径（探针 `/wv` 实际渲染 wild-card，上游应为 wild-base） |

   修法（一处一改）：
   1. `apply_spec`：白名单键逐键处理，未知键/类型不符**只跳该键**；未出现的键不写默认值（D1/D1b）；命中通配时 action 存进独立的 `wildcard_action_type/path`（D4）；`spec.wildcard` 按上游覆盖 `node.wildcard`（真实样本 0 例，一并实现，免留隐性偏差）。
   2. `check_depends` 重写：fs 按「object 全部 / array 任一」+ 四类型判定；uci 按「object 全部 / array 任一」+ `true` / `@type` / option 三形态，**非 object 取值一律忽略 ⇒ 满足**（上游 `:259-273`、`:283-288` 都没有 else 分支）。
   3. backend 契约**只加一个 proc**：`uci_config_sections(config, alloc) -> (sections: []Uci_Section, ok)`，其中 `Uci_Section{name, type_name, anonymous, options: []Uci_Option{name, values}}`；判定逻辑全部留在 `src/luci`（与 ucode 同层）。原 `uci_has` 删除（无兼容包袱，AGENTS §6.4）。
      - linux：`uci_load` + `uci.h:436-470` 的结构体（`uci_package.sections` / `uci_section.options` / `uci_option.v`）与 `uci.h:552` 的 `uci_foreach_element` 语义遍历，配 `#assert(size_of(…))` 尺寸断言；header 权威来源 `sysroot/usr/include/uci.h`（不是 `uci_internal.h`，公开 API 足够）。
      - darwin：`FAKE_UCI_HAVE` 换成同类型的假 section 表（含 `@interface` 类型、具名 section、option 值与不存在项），让 D3 的三形态都能在 macOS 上被断言。
      - **fs 侧不需要新 proc**：`core:os` 的 `File_Info.type`、`Permission_Flag.Execute_User`、`read_directory_by_path` 足够（AGENTS §2.1 rung 3）。
   4. smoke 同步：`白名单外的键整条丢弃 → 404` 改成上游期望 200；`depends.fs/uci` 的**字符串形式**用例改成 object 形式（上游对非 object 取值一律「忽略 ⇒ 满足」，字符串形式再也钉不住 404），另加一条「未知形状 ⇒ 满足」用例（真实样本 `admin/services/olsr` 的 `"uci": ["olsrd"]` 正属此类）；通配节点补「无剩余段用 base action」断言。
   5. `.ai-memory/r8_probe.py` 的 part A 是**静态复刻旧 `apply_spec`** 的统计脚本，改完代码会继续打印过期数字 → 按新语义重写（逐键 + 忽略非 object 取值）。
   6. 非严格 JSON（`luci-app-sms-tool-js` 对象尾逗号，7 条路径）：本机无 `ucode`（`which ucode` 为空），**维持原判**留到第 7 步，本步不动解析器。

   验收：`python3 .ai-memory/r8_probe.py` → `不一致条目: 0 / 11`；`./build.sh --host` → `./tests/http_smoke.sh`（失败 0）→ `./build.sh --target`（改了 linux-only 绑定，必须跑）；回写本文件进度表 + `README.md` / `docs/build-and-run.md` 的项数。
   **验证边界**：probe 与 smoke 只覆盖 darwin 侧；linux 侧 `uci_config_sections` 本步只做到编译校验（`--target`），运行时正确性属第 7 步。

6c. **三层架构文档 + 测试体系（用户要求：实现、测试、文档同步交付）—— 进行中**
   现状：测试只有 `tests/http_smoke.sh` 一套 shell 验收（同时充当集成与接口测试），没有单元测试；文档只有 `README.md` + `docs/{development-environment,build-and-run}.md`。
   **已完成（2026-09-26）**：单元测试层 19 个用例（`src/http` 4 / `src/luci` 13 / `src/backend` 2，全绿无泄漏）+ 单命令入口 `tests/unit.sh` + `docs/testing.md`（三层覆盖范围/判据/执行流程/覆盖边界）；`AGENTS.md` §4.1 门禁加 `./tests/unit.sh`，§10 与 Do/Don't 同步；`README.md` 加测试命令与文档索引。
   **剩余**：`docs/architecture.md`（三层职责、模块划分、调用关系、依赖规则）与 `docs/interfaces.md`（HTTP 路由 / `/ubus` 契约 / dispatcher PATH_INFO 与 action 语义 / backend 契约）。
   范围：
   - **分层定稿并写进文档**：数据层 = `src/backend/`（ubus/uci 访问 + `linux`/`darwin` 两个 provider）、业务层 = `src/luci/` + `src/http/`（菜单树、depends 判定、URI 规范化、HTTP 解析）、接口层 = `src/handlers/` + `src/main.odin`（HTTP 路由、`/ubus` JSON-RPC、`/cgi-bin/luci` dispatcher）。依赖规则单向：handlers → luci/http → backend；`src/luci` 与 `src/http` 互不依赖，`src/backend` 不依赖任何上层。
   - **单元测试**：`odin test -collection:molly=src <pkg>`（已实测可用），覆盖纯函数——`http/uri.normalize_path`、`http/mime.content_type_for`、`luci` 的 `apply_spec`/`check_depends`/`resolve`/`first_child`/`effective_action`、`backend.ubus_error_message`。
   - **集成测试**：`tests/http_smoke.sh`（真起 server、真 curl）。
   - **接口测试**：`/ubus` 两种 JSON-RPC 形态与 `/cgi-bin/luci` 的 PATH_INFO / action 分派（在 smoke 里按接口分节标注）。
   - **文档**：`docs/architecture.md`（三层职责、模块划分、调用关系、依赖规则）、`docs/interfaces.md`（HTTP 路由、`/ubus` 契约、dispatcher PATH_INFO 与 action 语义、backend 契约）、`docs/testing.md`（单元/集成/接口三类测试的覆盖范围、验证标准、执行流程）、配置方式与部署运行并入 `docs/build-and-run.md`。
   验收：`docs/` 上述文件齐备且与代码一致；`odin test` 全绿；`tests/http_smoke.sh` 失败 0；`README.md` 链接到新文档。

7. **真机联调（待设备）**：RSS 压测（连续请求后 `ps -o rss` 应收敛，目标 <2MB）、golden 对比、输出 P3 清单。

## 验证方式

本地（macOS，`./build.sh --host && ./build/molly-host --listen 127.0.0.1:8080 --docroot tests/fixtures/www --menu-dir tests/fixtures/menu.d`）：
```bash
curl -sD- -o/dev/null http://127.0.0.1:8080/index.html     # 200 + Content-Length
curl -sv http://127.0.0.1:8080/ http://127.0.0.1:8080/index.html 2>&1 | grep -i re-using  # keep-alive
curl -s http://127.0.0.1:8080/ubus/list                     # 对象/方法结构
curl -s -X POST -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","list",{}]}' http://127.0.0.1:8080/ubus   # result:[ret,{...}]
curl -s -H 'Authorization: Bearer 00000000000000000000000000000000' -X POST -d '{"jsonrpc":"2.0","id":1,"method":"list","params":{}}' http://127.0.0.1:8080/ubus/call/session
curl -sD- -o/dev/null http://127.0.0.1:8080/nope            # 404
curl -sD- -o/dev/null -H "X-Big: $(python3 -c 'print("a"*9000)')" http://127.0.0.1:8080/   # 413
curl -sD- -o/dev/null -X POST -H 'Transfer-Encoding: chunked' http://127.0.0.1:8080/       # 411
curl -s http://127.0.0.1:8080/cgi-bin/luci/admin/status/overview                           # 占位页
```

目标平台（有设备后）：`scp` 二进制 → 直接跑（不动原厂 uhttpd，换端口 8081 并行观察）→ 与 `curl -si` 抓的原厂响应做 golden 对比。**替换前先在原厂固件上抓全量样本存档**。

## 风险与不确定性

- **R1 设备是否提供 `libblobmsg_json.so.20260213`**：本地 sysroot 里有，但设备侧无法离线确认（OpenWrt 的 libubox 包历来把 `libubox.so`/`libblobmsg_json.so`/`libjson_script.so` 打在一个包里，故大概率有）。**兜底**：改用静态链接 `libblobmsg_json.a`（sysroot 里有），代价几 KB。
- **R2 `core:net` 在 linux_arm64 上的实际行为**未实测：`accept` 的错误映射、`listen_tcp` 绑 `::` 是否双栈（uhttpd 是 `0.0.0.0` + `::` 双 listener，molly 应支持多个 `--listen`）。第 1、2 步会在真机暴露。
- **R3 SIGPIPE 必须自己忽略**：Odin 默认不忽略，`core:net` 的 `send` 在 Linux 上无法传 `MSG_NOSIGNAL`，不漏掉的话客户端一断连就杀进程。
- **R4 一连接一线程与 uloop 的冲突（最大架构风险）**：`/ubus/subscribe`（SSE）与 P3 的 ubus 对象注册都需要一个 uloop 事件线程，与当前模型不兼容。P2 明确 501；P3 需引入专用 ubus uloop 线程 + 每连接 pipe，或回归单线程 epoll 重写 HTTP 层。**这是需要在 P3 前重新评估的架构分叉点。**
- **R5 Odin 无 stack_size 接口**：JSON 递归解析在 128KB 线程栈下有爆栈风险，需限制嵌套深度并实测。
- **R6 长连接下的内存增长**：每请求用 `context.temp_allocator` 并 reset、复用输出缓冲、线程退出时清理临时分配器；必须用 RSS 曲线验证，不能只看代码。
- **R7 边界状态码需 golden 校准**：413/411/403（目录无 index）/405 等具体取值，以及 25.12 版 `/ubus/list` 的请求头细节，需真机抓样本比对，不能凭推断定死。
- **R8 隐式中间层与真实 `menu.d` 的差异（第 6 步新增，已离线闭合：不成立）**：原假设是「molly 的隐式中间层一律 `satisfied = true`，而上游可能靠中间层 depends 不满足隐藏整枝」。**离线抽样已推翻**：25.12.2 钉住的 luci 提交 `d6167ea` 里 `dispatcher.uc:400-402` 就是 `node.children[s[0]] ??= { satisfied: true }`，与 molly 的 `descend` 逐字一致。真实样本（138 文件 / 413 路径）8 例中间层缺显式 spec 全部落在通配端点下，合成探针 `imp/a/b` 实测与上游一致。原始的两条兜底修法都**不需要**。**同段代码另查出 4 类真实偏差（D1–D4，117/413 受影响）**，已单列为第 6b 步，证据与修法见 `.ai-memory/r8-menu-sample.md`。仍然待真机的只剩两点：`luci-app-sms-tool-js.json` 的对象尾逗号 ucode 是否容忍；`depends.fs` 的 `lsdir`/`stat` 在设备上对真实路径的判定（第 7 步随 golden 对比一起做）。