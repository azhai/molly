# 架构：三层职责、模块划分、调用关系与依赖规则

molly 用 Odin 复刻 ImmortalWrt LuCI 的**服务端三层**。本文是架构的权威描述：
每层的职责边界、目录与模块、一次请求的调用链、以及**必须遵守的依赖规则**。
接口与协议细节见 [`interfaces.md`](interfaces.md)，测试分层见 [`testing.md`](testing.md)。

## 1. 范围：替换什么、不动什么

| 上游组件 | 职责 | molly 的对应物 | P2 状态 |
|---|---|---|---|
| `uhttpd` | HTTP/1.1 服务 + `/ubus` 插件 + CGI 转发 | `src/http/`（传输）+ `src/handlers/{static,ubus_http,cgi_luci}.odin` | 已实现 |
| `rpcd` | ubus 上的 `session` / `uci` / `file` / `luci` 对象（认证、会话、配置、ACL） | `src/backend/` —— **只做 HTTP 侧转发** | 过渡期：对象仍由设备上的 rpcd 提供，P3 才由 molly 注册（决策 7） |
| `ucode` dispatcher | `menu.d` → 菜单树 → 路径解析 → 渲染 | `src/luci/`（`menu.odin` 语义 + `render.odin` 占位页） | 已实现（模板渲染属 P3） |

**不动**：`/etc/config`（uci 数据）、`ubusd`（消息总线）、`/www`（静态文件）。

## 2. 分层总览

| 层 | 目录 | 职责（一句话） | 允许依赖 |
|---|---|---|---|
| **接口层** | `src/main.odin`、`src/handlers/` | 把 HTTP 请求映射成业务调用：进程装配、CLI、路由分派、三个 handler | `http`、`luci`、`backend` |
| **业务层** | `src/http/`、`src/luci/` | `http`：HTTP/1.1 传输与安全边界；`luci`：菜单树与 depends 语义 | `http` 谁都不依赖；`luci` → `backend` |
| **数据层** | `src/backend/` | 平台相关的 uci / ubus 访问，两个 provider 同名同签名 | `backend` → `bindings/`（仅 linux）；它们不依赖任何上层 |

```
                 main.odin
                    │  handle(): 规范化 → /ubus → /cgi-bin/luci → 静态
        ┌───────────┴────────────┐
        ▼                        ▼
   handlers/                 http/            ← 传输层：谁都不依赖（叶子）
   ├─ static.odin ──────────► http            （uri / request / response / limits / mime / server）
   ├─ ubus_http.odin ───────► http, backend
   └─ cgi_luci.odin ────────► http, luci
                                 │
                                 ▼
                              luci/            ← 菜单语义：只依赖 backend
                              ├─ menu.odin ──► backend
                              └─ render.odin   （只依赖 core）
                                 │
                                 ▼
                              backend/         ← 平台层：只依赖 bindings
                              ├─ backend.odin       契约 + 共享类型/常量
                              ├─ darwin.odin        #+build darwin：假数据
                              ├─ linux.odin         #+build linux：真 libuci/libubus
                              └─ bindings/*.odin    #+build linux：C 绑定 + 布局断言
```

## 3. 各层的模块清单

### 3.1 数据层 `src/backend/`

| 文件 | 内容 |
|---|---|
| `backend.odin` | **契约**（写在文件头的注释里）+ 共享类型与常量：`Call_Result` / `Call_Outcome`、`Uci_Section` / `Uci_Option`、`UBUS_STATUS_*` 与 `ubus_error_message`。Odin 不允许「只声明不实现」的 proc，所以这层是「注释即接口 + 两个 provider 提供同名实现」。 |
| `darwin.odin` | `#+build darwin` 的 provider：罐头 JSON 与假 uci 配置（`FAKE_UCI`），让 macOS 上能验证所有平台无关代码。 |
| `linux.odin` | `#+build linux` 的 provider：`ubus_invoke_fd` 真调用、`uci_load` + 结构体遍历；全局单例 context + `sync.Mutex` 串行化（libubus/libuci 非线程安全）。 |
| `bindings/*.odin` | 仅 linux 编译的 C 绑定：`libc`（只绑 `free`）、`blob`、`blobmsg`、`ubus`、`uci`。结构体布局按 `sysroot/usr/include/uci.h` 写，并配 `#assert(size_of/offset_of)` 兜底。 |

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
| `menu.odin` | `load_tree`（进程内 mtime 失效缓存）、`apply_spec`（逐键 spec 合并）、`descend`、`check_depends`（fs/uci 全形态）、`resolve`、`first_child`、`effective_action`。 |
| `render.odin` | `dispatch`（firstchild/alias 下钻 → action 分派 → 200/404/501）与 `render_placeholder`（P2 的占位页，不是模板渲染）。 |

### 3.3 接口层

| 文件 | 内容 |
|---|---|
| `main.odin` | CLI 解析、`--listen/--docroot/--menu-dir`、SIGPIPE 忽略、`http.Server` 装配、`handle` 路由分派、`matches_prefix`（带边界）。 |
| `handlers/static.odin` | `/www` 下的静态文件（目录 → `index.html`，非 GET/HEAD → 405）。 |
| `handlers/ubus_http.odin` | `/ubus` 的三种形态与 JSON-RPC 信封（详见 `interfaces.md` §4）。 |
| `handlers/cgi_luci.odin` | `/cgi-bin/luci` 的**两种模式**：`--luci-cgi` 非空 → 交给子进程（ADR 0003 的 T1）；否则 → `luci.dispatch` → 200/404/501，只接 GET/HEAD。 |
| `handlers/cgi_exec.odin` | CGI 桥接：环境构造（纯函数）→ `fork`/`execve` → 响应解析（纯函数）→ 透传状态与额外头。两个纯函数有单元测试，桩脚本有 `tests/cgi_smoke.sh`。 |

## 4. 一次请求的调用链

```
accept（server.odin，超额 503）
  └─ 连接线程：连接私有 arena + keep-alive 循环
       ├─ request.odin 解析请求行/头/body（超限 → 413/411，非法 → 400）
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
| `GET /cgi-bin/luci/admin/status/overview` | `handlers/cgi_luci` → `luci.dispatch` | `backend.uci_config_sections`（仅当节点有 `depends.uci`） | 200 + 占位页 |

## 5. 依赖规则（硬规则）

1. **单向、无环**：`main → handlers → {http, luci, backend}`；`luci → backend`。
   `http` 与 `backend`（除 `bindings` 外）是叶子包。
2. **`src/luci` 不得 import `src/http`**：菜单语义不应该知道 HTTP 的存在；
   HTTP 状态码的映射属于 `handlers`（`render.odin` 只回 `.Page/.NotFound/.Not_Implemented` 这种业务结果）。
3. **`src/http` 不得 import `luci` 或 `backend`**：传输层不知道业务，它只提供
   `Server/Connection/Request/respond`。
4. **平台差异只能出现在两处**：`src/backend/{linux,darwin}.odin` 与
   `src/backend/bindings/*.odin` 的 `#+build` 标签。`src/http` / `src/luci` /
   `src/handlers` / `main.odin` 里**不得**出现 `#+build`。
5. **接口层不得直接碰 C 库**：uci/ubus 一律经 `backend`；`foreign import` 只允许
   出现在 `bindings/` 下。
6. **新增平台 = 新增 provider**：加一个 `#+build <platform>` 文件，写同名同签名的
   proc；签名漂移会在该平台的编译期暴露（macOS 上每次构建走的都是 darwin 那份）。

验证（`AGENTS.md` §4.1 的门禁之外，规则本身可以随时 grep 复核）：

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

- **过渡期**：不注册任何 ubus 对象，启动打印 `WARN: transitional mode - ubus objects still
  provided by device rpcd`；占位页带「ACL 未实施」横幅。**不要把这个阶段的产物当可对外暴露的服务。**
- **不写 `/tmp/luci-indexcache`**：改用进程内 mtime 失效缓存，避免与真 LuCI 的缓存格式打架。
- **一连接一线程 vs uloop**：`/ubus/subscribe`（SSE）与 P3 的 ubus 对象注册都需要 uloop 事件线程，
  P2 明确回 501；这是 P3 前必须重新评估的架构分叉点（计划风险 R4）。
- **请求体超 64KB**：molly 回 413，上游 ubus 插件回 200 + `-32700` 并关连接——这是 HTTP 层的既有决策。
- **linux 侧只做到编译校验**：`uci_config_sections` 的遍历与 `#assert` 的布局断言都不等于运行期正确性，
  真机行为属第 7 步。
- **`/cgi-bin/luci` 有两种模式**（ADR 0003）：默认是**内置的 Odin dispatcher**（`src/luci`，P2 形态，
  `tests/http_smoke.sh` 覆盖）；给了 `--luci-cgi` 则整个前缀交给设备上的 ucode dispatcher
  （复刻 uhttpd 的 `ucode_prefix` 接线，`tests/cgi_smoke.sh` 用桩脚本覆盖桥接本身）。
  生产设备上按 ADR 0003 走后者；前者保留为「将来去 ucode」的对照实现与回归基准。
