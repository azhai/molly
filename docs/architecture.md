# 架构：三层职责、模块划分、调用关系与依赖规则

molly 用 Odin 复刻 ImmortalWrt LuCI 的**服务端三层**。本文是架构的权威描述：
每层的职责边界、目录与模块、一次请求的调用链、以及**必须遵守的依赖规则**。
接口与协议细节见 [`interfaces.md`](interfaces.md)，测试分层见 [`testing.md`](testing.md)。

## 1. 范围：替换什么、不动什么

| 上游组件 | 职责 | molly 的对应物 | P2 状态 |
|---|---|---|---|
| `uhttpd` | HTTP/1.1 服务 + `/ubus` 插件 + CGI 转发 | `src/http/`（传输）+ `src/handlers/`（`static` / `ubus_http` / `router` / `luci` / `cgi` / `cgi_io`） | 已实现 |
| `rpcd` | ubus 上的 `session` / `uci` / `file` / `luci` 对象（认证、会话、配置、ACL） | `src/backend/` —— 对象实现（`session`/`uci`/`file`/`luci-rpc`）+ 入站 ACL | P3：molly 已自持四个对象（P3-2…P3-5）与入站 ACL（P3-6，`/usr/share/rpcd/acl.d/*.json`）；设备 rpcd 仅作参照（决策 7） |
| `ucode` dispatcher | `menu.d` → 菜单树 → 路径解析 → 渲染 | `src/luci/`（`menu.odin` 语义 + `render.odin` 占位页） | 已实现（模板渲染属 P3） |

**不动**：`/etc/config`（uci 数据）、`ubusd`（消息总线）、`/www`（静态文件）。

## 2. 分层总览

| 层 | 目录 | 职责（一句话） | 允许依赖 |
|---|---|---|---|
| **接口层** | `src/main.odin`、`src/handlers/` | 把 HTTP 请求映射成业务调用：进程装配、CLI、路由分派、handler | `http`、`luci`、`backend` |
| **业务层** | `src/http/`、`src/luci/`、`src/assets/` | `http`：HTTP/1.1 传输与安全边界；`luci`：菜单树与 depends 语义；`assets`：编译进二进制的静态资源与简洁版菜单 | `http` 谁都不依赖；`luci` → `backend` |
| **数据层** | `src/backend/` | 平台相关的 uci / ubus 访问，各 provider 同名同签名 | 不依赖任何上层 |

```
                 main.odin
                    │  handle(): 规范化 → /ubus → 专家版前缀 → 简洁版 / → 静态
        ┌───────────┴────────────┐
        ▼                        ▼
   handlers/                 http/            ← 传输层：谁都不依赖（叶子）
   ├─ static.odin ──────────► http            （uri / request / response / limits / mime / server）
   ├─ ubus_http.odin ───────► http, backend
   └─ luci.odin / router.odin ─► http, luci, handlers/cgi
                                 │
                                 ▼
                              luci/            ← 菜单语义：只依赖 backend
                              ├─ menu.odin ──► backend
                              └─ render.odin   （只依赖 core）
                                 │
                                 ▼
                              backend/         ← 平台层：只依赖 bindings
                              ├─ backend.odin            契约 + 共享类型/常量
                              ├─ object_provider_* + uci_provider_* / process_spawn_* / platform_hooks_*
                              │                          #+build darwin：假数据 / #+build linux：真 libuci/libubus
                              └─ bindings/ + src/native   #+build linux：C 绑定 shim.odin + zig 编的 shim.c
```

## 3. 各层的模块清单

### 3.1 数据层 `src/backend/`

| 文件 | 内容 |
|---|---|
| `backend.odin` | **契约**（写在文件头的注释里）+ 共享类型与常量：`Call_Result` / `Call_Outcome`、`Uci_Section` / `Uci_Option`、`UBUS_STATUS_*` 与 `ubus_error_message`。Odin 不允许「只声明不实现」的 proc，所以这层是「注释即接口 + 两个 provider 提供同名实现」。 |
| `object_provider_{darwin,linux}.odin`、`uci_provider_*`、`process_spawn_*`、`platform_hooks_*`、`luci_provider_linux`、`iwinfo_provider_linux` | 按 `#+build darwin` / `#+build linux` 切分的同名 provider：darwin 给罐头 JSON 与假 uci 配置，让 macOS 上能验证所有平台无关代码；linux 走真 `ubus_invoke` / `uci_load` + 结构体遍历，libubus/libuci 非线程安全故用全局单例 + 锁串行化。 |
| `bindings/shim.odin` + `src/native/shim.c` | C 绑定层：`bindings/shim.odin` 声明 foreign import 与布局断言，真正连 uci/ubus/blobmsg 的 C helper 在 `src/native/shim.c`（zig 编译，只 linux 链接）。 |

对外暴露的只有三件事：`list_objects`、`call_object`、`uci_config_sections`（加错误文案表）。
**判定逻辑不在这里**——`depends` 的语义留在 `src/luci`，与上游 ucode 同层。

### 3.2 业务层

`src/http/`（传输与安全边界）：

| 文件 | 内容 |
|---|---|
| `uri.odin` | `normalize_path`：剥查询串/片段 → 百分号解码 → 逐段压掉 `.`/空段 → 拦 `..`。**安全边界**：编码非法回 400，逃逸回 403。 |
| `request.odin` | HTTP/1.1 请求解析状态机（请求行、头、body、keep-alive 与 body 消费记账）。 |
| `response.odin` | `Status` 枚举 + `reason` + `respond`（头与 body 的零拷贝发送）。 |
| `limits.odin` | 上限常量：头 8KB / 64 个、body 64KB、并发 32、读写超时 10s。契约类与自定类分开标注。 |
| `mime.odin` | 扩展名 → `Content-Type`（不区分大小写、不跨 `/`、未收录不猜）。 |
| `server.odin` | 监听、accept 循环、连接上限（超额 503）、一连接一线程、keep-alive 循环、连接私有 arena。 |

`src/luci/`（菜单语义，逐条对齐上游 `dispatcher.uc`）：

| 文件 | 内容 |
|---|---|
| `menu.odin` | `load_tree`（进程内 mtime 失效缓存）、`apply_spec`（逐键 spec 合并）、`descend`、`check_depends`（fs/uci 全形态）、`resolve`、`first_child`（含无会话时的 login 放行模式）、`effective_action`、`Auth_State`/`login_required`（`auth.login` 判定，见 `interfaces.md` §5.2）。 |
| `render.odin` | `dispatch`（firstchild/alias 下钻 → action 分派 → 200/404/501/403-登录）与 `render_placeholder` / `render_login_required`（占位页，不是模板渲染）。 |

### 3.3 接口层

| 文件 | 内容 |
|---|---|
| `src/main.odin` | CLI 解析、`--listen/--docroot/--menu-dir/--luci-prefix/--luci-render/--luci-strip`、SIGPIPE 忽略、`http.Server` 装配、`handle` 路由分派、路径边界匹配。 |
| `handlers/static.odin` | `/www` 下的静态文件（目录 → `index.html`，非 GET/HEAD → 405）。`/cgi-bin/*` 一律 403——上游 uhttpd 只执行它、从不吐脚本正文，见 `interfaces.md` §3。 |
| `handlers/ubus_http.odin` | `/ubus` 的三种形态与 JSON-RPC 信封（详见 `interfaces.md` §4）。 |
| `handlers/luci.odin` + `handlers/cgi.odin` | **专家版前缀**（用 Odin 重写的 LuCI）的两种渲染模式：默认 → `luci.dispatch`（内置 Odin dispatcher）→ 200/404/501/**403 登录提示**（带 `X-LuCI-Login-Required: yes`），只接 GET/HEAD；`--luci-cgi` 非空 → 整段前缀交给设备 ucode 子进程（ADR 0003 的 T1），只作**对照与排查**。前缀是变量（`--luci-prefix`），因为同一值还要当 CGI 的 `SCRIPT_NAME` 用。 |
| `handlers/simple.odin` | **简洁版**（`/lite`，`/` 是 302 入口）：把 `webassets/simple` 的单页发出去（**整个前缀下任意路径**都回同一份 HTML，路由在 `#/` 片段）。菜单来自 Odin 侧的 `src/assets/menu.odin`，**不读 menu.d**，渲染不经过 ucode。注入项（`__CFG__`）是 sid + 菜单 + 专家版前缀（页面据此出「前往专家版」链接）。 |
| `handlers/auth.odin` | 会话与口令：登录、`/auth/logout`、改密码（`POST /auth/password`）；改密的 shadow/openssl 原语按 `auth_linux.odin`（真机）/ `auth_darwin.odin`（桩）切分。 |
| `handlers/cgi.odin` + `handlers/cgi_run.odin` | CGI 子进程桥（`--luci-cgi`）：环境构造（SCRIPT_NAME/PATH_INFO 切分）→ 走 `spawn` 拉起 ucode → 解析响应头与 body → 透传状态与额外头。 |
| `handlers/cgi_io.odin` | **`/cgi-exec`、`/cgi-download`、`/cgi-upload`、`/cgi-backup`** 四端点（fs.exec_direct / read_direct / ui.uploadFile + 专家版备份）：会话取 POST 表单里的 `sessionid`，鉴权/落盘在 `backend/cgi_io.odin`，upload 侧还含 `multipart/form-data` 解析。 |

## 4. 一次请求的调用链

```
accept（server.odin，超额 503）
  └─ 连接线程：连接私有 arena + keep-alive 循环
       ├─ http 解析请求行/头/body（超限 → 413/411，非法 → 400）
       ├─ handle（main.odin）
       │    ├─ normalize_path（400 / 403 在这里终结）
       │    ├─ matches_prefix("/ubus")            → handlers.serve_ubus
       │    │     ├─ GET  /ubus/list[/<path>]     → backend.list_objects
       │    │     └─ POST /ubus | /ubus/call/<p>  → backend.call_object
       │    ├─ matches_prefix("/cgi-bin/luci")    → handlers.serve_luci
       │    │     └─ luci.load_tree → luci.dispatch
       │    │          └─ resolve → effective_action → render_placeholder
       │    │             （check_depends → backend.uci_config_sections / core:os）
       │    └─ 其余 → handlers.serve_static（os.stat → 读文件 → 送字节）
       └─ response.respond：状态行 + Content-Length + Content-Type + Connection
```

三条典型路径的差异只在「业务层被谁调用」：

| 请求 | 业务层入口 | 数据层调用 | 结果 |
|---|---|---|---|
| `GET /index.html` | `handlers/static` | 无（`core:os`） | 200 + `text/html; charset=utf-8` |
| `POST /ubus/call/session` | `handlers/ubus_http` | `backend.call_object` | 200 + JSON-RPC 信封 |
| `GET /cgi-bin/luci/admin/status/overview` | `handlers/luci` → `luci.dispatch` | `backend.uci_config_sections`（仅当节点有 `depends.uci`） | 200 + 占位页 |

**每次请求的内存**：HTTP 侧是「连接私有 arena + 每请求 `reset`」（`server.odin:91-114`）；
ubus 对象那侧没有连接的概念，所以四个 handler（backend 的 linux provider 里 session/uci/file/luci）
**各自起一个 `Dynamic_Arena`**，并把 `context.allocator` 也指向它——params、中间树、回复串、
cstring 副本都随 handler 返回一起释放。契约就是 `docs/interfaces.md` §7.1 的那条：
「回复串一律指向调用方给的 `alloc`（每请求 arena），实现不得返回需要调用方 `free` 的堆内存」。

**长期状态一律不走 arena**：会话数据、apply 等待窗口的 sid、SSE 订阅对象都用
`session_store_allocator()`（显式 `runtime.default_context().allocator`，即默认堆分配器，
对应上游的 `calloc`/`free`）。改这条路径前先想清楚「这东西活不活过这次请求」。

## 5. 依赖规则（硬规则）

1. **单向、无环**：`main → handlers → {http, luci, backend}`；`luci → backend`。
   `http` 与 `backend`（除 `bindings` 外）是叶子包。
2. **`src/luci` 不得 import `src/http`**：菜单语义不应该知道 HTTP 的存在；
   HTTP 状态码的映射属于 `handlers`（`render.odin` 只回 `.Page/.NotFound/.Not_Implemented/.Login_Required`
   这种业务结果）。
3. **`src/http` 不得 import `luci` 或 `backend`**：传输层不知道业务，它只提供
   `Server/Connection/Request/respond`。
4. **平台差异只能出现在两处**：`src/backend/{linux,darwin}.odin` 与
   `src/backend/bindings/*.odin` 的 `#+build` 标签。`src/http` / `src/luci` /
   `src/handlers` / `main.odin` 里**不得**出现 `#+build`。
5. **接口层不得直接碰 C 库**：uci/ubus 一律经 `backend`；`foreign import` 只允许
   出现在 `bindings/` 下。
6. **新增平台 = 新增 provider**：加一个 `#+build <platform>` 文件，写同名同签名的
   proc；签名漂移会在该平台的编译期暴露（macOS 上每次构建走的都是 darwin 那份）。

验证（门禁 `make test` / `make smoke` / `make device-*` 之外，规则本身可以随时 grep 复核）：

```bash
# 下面三条都应该**没有输出**（末尾的 || echo 只是让 set -e 下的脚本别中断）
grep -rn 'molly:' src/http src/backend/backend.odin | grep -v 'bindings' || echo ok   # http 必须是叶子包
grep -rn 'molly:http' src/luci || echo ok                                             # luci 不该知道 HTTP
grep -rln '#+build' src/http src/luci src/handlers src/main.odin || echo ok            # 平台差异只在 backend
```

2026-09-26 实测：三条均为空（规则当前成立）。

## 6. 为什么用 build tag 而不是 vtable

只有两个实现（darwin 假数据 / linux 真库），且差异集中在数据层。用
`#+build` + 同名 proc 的收益：

- **零间接层**：共享层直接 `backend.list_objects(...)`，没有接口值、没有动态分发。
- **签名漂移在编译期暴露**：macOS 每次构建都编译 darwin 那份，漏实现或签名不一致立刻报错
  （第 4 步的决策 2；`docs/../.ai-memory/p2-runtime-skeleton.md` 的「关键设计决策」）。
- **假数据让平台无关代码可验证**：HTTP、路由、dispatcher、`depends` 判定全在 macOS 上跑真代码，
  这是「无设备也能验证」的全部秘密（见 `testing.md` §7 的边界说明）。

## 7. 与上游语义的对应（可审计）

| 语义点 | 上游来源 | molly 实现 |
|---|---|---|
| HTTP/1.1 与各类上限 | `uhttpd` 的行为 | `src/http/`（自定取值待真机校准，风险 R7） |
| `/ubus` 各形态与错误码 | `uhttpd/ubus.c`（提交按 25.12.2） | `src/handlers/ubus_http.odin` |
| 会话来源 | `ubus.c:120-137`（`Authorization: Bearer`） | `auth_sid` |
| `menu.d` → 菜单树 | `modules/luci-base/ucode/dispatcher.uc:346-420` | `src/luci/menu.odin` 的 `apply_spec`/`descend` |
| `depends.fs` / `depends.uci` | `dispatcher.uc:171-196`、`:198-276`、`:279-310` | `check_depends` 族 |
| 通配 action | `dispatcher.uc:410-414`、`:1006-1011` | `wildcard_action_*` + `effective_action` |
| firstchild 竞选 | `dispatcher.uc:467-502` | `first_child`（并列时按段名定序，见下） |

**一处刻意的确定性替代**：上游 firstchild 并列权重时吃 ucode 对象的插入序，
molly 用「段名字典序」替代——语义等价性以可复现为先（`menu.odin` 的注释里写明了这点）。

## 8. P2 的边界与已知偏差

- **过渡期已是历史（P3-9）**：P3-1 起注册 `molly.probe`，P3-2…P3-5 陆续自持
  `session`/`uci`/`file`/`luci-rpc`，P3-6 起 `/ubus` 的**入站 ACL** 由 molly 按
  `/usr/share/rpcd/acl.d/*.json` 校验（不过就是 `-32002`，fail-closed）、dispatcher 的菜单
  也按会话 ACL 裁树（缺组 → 404、只有 read → 只读；**无会话**且路径上有 `auth.login`
  的节点 → 403 + `X-LuCI-Login-Required: yes` + 登录提示页，与上游状态码/响应头一致），
  P3-7 起 `/ubus/subscribe` 是真 SSE。设备上 rpcd 未停时同名对象注册失败（非致命，
  **逐对象**打一行诊断）——要接管就先 `/etc/init.d/rpcd stop`。**不再有** transitional 提示行，
  也**不再有**占位页的「ACL 未实施」横幅。
  **尚未收口**：登录**表单**本身（上游由 dispatcher 渲染 `sysauth` 并 `Set-Cookie`；
  这里走 `--luci-cgi` 的 ucode 侧，内置 dispatcher 只给登录提示页），以及**真机验收**（`make device-simple` + `make device-luci`，在设备上跑）。
- **不写 `/tmp/luci-indexcache`**：改用进程内 mtime 失效缓存，避免与真 LuCI 的缓存格式打架。
- **一连接一线程 vs uloop**（风险 R4，已按 ADR 0001 解决）：ubus 对象注册与事件都在
  **专用 ubus 线程**里跑 uloop；`/ubus/subscribe` 的 SSE 用**每订阅一根管道**把通知从
  ubus 线程交回 HTTP 线程（`src/backend/event_bus.odin` + `src/handlers/ubus_sse.odin`），
  HTTP 层因此不需要改成事件驱动。P3-7 的 S2 只差把真正的 ubus 订阅接进这条总线。
- **请求体超 64KB**：molly 回 413，上游 ubus 插件回 200 + `-32700` 并关连接——这是 HTTP 层的既有决策。
- **linux 侧只做到编译校验**：`uci_config_sections` 的遍历与 `#assert` 的布局断言都不等于运行期正确性，
  真机行为属第 7 步。
- **专家版前缀有两种模式**（ADR 0003）：默认是**内置 Odin dispatcher**（`src/luci`）——本站的
  **目标形态**，`tests/smoke.sh` 覆盖它的建树/depends/firstchild/通配/ACL 裁树/登录判定；
  视图层尚未落地，cbi/view/template 类节点回 501 并带 `action.type/view/menu`，那是待补的页面清单。
  给了 `--luci-cgi` 则整段前缀交给设备上的 ucode dispatcher（复刻 uhttpd 的 `ucode_prefix` 接线，
  `tests/smoke.sh` 用桩 CGI（`tests/fixtures/cgi/`）覆盖桥接本身）——那条现在是**对照与排查**用的基准，不是部署形态。
