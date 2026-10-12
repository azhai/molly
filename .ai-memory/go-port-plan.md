# gomolly —— 用 Go 复刻 molly（LuCI 服务端替换层）

> 任务：在 `/opt/repos/molly` 之外再用 Go 复刻一份，行为对齐 Odin 版 molly。
> 本文件是本次任务的权威计划（`.ai-memory/` 永不提交）。镜像：`.trae/documents/go-port-plan.md`。

## Context

- Odin 版 molly 约 16,625 行，四层：HTTP（`src/http`）→ 处理器（`src/handlers`）→
  backend 能力接缝（`src/backend`，`#+build linux|darwin` 双实现 + libubus/libuci/libblobmsg 绑定）
  → dispatcher（`src/luci`，menu.d 建树 / ACL 裁树 / 登录提示 / 渲染）。
- 已确认的环境：go1.27.1 darwin/arm64、zig 0.17.0、
  sysroot `~/openwrt-sdks/sysroot-aarch64_cortex-a53`（libubus/libuci/libubox/libblobmsg_json 齐全）、
  `tests/fixtures`（acl.d / menu.d / www / cgi / board.json）可直接复用。

## 范围决策（用户跳过了范围提问 → 取最小可用骨架，后续增量补齐）

落点：`/opt/repos/molly/gomolly/`，独立 `go.mod`，**不动** `build.sh` / `src/` / `tests/`。
里程碑：

| # | 内容 | 验收 |
| --- | --- | --- |
| M1 | 模块骨架 + CLI（`--listen/--docroot/--menu-dir/--luci-cgi/--ubus-socket/-h`）+ HTTP 1.1 服务 + 路由顺序 + 静态文件 + URI 规范化 | `go test ./...` 全绿；本机 curl 能取到 fixture 静态文件；非法编码 400、`..` 逃逸 403 |
| M2 | `/ubus` JSON-RPC 信封（旧式 + 新式 `/ubus/call/<path>`、Bearer、全错误码）+ `list` + `call` 透传 | darwin 假数据下与 Odin 版 http_smoke 的断言一致 |
| M3 ✅ | dispatcher：menu.d 建树、`depends` 求值、ACL 裁树、无会话 403 登录提示、占位页/404 + `--luci-cgi` 子进程桥 | 复用 `tests/fixtures/menu.d`；对照 Odin 版 `menu_test.odin` 用例 |
| M4 ✅ | 四个 ubus 对象（session/uci/file/luci-rpc）+ probe + SSE | darwin 假数据下 `tests/smoke.sh` 通过 284 失败 0 |
| M5 ✅ | 交叉编译上设备（cgo + zig cc）+ golden 对比 + RSS 压测 | 真机实测：/ubus 探针 **HTTP 对 HTTP** 归一化对比，差异仅限 §9.3 已记录偏离（详见「M5 设备验收」，脚本的 CLI-vs-HTTP compare 不可直接用作准则） |
| M6 ✅ | **双界面**：`--luci-prefix`（专家版迁到 `/plus`，原 `/cgi-bin/luci`）+ `/lite` 新手版（六件事，`/` 是 302 入口），两套界面共用一条会话 | 真机 22/22：`/plus/` 登录与页面、`/lite/` 注入同一 sid、`/` 302、`/cgi-bin/*` 不外发。细节见 `.ai-memory/dual-ui-prefix-and-novice.md` |
| M7 ✅ | 前端资源统一到根 **`webassets/`**（luci-static 兜底副本 + 新手版页面）；两套界面统一成**一条会话**（服务端登录/退出 + 会话 cookie 的 path 放宽到 `/`） | `go test ./...` 全绿、`tests/smoke.sh` **310/0**；真机会话统一 **18/0**（新手版登录下发的 cookie 在专家版直接 200，反之亦然；退出后立即失效） |

## 关键设计决策

1. **接缝用 Go 惯用法**：`internal/backend` 定义 `Backend` interface，
   `backend_linux.go`（cgo 真实现）/ `backend_darwin.go`（假数据）各给一个 `newBackend()`。
   与 Odin 版「同名同签名、编译期暴露漂移」语义等价，但改用 interface 更合 Go 习惯。
2. **HTTP 层复用 stdlib `net/http`**（复用阶梯第 3 级），不手写解析器；但**不用 `ServeMux`**
   ——`ServeMux` 会对 `//`、`..` 做 301 重定向，与 molly 的 400/403 语义冲突。
   改为单个 catch-all handler + 自写 `normalizePath`，逐条对齐 molly 的边界行为。
3. **cgo 只出现在两处**：`internal/backend/backend_linux.go` 与 `internal/cbind/`
   （libubus / libuci / libblobmsg 的绑定，对应 Odin 的 `src/backend/bindings/*.odin`）。
   `cbind` 用 `//go:build linux && cgo`，与 Odin 的 `#+build linux` 只影响 target 一致。
4. **零第三方依赖**：只用 stdlib（`net/http`、`encoding/json`、`os/exec`）。
   JSON-RPC 信封与 ubus 状态码表逐字复刻（见 `src/backend/backend.odin:106-152`）。
5. **交叉编译复用现有工具链**：
   `CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="zig cc -target aarch64-linux-musl"
   CGO_CFLAGS="--sysroot=$SYSROOT -I/usr/include" CGO_LDFLAGS="--sysroot=$SYSROOT -L/usr/lib -luci -lubus -lblobmsg_json -lubox"`。
   与 `build.sh --target` 同一套 sysroot 与库顺序（uci/ubus 依赖 ubox，blobmsg_json 依赖 json+ubox）。

## 已验证的事实（代码依据，非猜测）

- CLI 五个开关与默认值：`src/main.odin:21-23,54-99`。
- 路由顺序：`normalize_path` → `/ubus` 前缀 → `/cgi-bin/luci` 前缀 → 静态；
  **前缀必须带边界**（`/ubus.html` 不能被 ubus 抢走）：`src/main.odin:161-202`。
- 接缝契约（`list`/`call`/uci 数据形状/`start_ubus_server`）：`src/backend/backend.odin`。
- target 链接细节与库顺序：`build.sh:117-138`。
- ubus 状态码枚举 + `ubus_strerror` 文案表：`src/backend/backend.odin:106-152`。

## 验证方式（门禁）

现在仓库根就是 module 根，且有 Makefile（2026-10-07 新增）——**日常只用 make**：

```bash
make lint      # gofmt 检查 + go vet（每次改动必跑）
make test      # go test -count=1 ./...
make smoke     # 起 7 个实例（18080 dispatcher + 18081..18085 CGI 桥 + 18086 前缀可配）
make build     # darwin 原生：build/gomolly-host
make target    # 交叉编译设备产物：build/gomolly-arm64
make deploy    # 交叉编译 + 部署到设备（停服务 → 覆盖 → 启动 → 回状态）
make help      # 全部目标与可覆盖的变量
```

Makefile 里 `target` 的交叉编译配置（就是 M5 那套环境变量，只是收进了 Makefile）：

```
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 GOARM=8
CC="zig cc -target aarch64-linux-musl"
CGO_CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include" CGO_LDFLAGS="--sysroot=$SYSROOT"
```

`SYSROOT` 默认 `~/openwrt-sdks/sysroot-aarch64_cortex-a53`（注意目录名是 **aarch64**，
不是 arm64），`ZIG` 默认 `zig`，两者都能 `make target SYSROOT=... ZIG=...` 覆盖。
`make target-embed` 是把设备前端资源也编进去的变体（`-tags embed_assets`，需先跑
`tools/embed-assets.sh`）。

`tests/smoke.sh` = Odin 版 `tests/http_smoke.sh` + `tests/cgi_smoke.sh` 合并成一份，
覆盖 M1-M3 全部断言（路由/静态/规范化 + /ubus 信封 + dispatcher + CGI 桥）+ 双界面 + 会话统一。

## 进度与会话记录（新在前）

### 2026-10-09 — 修设备侧 index.uc 被改坏导致 :80 只剩状态页（菜单 500）

- **症状**：用户报 :80 只剩一个状态页、其他菜单没了。
- **排除 molly**：:80 原生登录与「molly cookie 打 :80」行为**完全一致**（同一页、同一菜单状态），
  且 molly 在 :8080、不碰 menu.d；菜单是前端 JS 去 `GET /admin/menu` 现建的（服务端 HTML 里
  `#topmenu` 本就 `display:none` 空）。故与 :8080/方案1 会话无关。
- **真因**：`/cgi-bin/luci/admin/menu` 返回 **error500 HTML**（非 JSON）——页内报
  `Unable to compile source file '/usr/share/ucode/luci/controller/admin/index.uc': Syntax error`。
  定位到 **154 行**：早先给 :80 打「认 sysauth_molly」补丁时，`'`（ASCII 0x27）被误当成字面量
  `x27` 写进了 dispatcher.is_authenticated 的 methods 数组→该 controller 编译不过→`action_menu` 抛 500→
  前端建不起菜单。menu.d 本身没被裁（`luci-base.json` 与 `.molly-bak` 顶层 admin 节点一致）。
- **修复**：把 154 行还原为正确单引号、**保留 `'cookie:sysauth_molly'`**（:80 靠它读共享 cookie 认证）：
  `methods: [ 'cookie:sysauth_https', 'cookie:sysauth_http', 'cookie:sysauth_molly' ]`。
  做法：取回文件→工作区 `build/` 里 SearchReplace→scp 推回（改前先备份坏版 `index.uc.broken-bak`）。
  与出厂 bak 相比**仅差这一处预期改动**。
- **验证**：ucode `loadfile` 编译 OK；`/admin/menu` 回 19 KB JSON，admin 一级 = system/network/services/
  status/nas/vpn 均 `satisfied=true`；一级落地页 network/system/services/status/nas → 200（vpn 404 是
  空节、无关）。扫全部 controller：除我新建的 `.broken-bak` 外无残留 x27、均编译通过。
- **未改 molly 代码**：纯设备侧文件修复，不动 Go 产物/门禁。教训见记忆「改设备 .uc 后必做 ucode 编译校验」。

### 2026-10-09 — 方案 1 收尾：桥接态自有对象的内部 ACL 也要转问 rpcd（:8080 频繁 Permission denied）

- **症状**：方案 1 后两边能一起登录/退出，但 :8080 频繁「Permission denied」。
- **定位**：用 `/auth/login` 真实 sid 逐条打 SPA 会发的 RPC——`uci.get`、`file.exec` 回
  **code 6「Permission denied」**，而外部对象（`system.board`）与不查 session 的自有对象
  （`luci-rpc.getDHCPLeases`）正常。根因：molly 进程内自有的 `uci`/`file` 对象实现**内部**还调
  `sessionAccess(sid, scope, …)`（`uci_object.go:351/360/552/1101`、`file_object.go:188`）做第二道
  ACL，读的是 molly 私有 `sessionStore`；桥接态真会话在 rpcd、私有存储空 → 判否 → code 6。
  `device_luci` §5 只测转发式/`params` 里不带 `ubus_rpc_session` 的路径（`if len(sid)==0 return true`
  跳过内部鉴权），所以没覆盖到，才漏过。
- **修复**：桥接态把这道**内部 ACL 也交给 rpcd**，与 HTTP 前置 ACL 同源。加 `sessionAccessBridge`
  钩子（`session.go`，`sessionAccess` 于取 `sessionMu` 前先问钩子；darwin/非桥接恒 nil → 原行为不变）；
  `linux.go` 抽出 `rpcdSessionAccess(sid,scope,object,function)`（转 rpcd `session.access`、fail-closed），
  `SetSessionOnBus(true)` 装配桥接、`SessionAccessUbus` 复用它。`CallObject` 在 line 119 跑
  `callOwnObject` 时**尚未持 `ubusMu`**（锁在 127），故内部再转 rpcd 不自锁。
- **门禁**：宿主 vet/test 全绿、smoke **334/0**、`make target` arm64/musl 通过。
- **真机复验（pid 32443）**：`uci.get`(system/network)、`file.exec /bin/df` 均从 code 6 恢复为 **ret 0**；
  `device_luci.sh(/admin)` 仍 **通过 47 失败 0**；molly/rpcd/uhttpd/ubusd 齐、:80 与 :8080 并存。
- **部署**：`make deploy` 上传步在 macOS 撞 sshpass+管道抖动，仍用 `sshpass scp -O` 绕开；zsh 多词
  选项要么内联要么 `${=OPTS}`，且内联 ssh 命令用 `-T` 关 pty 更稳。

### 2026-10-09 — 方案 1：桥接态会话统一到 rpcd（原版 :80 LuCI 与 molly 共用一条 cookie）

- **起因**：用户报「原版 :80 的 LuCI 登不进去」。四发探针定位根因——桥接态（init.d：系统总线
  + 未停 rpcd）下 `sysauth_molly` 背后有**两套会话存储**：:80 与 :8080 `/admin`（经 ucode→rpcd）
  用 **rpcd 的 session**；:8080 `/lite`、`/auth`、molly 自身 `/ubus` 用 **molly 进程内私有存储**。
  cookie 只认「主机+路径」、**不分端口**，两边登录态互相覆盖、彼此判为无效（molly-native sid
  打 :80 = 403；rpcd sid 打 molly `/ubus` = -32002）。
- **方案 1（用户选定）**：桥接态让 molly 原生侧（`/lite`+`/auth`+`/ubus`）的**会话与前置 ACL 交给
  总线上的 rpcd**，其余自有对象（uci/file/luci-rpc）仍由 molly 进程内服务。一个 `sessionOnBus`
  标志门控（= `--luci-cgi` 且走系统总线），非桥接态/darwin 行为完全不变。
- **改动面**：
  - `backend.Backend` 接口加 `SessionSelfService(sid, method)`（原 `ubus.go` 直接调包函数，改走接口）。
  - `linux.go`：`SetSessionOnBus(on)` + `sessionOnBus` 变量；`CallObject` 在桥接态把 **session 对象转发
    总线**（登录产出 rpcd sid）；`SessionAccessUbus` 桥接态改问 rpcd `session.access`；`SessionSelfService`
    桥接态按 sid 形态放行、有效性交给被转发的 rpcd 兜底。uci/file/luci-rpc/molly.probe 数据面不动。
  - `darwin.go`：补 `SessionSelfService` 接口实现 + `SetSessionOnBus` 空操作。
  - `main.go`：`backend.SetSessionOnBus(*luciCGI != "" && *ubusSocket == "")`。
- **关键坑（第一版没打通、复测发现）**：转发后 molly 登录产出的确实是 rpcd sid（`session.get` 只回
  `{username}`、rpcd 认），但**原版 :80 仍 403**——因为裸 `session.login` 只写 username，而设备 ucode
  dispatcher 判「已登录」要求会话里有一个**字符串 token**（dispatcher 在 login 后额外 `session.set`）。
  → 在 `auth.go` 加 `ensureSessionToken`：molly 转发 login 拿到 sid 后补 `session.set {values:{token}}`。
  内置态 `sessionDoLogin` 本就写 token，覆盖一次无害。
- **门禁**：宿主 `go vet`/`go test`/`./tests/smoke.sh` **334/0** 全绿；`make target` arm64/musl 通过。
- **真机复验（pid 28430，rss ~14 MB）**：`device_luci.sh(/admin)` **通过 47 失败 0**（回归不破）；
  molly `/auth/login` sid → `session.get` 回 `{token,username}` → **★ 同一条 cookie 打原版 :80 = 200**
  （原 bug 修复；无 cookie 对照仍 403）、打 :8080 `/admin` = 200；`/auth/logout` 后 :80 回到 403
  （`session.destroy` 转发 rpcd 生效）。rpcd/uhttpd/ubusd 照常，:80 与 :8080 并存。
- **部署插曲（非代码）**：`make deploy` 的 `cat target | ssh 'cat>dest'` 这步在 macOS 上撞上
  `sshpass`+管道 stdin 抖动（ssh 退回 `ssh_askpass` 交互提示 → Permission denied）。改用
  `sshpass scp -O` 上传（不走管道）等价完成；另 zsh 不对无引号变量分词，多词 `$OPTS` 要 `${=OPTS}`。

### 2026-10-09 — 真机复验（deploy + device_luci.sh）：修一处测试脚本的写死前缀

- **动作**：`make target`（arm64/musl，`-s -w` → 7.27 MB）→ `make deploy`（init.d 的 T1 形态：
  `--docroot /www-molly --luci-prefix /admin --luci-strip admin --luci-cgi "/usr/bin/ucode
  /www-molly/cgi-bin/luci"`，:8080，系统总线）→ `MOLLY_DEVICE_PASS=*** ./tests/device_luci.sh`。
  宿主门禁先行全绿：`go test` ok、`./tests/smoke.sh` **334/0**。
- **首轮 25/22**：§0 未登录 403 判定 ok，但**登录/页面/并发全 FAIL，返回 403 + 10 字节正文且无
  `x-luci-login-required`**——那是 `internal/handlers/static.go` 的 `/cgi-bin/*` 守卫回 `forbidden\n`，
  请求根本没进 dispatcher/CGI 桥。而 §4/5（molly 自身 `/ubus`）与静态资源**全过**。
- **根因（非 molly 缺陷）**：`tests/device_luci.sh` 把专家版前缀**写死成 `/cgi-bin/luci`**，而本机部署
  经 `--luci-prefix /admin --luci-strip admin` 把它挂在 **`/admin`**。脚本自己的注释早就写着
  「前缀由部署给（本站 /admin），别写死」——是脚本没跟上部署形态。手工实证 `/admin` 一切正常：
  未登录 403+`x-luci-login-required: yes`+登录页；表单登录 302+`set-cookie: sysauth_molly=…; path=/`；
  9 页面全 200 非空；40 并发全 200 无 503。
- **修复**：脚本改用 `MOLLY_LUCI_PREFIX`（挂载前缀，默认 `/cgi-bin/luci`）+ `MOLLY_LUCI_SUB`
  （前缀之后 URL 里那段，默认 `/admin`；配 `--luci-strip admin` 的站给**空串**，用 `${VAR-}` 而非
  `${VAR:-}` 才允许显式空）。§0/§1 打 `$LUCI/`，§2/§6 打 `$LUCI$SUB/<rel>`。默认分支保持旧契约不变。
- **复验**：`MOLLY_LUCI_PREFIX=/admin MOLLY_LUCI_SUB= ./tests/device_luci.sh` → **通过 47 失败 0**
  （对齐 M5「通过 47」基准）。进程 pid 不变、VmRSS 15.9 MB；rpcd/uhttpd(:80 原版 LuCI) 不受影响。
- **观察（非本轮修）**：init.d 走**系统总线**且未停 rpcd → molly 注册 session/uci/file/luci-rpc 全报
  error code 2（名字被 rpcd 占）。T1 桥接形态下无碍：ucode 经系统总线用的是 **rpcd** 的真对象（正是
  对照基准），molly 自身 `/ubus` 走进程内 backend 应答——所以 §4/5 照过。日志里那几条注册失败属
  「非致命诊断」，设计如此。

### 2026-10-06 — M1 完成（HTTP 服务 + 路由 + 静态文件）

落点 `gomolly/`：`go.mod`、`cmd/gomolly/main.go`、`internal/httpx/{uri,mime}.go`、
`internal/httpx/uri_test.go`、`internal/handlers/{response,static}.go`、`tests/smoke.sh`。

- **验收**：`gofmt -l` 空、`go vet ./...` 通过、`go test ./...` 通过（httpx 表驱动 18+12 用例）、
  `tests/smoke.sh` **通过 25 失败 0**、`build/gomolly-host` 8,219,954 bytes（darwin 原生）。
- **已验证的对齐点**：路由顺序与带边界的前缀匹配；`normalize` 的 400/403 语义；
  静态文件的目录回落、非普通文件 404、POST 405；HEAD 回完整头无 body；
  **故意不发 Date / Server 头**（`w.Header()["Date"] = nil` 实测可抑制 net/http 自动补的 Date）。
- **踩坑（已修）**：
  1. `curl -X HEAD` 会挂死——它只换请求行方法，curl 仍按「有 body」读；脚本里必须用 `-I`。
  2. bash 里 `$VAR` 紧跟全角标点（`，`）会被当成变量名的一部分 → 报 unbound variable；
     必须写 `${VAR}`（与 Odin 版 `build.sh:85-86` 是同一个坑）。
  3. 用 `r.RequestURI` 而不是 `r.URL.Path`：后者已被 Go 解码，丢掉 `%2f` 与 `/` 的区别，
     规范化就拿不到原始字节判 400/403。
- **已知偏离（待 M2/M3 继续对齐）**：`net.Listen` 接受主机名（Odin 版只接受数字地址）；
  `net/http` 自行决定 `Connection` 头；未自建请求行/头/体上限（下一步按 Odin 版
  `src/http/request.odin` 的常量设 `MaxHeaderBytes` 等）。

### 2026-10-06 — M2 完成（/ubus JSON-RPC 信封 + backend 接缝）

新增/改动：
- `internal/backend/backend.go`：`Backend` 接口 + `CallResult`/`CallOutcome` + 14 条 ubus
  状态码与 `UbusErrorMessage`（文案表逐字抄 libubus.c 的 `__ubus_strerror`）。
- `internal/backend/darwin.go`：假对象表（file/luci/luci-rpc/molly.probe/session/uci）+
  `New()`；`CallObject` 走「签名子串判方法存在 → 回显 echo」。
- `internal/backend/linux.go`：`//go:build linux` 骨架，fail-closed（真 cgo 留到 M5）。
- `internal/handlers/ubus.go`：信封全部逻辑（旧式 `/ubus` 单/批请求、新式
  `/ubus/call/<path>`、`Authorization: Bearer` → 哨兵 sid、GET `/ubus/list[/<path>]`、
  OPTIONS 200 / 其余 400、错误优先级「对象存在性 → 参数校验」）；七个 JSON-RPC 错误码
  `-32700/-32600/-32601/-32602/-32603/-32000/-32002`。
- `internal/handlers/ubus_test.go`：表驱动单测（信封各分支 + 路由边界）。
- `cmd/gomolly/main.go`：router 持有 `backend.Backend`，签名改为 `ServeUbus(w,r,path,be)`。
- `tests/smoke.sh`：M1 的两条 `/ubus 501` 断言改为 `404`，追加 /ubus 断言。

**验收**：`gofmt -l` 空、`go vet ./...` 通过、`go test -count=1 ./...` 全绿、
`tests/smoke.sh` **通过 70 失败 0**、`build/gomolly-host` 9,329,778 bytes（darwin 原生）。

**已验证的对齐点**：`result` 形态（旧式恒 `[0,{…}]` / 新式裸表 / 无回复 `null`）；
缺 id 与 `id:null` 都回 `null`；`params` 缺失=空表而 `params:null`=-32602；
对象存在性优先于参数校验；未知方法回 ubus 状态码 3（不是 -32601）；
GET list 的 500 回 ubus 错误码 4（不是 JSON-RPC 码）；批请求与空数组 `[]`。

**已知偏离（记录在案，M4 补齐）**：
1. uhttpd 的前置 ACL 校验（不过 → -32002）**尚未接**——它需要 session 对象，属 M4。
   因此哨兵会话目前能调用任意对象（Odin 版会回 -32002）。M4 会在 `invoke` 的对象
   存在性检查之后补上这一步。
2. `/ubus/subscribe` 仍回 501 占位（M4 的 SSE）。

**踩坑（已记）**：Go 的 `json.Unmarshal` 把 `params:null` 解进 slice 时返回 nil error，
不能靠 error 判「是不是数组」——必须先用 `firstByte` 看容器类型。

### 2026-10-06 — M3 完成（dispatcher + CGI 子进程桥）

新增/改动：
- `internal/luci/menu.go`：`build_pagetree` 语义（menu.d 逐键合并、`depends.fs` / `depends.uci`
  求值、通配 `*` 段、`firstchild` 竞选、`apply_tree_acls`）。修复 `applySpec` 传 `nil` deps
  导致 depends.uci 节点全失效的缺陷——把 `Deps` 从 `LoadTree` 一路贯穿到 `checkDepends`
  （进程内单 backend 实例，等价 Odin 版包级 backend）。
- `internal/luci/render.go`：`Dispatch` = resolve → 登录判定 → firstchild/alias 下钻 → 501 /
  占位页；四态 `KindPage/KindNotFound/KindNotImplemented/KindLoginRequired`；
  `readonly` 由 `SessionACLLevel(sid, groups) == ACLReadOnly` 每请求现算。
- `internal/luci/menu_test.go`：假 Deps + fixture 建树，14 个 dispatch 用例 + ACL 三态 +
  fs/uci 各形态 + 通配 action + 逐键合并 + request_args 转义。
- `internal/handlers/luci.go`：`ServeLuci`（LuciCGI 非空 → 子进程；否则内置 dispatcher，
  只接 GET/HEAD）+ `luciSIDFromCookie`（`sysauth_https` / `sysauth_http`）。
- `internal/handlers/cgi.go`：CGI 桥——`buildCGIEnv`（REQUEST_METHOD/SCRIPT_NAME/PATH_INFO/
  QUERY_STRING/DOCUMENT_ROOT/REMOTE_ADDR/CONTENT_* + 排序后的 `HTTP_*` + 单独补的 `HTTP_HOST`
  ＋`MOLLY_UBUS_SOCKET`）、`parseCGIResponse`、`runCGI`（`os/exec`，避免手写 fork/execve 的
  async-signal-safe 逻辑与管道死锁）、`exitDesc`。
- `internal/handlers/cgi_test.go`：响应解析 7 子用例 + 环境构造 + splitCommand + headerEnvName。
- `internal/handlers/response.go`：加 `ExtraHeader` + `RespondFull`（多响应头 + molly 重算
  Content-Length）。
- `cmd/gomolly/main.go`：router 加 `ubusSocket`，`ServeLuci` 用 `LuciConfig`。
- `tests/smoke.sh`：合入 Odin 版 `cgi_smoke.sh` 的 5 个桩实例（18081-18085）；`/cgi-bin/luci`
  从 M1 的 501 占位改为断言 403 + `X-LuCI-Login-Required`；追加 dispatcher 段与 CGI 桥段，
  新增 `h1_of`/`view_of`/`readonly_of`/`body_of`/`code_of` 辅助。

**验收**：`gofmt -l` 空、`go vet ./...` 通过、`go test -count=1 ./...` 全绿（handlers/luci/httpx
三包）、`tests/smoke.sh` **通过 159 失败 0**、`build/gomolly-host` 9,610,738 bytes（darwin 原生；
未加 `-s -w`，故比 Odin 版大）。

**已验证的对齐点**：dispatcher 对 fixture 的 14 个行为；ACL 三态（缺组裁树 404 / firstchild
跳过 → logs、只读标 readonly、有 write 正常）；`depends.fs` 五种形态 + 非 object 备选忽略；
`depends.uci` 十种形态（含 `@type` 匿名 section、option 值精确匹配、config 无 section /
不存在）；通配段的 base action 与 wildcardaction 分离 + request_args；同路径逐键合并（title
保留 / probe 的 action 生效）；schema 白名单外键仅忽略该键；无会话 → 403 登录提示（带请求
路径，不是 404）；POST 405；HEAD 三处「有头无体」；CGI 环境构造、请求体透传（含 64KB 无死锁）、
Status/Location/Set-Cookie/Cache-Control 透传、Content-Length 重算、缺 Content-Type / 无输出
→ 500、keep-alive 复用。

**踩坑（已记）**：
1. `httptest.NewRequest` 传完整 URL 会把 `RequestURI` 设为完整 URL → CGI 环境里
   `REQUEST_URI` 变成 `http://…`。必须传 path-only target。
2. 测试辅助 `childOf` 与包内 `childOf(n, seg)` 同包重名 → 改名 `nodeAt`。
3. `gofmt -l` 对未格式化新文件报错 → 每次改完先 `gofmt -w`。

**已知偏离（记录在案）**：
1. 内置 dispatcher 只渲染占位页（不对齐上游 ucode 模板）；生产走 `--luci-cgi`（ADR 0003）。
2. 非 view 的 `action.type`（cbi/form/template/function/call）→ 501 + 命中信息，与 Odin 版一致。
3. `--luci-cgi` 模式不校验方法（由脚本自判），与 Odin 一致。

### 2026-10-06 — M4 完成（四个 ubus 对象 + probe + SSE + 前置 ACL）

新增文件（`internal/backend/`）：
- `event_bus.go`：事件总线。Odin 版是容量 32 的管道，Go 版换成带缓冲 channel
  （`eventBusBacklog=16`），语义保持「上限 `eventBusMax=32` / 非阻塞写满即丢 /
  首订阅触发 `sseWatchStart`、末订阅触发 `sseWatchStop`」。
- `file_object.go` + `file_object_test.go`：file 对象 8 方法（read/write/list/lstat/stat/md5/remove/exec），
  平台无关真实现。安全检查顺序＝文本路径规范化 → ACL → realpath → 解析后的路径再查一次 ACL；
  权限名按方法区分（read/write/list/exec）。
- `uci_object.go`（因子代理交付，约 1361 行）+ `uci_darwin.go` + `uci_linux.go` + `uci_object_test.go`：
  uci 对象 15 方法 + 20 个 `uciProvider*` 平台钩子。
- `luci_object.go` + `luci_darwin.go` + `luci_linux.go` + `luci_object_test.go`：luci-rpc 对象 6 方法
  （getBoardJSON/getDHCPLeases/getDUIDHints + 3 个设备绑定方法）。

改动：
- `internal/backend/darwin.go`：`CallObject` 按 Odin 顺序挂上四个分支——session → file → uci →
  luci-rpc → `molly.probe` 的 `notify`（Publish `ping` + `{"hello":"world"}`，回 `{"notified":"molly.probe"}`）
  → 假对象签名子串判方法 → echo。
- `internal/handlers/ubus.go`：接上真 SSE（`GET /ubus/subscribe/<path>`）——`:subscribe`
  伪方法 ACL 点、`text/event-stream` 帧 `event: <method>\ndata: <json>\n\n`、30s 心跳 `: heartbeat\n\n`、
  不过 → HTTP 200 + `application/json` + posix `-13`、对象不存在 → 200 + ubus 码；
  并在 `invoke` 里补上 uhttpd 前置 ACL（对象存在性 → ACL(-32002) → 参数校验，session 自服务例外）。
- `internal/handlers/ubus_test.go`：加 `TestMain` 把 `GOMOLLY_ACL_DIR` 指向仓库 fixture
  （`../../../tests/fixtures/acl.d`）+ `testSID(t)` 助手（登录 root/test1234）。
- `tests/smoke.sh`：M2 段改为复用 `P2SID`（登录会话）并补 4 条前置 ACL 断言；
  新增 SSE 段；新增 P3-2/P3-3/P3-4/P3-5 四段对象断言（约 115 条）。

**验收**：`gofmt -l` 空、`go vet ./...` 通过、`go test -count=1 ./...` 全绿（backend/handlers/httpx/luci
四包）、`GOOS=linux GOARCH=arm64 go build ./...` 通过、`tests/smoke.sh` **通过 284 失败 0**、
`build/gomolly-host` **9,767,890 bytes**（darwin 原生；未加 `-s -w`）。

**已验证的对齐点**：前置 ACL 的三条优先级（对象存在性优先于 ACL；session 自服务例外；
哨兵除 login 外一律 -32002）；SSE 全部分支（哨兵 → json -13、无效 Bearer → -32002、
对象不存在 → ubus 码、成功 → event-stream + 心跳 + 事件帧）；session 对象 15 方法；
uci 对象 configs/get/changes 与写路径、apply 系在 darwin 的 `StatusNotSupported(8)`；
file 对象 8 方法 + 符号链接复查 + exec；luci-rpc 的 board.json / 租约 / linux-only 回 8。

**已知偏离（记录在案，M5 收口）**：
1. `file.stat` 省略 atime/ctime/inode（对齐其核心字段即可，未逐字复刻 stat 结构）。
2. `file.exec` 用 `os/exec` + context 同步实现（上游 uloop 异步）；输出超 64KB → 8、
   超时 120s → 7、启动失败 → 127。
3. linux 侧（`linux.go` 与 `uci_linux.go`/`luci_linux.go`）整体仍 fail-closed，真 ubus/uci 调用留 M5。

**踩坑（已记）**：
1. 加前置 ACL 后单元测试 ACL 目录取不到 → 登录也回 -32002。darwin 默认路径是相对**包工作目录**，
   `TestMain` 必须写三段 `..` 指到仓库根 fixture。
2. `luci_darwin.go` 的 `luciRPCBoardPath()` 同理用 `../tests/fixtures/board.json`（相对 gomolly cwd），
   smoke.sh 另设 `GOMOLLY_BOARD_JSON` 绝对路径双保险。
3. 后台子代理在「准备写」阶段提前结束、仓里无文件——`resume` 报 ID not found，
   只能新起代理并给完整 brief（入口签名 + 可复用 helper + 安全顺序 + 断言清单 + 验收命令）。

### 2026-10-06 — M5 侦察（已实测，勿重做）

**工具链已实测可用**：zig 0.17.0；sysroot `~/openwrt-sdks/sysroot-aarch64_cortex-a53`
（libubus.so / libuci.so / libblobmsg_json / libubox 与头文件齐全，头在 `usr/include/`：
`libubus.h`、`uci.h`、`libubox/blobmsg_json.h`）；设备 `192.168.1.1` 可达。

**交叉编译配方（已验证，两个坑）**：
```
CC="zig cc -target aarch64-linux-musl"
CGO_CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include"     # 坑①：--sysroot 下 -I/usr/include 解析不到头，必须用绝对 sysroot 路径
CGO_LDFLAGS="--sysroot=$SYSROOT -L/usr/lib -luci -lubus -lblobmsg_json -lubox"  # 坑②：-L 必须 sysroot 相对（-L/usr/lib），绝对路径会被拼成 $sysroot/$abs
```
已实测：纯 cgo 程序交叉编译出 aarch64 ELF；`#include <libubus.h>` + `-luci -lubus …` 链接通过
（`--as-needed` 下无引用时 NEEDED 只剩 libc.so，属正常）。

**部署模型**：gomolly 连 ubusd **系统总线**（默认 socket），自己注册
`session`/`uci`/`file`/`luci-rpc`/`molly.probe` 五个对象（即替代 rpcd；设备上需
`/etc/init.d/rpcd stop` 才能接管，逐对象注册失败只打诊断、非致命）。`--ubus-socket`
是可选私有总线模式（此时系统对象要走系统总线回退）。`--luci-cgi` 模式会把
`MOLLY_UBUS_SOCKET` 传给子进程——说明 ucode 侧也会经 ubus 调 session/uci，
**所以必须真注册对象，不能只在进程内直连**。

**Odin `src/backend/linux.odin` 结构（行号地图，107KB）**：
`set_ubus_socket`(102)/`ubus_socket_path`(112)/`ubus_connect_own`(121)/`ubus_connect_system`(130)/
`ubus_ctx`(139)/`ubus_sys_ctx`(154)｜`list_cb`(181)/`list_objects`(240)/`list_objects_on`(268)｜
`call_data_cb`(319)/`call_object`(328)｜`uci_ctx`(447)｜`probe_ping`(483)/`probe_notify`(502)/
`ubus_server_thread`(532)｜SSE：`sse_ctx`(627)/`sse_sys_ctx`(646)/`sse_watch_start`(699)/
`sse_watch_stop`(711)/`sse_drain_watch_cmds`(723)/`sse_event_enqueue`(783)/`copy_cstr`(799)/
`sse_watch_apply_start`(823)/`sse_watch_apply_stop`(879)/`sse_notify_cb`(908)/`start_ubus_server`(932)｜
`register_session_object`(972)/`session_handler`(1025)/`session_verify_password`(1088)/`shadow_hash`(1116)｜
`uci_config_sections`(1156)/`uci_package_sections`(1186)/`uci_list_configs`(1251)/
`register_uci_object`(1311)/`uci_handler`(1334)/`uci_savedir_of`(1394)/`uci_state_sections`(1423)/
`uci_delta_changes`(1443)/`uci_trigger_event`(1500)/`uci_commit`(1522)/`uci_revert`(1553)/
`uci_write_*`(1595-1717+)｜（file / luci-rpc 的注册与 handler 在更后面）。

**`call_object` 的关键语义（linux.odin:328-433，必须逐条复刻）**：
① `ubus_lookup_id` 先在自有总线找，失败且系统总线不同 → 回退系统总线找；都失败 → Object_Not_Found(-32000)。
② 请求体＝`blobmsg_add_json_from_string(params_json)` + 追加 `ubus_rpc_session=sid`。
③ `ubus_invoke_fd(ctx, id, method, msg, cb, nil, UBUS_TIMEOUT_MS, -1)`；
   `ret == UBUS_STATUS_INVALID_ARGUMENT` → Internal(-32603)，其余非 0（NOT_FOUND/TIMEOUT/METHOD_NOT_FOUND…）
   当远端返回码交 handler。
④ 回复：`blob_len(acc.head)==0` → reply=""（即 `result:null`）；否则把子项直接搬进新 buf **不再包 table**
   再 `blobmsg_format_json(buf.head, true)`（多包一层会出非法 `{{}}`）。
⑤ `list_objects`：同样自带→系统总线回退；`ubus_lookup` 用 verbose 回调建
   `{对象:{方法:{参数:类型}}}`，path 非空则不带外层对象名。
⑥ 并发：ubus ctx 一把锁（`g_lock`），uci ctx 另一把（`g_uci_lock`）——两个 C 库都非线程安全。

**Go 侧注意事项**：
- C 回调（`list_cb`/`call_data_cb`/`session_handler`/`sse_notify_cb`）要用 cgo 导出：
  `//export` 函数 + C 侧 shim，或 `C.function` 传 Go 闭包（cgo 回调进 C 再回 Go 受限，
  且 C 回调里不能持有 Go 指针）——优先「C shim + `//export`」。
- `blobmsg_format_json` 返回 malloc 内存 → 必须 `C.free`（Odin 版踩过 block-scoped defer 的坑，
  已知教训：Go 里用显式 `defer C.free(unsafe.Pointer(p))` 在**同一函数作用域**内）。
- `blob_buf` 全局复用（`g_tmp`/`g_acc`/`g_out`）——Go 侧同样用包级变量 + 锁。
- M5 新增目录 `internal/cbind/`（`//go:build linux && cgo`），逐字对齐
  `src/backend/bindings/{libc,blob,blobmsg,ubus,uci,uloop}.odin`（共约 922 行）。
- 需要的 C 函数：ubus：connect/free/lookup/lookup_id/invoke_fd/add_object/remove_object/
  send_reply/complete_deferred_request/register_subscriber/subscribe/unsubscribe/notify/add_uloop；
  blob：buf_init/put/len/head/iter/iter_ok/iter_next；blobmsg：add_* / add_json_from_string /
  format_json / add_blob；uci：alloc_context/free_context/load/lookup/foreach/…；libc：free/crypt/dlopen。
- uloop（`uloop.odin`）用于 `ubus_server_thread` 的事件循环——Go 侧可用 cgo 调 uloop_run，
  或改用 Go goroutine + `ubus_complete_deferred_request`（需评估）。

**M5 验收**：`CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="zig cc …"` 出 aarch64 动态 ELF；
`scp` 到 192.168.1.1；`/etc/init.d/rpcd stop` 后接管；跑 `tests/golden.sh` 对比零差异 +
`tests/device_smoke.sh`；RSS < 2MB。宿主门禁（gofmt/vet/test/smoke 284）必须保持全绿（回归）。

### 2026-10-06 — M5 实现设计（已实测定稿，按此执行，勿再侦察）

**cgo 实测结论（在 /tmp 独立模块验证通过，出 aarch64 动态 ELF）**：
- cgo **可以**直接 `#include <libubus.h>/<libubox/blobmsg.h>/<libubox/blobmsg_json.h>/<uci.h>`，
  static inline（`blob_data/blob_id/blob_len/blob_next/blobmsg_name/type/data/get_string/
  get_u32`、`blobmsg_format_json`、`ubus_add_uloop`）**可直接 `C.xxx()` 调用**，`ctx->sock.fd`
  等字段可直接访问。**不必手抄结构体布局**（Odin 手抄是因为 Odin 绑 C 头不便）。
- `#cgo CFLAGS: -I$SYSROOT/usr/include`（绝对路径 OK）。
- **`--sysroot=` 不能写进 `#cgo LDFLAGS`**（cgo 报 `invalid flag`）→ 必须走环境变量
  `CGO_CFLAGS`/`CGO_LDFLAGS`。`#cgo LDFLAGS: -L/usr/lib -luci -lubus -lblobmsg_json -lubox`
  （`-L` 必须 **sysroot 相对**，绝对路径会被拼成 `$sysroot/$abs`）。
- 编译命令：`CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="zig cc -target aarch64-linux-musl"
  CGO_CFLAGS="--sysroot=$SYSROOT" CGO_LDFLAGS="--sysroot=$SYSROOT" go build -o build/gomolly-arm64 ./cmd/gomolly`。
- `CGO_ENABLED=0 GOOS=linux go build ./...` 仍要能过 → linux 侧非 cgo 文件不得依赖 cbind；
  cbind 需要 `//go:build linux && !cgo` 的 fallback（同签名 no-op/错误），否则 cgo-less 类型检查挂。

**架构决策（本轮的 provider 形态，记录偏离）**：
1. `CallObject` 对 **molly 自有对象**（session/uci/file/luci-rpc/molly.probe）走**进程内**调用
   （与 darwin.go 完全同构：注入 sid → `SessionCall`/`callUCI`/`callFile`/`callLuciRPC`），
   **不做** ubus 往返。可观测结果与 Odin 的 ubus 往返一致（同一份 handler 逻辑），
   但避免「同 ctx 跨线程 invoke」与 uloop poll 冲突。外部对象（netifd/…）才 `ubus_invoke_fd`。
2. 另起 **ubus 服务 goroutine**（`runtime.LockOSThread`）注册五个对象，供 `--luci-cgi` 下
   ucode 经 ubus 调用（等价 Odin 的 `ubus_server_thread`）。uloop 用
   `uloop_run_timeout(100)` 循环 + 命令队列轮询。
3. handler 约定（读自 Odin session/file/uci/luci handler）：C 回调 → Go export
   `mollyGoHandle(objName, method, msgJSON) (status int, replyJSON string)`；
   `status != 0` 时**不** `ubus_send_reply`（由 libubus 回错误码）；`status == 0` 时把
   replyJSON（空则 `{}`）用 `blobmsg_add_json_from_string` 建 blob 再 `ubus_send_reply`。
4. 所有 C 回调桥接写在 `cbind/shim.c`（C 定义 handler，回调 Go 的 `//export`），
   Go 侧只调普通 C 函数，**不在 Go 里做函数指针转换**。`//export` 所在 Go 文件 preamble
   只能 `#include`，不能有 C 定义。
5. `blobmsg_format_json*` 返回 malloc → 必须 `C.free`，在同一函数作用域（勿踩 Odin 的
   block-scoped defer 悬垂坑）。blob_buf / ubus ctx / uci ctx 复用要在 Go 侧加锁
   （C 库非线程安全；HTTP 线程一把 g_lock，服务线程天然串行）。

**文件清单（M5 新增/改动，全部在 `gomolly/` 内）**：
- `internal/cbind/cbind.go`（linux&&cgo，Go 封装）/ `shim.c` / `shim.h` / `export.go` / `fallback.go`（linux&&!cgo）
- `internal/backend/linux.go`：list/call（外部对象走 ubus）+ 服务 goroutine 启动 + 五对象注册 handler
- `internal/backend/session_linux.go`：crypt + /etc/shadow（拆出，避免 linux.go 过大）
- `internal/backend/uci_linux.go`：20 个 uciProvider* 钩子接 libuci
- `internal/backend/luci_linux.go`：board.json / getNetworkDevices / getWirelessDevices / getHostHints
- `cmd/gomolly/main.go`：linux 下启动 ubus 服务（darwin 空操作）——用 `backend.StartServer()` 钩子

**验证（本轮每步都跑）**：
```bash
cd gomolly && gofmt -l . && go vet ./... && go test -count=1 ./... && go build -o build/gomolly-host ./cmd/gomolly && ./tests/smoke.sh   # 须 284/0
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...   # linux 类型检查
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="zig cc -target aarch64-linux-musl" CGO_CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include" CGO_LDFLAGS="--sysroot=$SYSROOT" go build -o build/gomolly-arm64 ./cmd/gomolly   # 真交叉编译
```
**更正（实测）**：`CGO_CFLAGS` 必须带 `-I$SYSROOT/usr/include`，只写 `--sysroot` 会报
`fatal error: 'libubus.h' file not found`（zig cc 的 sysroot 不自动加 usr/include 到搜索路径）。

### 2026-10-06 — M5 进行中（m5-5 / m5-6 / m5-7 完成；剩设备验收）

**m5-5 完成并验证**（uci 写路径 + delta + commit/revert/apply/reload）：
- C 侧：`shim.c` 追加 uci 写事务全实现（savedir→load→改→save→unload→free）、
  `molly_uci_delta`、`molly_uci_commit/revert/apply_config/reload_config`（fork+sleep2+execv
  `/sbin/reload_config`）、`molly_uci_trigger_event`（经服务线程连接调 `service.event`）；
  `molly_uci_sections`/`molly_uci_list_configs` 返回码改为 **ubus 风格**（uci 的
  `UCI_ERR_MEM=1`/`UCI_ERR_NOTFOUND=3` 与 ubus 状态码数值冲突）。
- Go 侧：`cbind.go`/`fallback.go` 同签名包装；新建 `backend/uci_write_plan.go`（平台无关
  计划层 `uciPlanMergeSet`/`uciPlanAddValue`）；**整文件重写 `backend/uci_linux.go`**
  （`uciMu` 串行化、20 个 `uciProvider*` 钩子接 libuci、`uciDecodeSections`/`uciDecodeDelta`）。
- **门禁全绿**：`gofmt -l` 空（修了 `uci_linux.go`/`uci_write_plan.go`/`fallback.go` 三处格式）；
  `go vet ./...` 0；`go test -count=1 ./...` 4 包全 ok；`go build -o build/gomolly-host` ok；
  `./tests/smoke.sh` **通过 284 失败 0**；`CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` ok；
  真交叉编译出 **aarch64 musl 动态 ELF**（`build/gomolly-arm64` 17,495,392 B）。
  - 修了一个编译错：`uci_linux.go` 里 `o.IsList()` → `o.List == 0`。
- **风险（记下）**：Go 静态运行时 + cgo 使目标 ELF 约 17.5 MB（Odin 版约 0.5 MB）；
  计划里的「RSS < 2 MB」验收**对 Go 二进制不成立**，M5 验收时改为记录实测 RSS 并与
  Odin 版对比说明偏离。

**m5-6 完成并验证**（luci-rpc 三个设备绑定钩子的真实现）：
- C 侧 `shim.c` 追加约 470 行（不碰 ubus；布局与协议解析全在 C）：
  - `molly_getifaddrs_json`：遍历 `getifaddrs`，JSON 数组每项
    `{name,family(2|10|17),addr,netmask,dstaddr,flags,ifindex,hatype,halen,mac}`；
    AF_PACKET 用裸字节偏移解析 `sockaddr_ll`（不引内核头）。
  - `molly_get_neighbors_json`：裸 netlink（`AF_NETLINK/SOCK_RAW/NETLINK_ROUTE`）发
    RTM_GETNEIGH dump、解析 RTM_NEWNEIGH，过滤 family 2/10 且 `state & ~NUD_NOARP != 0`，
    取 NDA_DST/NDA_LLADDR → `[{ip,mac}]`。
  - `molly_iwinfo_json`：dlopen `/usr/lib/libiwinfo.so*`，按 iwinfo master 布局取 35 个
    函数指针 + 六张名字表；两层失效保护（`ops.name` ∈ {wext,nl80211,madwifi,wl,unknown}；
    hwmode/htmode/mode 位范围守卫），任一不符 → 非 0（调用方一个键都不加）。
- `shim.h` 加三个函数声明；`cbind.go` 加 `IfAddr`+`GetIfaddrs`、`Neighbor`+`GetNeighbors`、
  `IwinfoJSON`；`fallback.go`（linux&&!cgo）加同签名空实现。
- **整文件重写 `backend/luci_linux.go`**（约 560 行）：
  - `luciRPCNetworkDevices`：`/sys/class/net` 遍历 + `luciNetdevJSON`
    （bridge/ports/id/stp、master、wireless、operstate→up、mtu/qlen、uevent DEVTYPE→devtype、
    ipaddrs/ip6addrs + flags OR、PACKET→mac/type/ifindex/parent、stats 10 项、flags 7 项、
    link 5 项）。目录遍历用 `Open+Readdirnames`（保序，不用会排序的 `os.ReadDir`）。
  - `luciRPCWirelessDevices`：同步 `luciInvokeExternal("network.wireless","status")`；
    lookup 失败→4、invoke 失败/空→9；重塑时丢所有 iwinfo 键，接口级补 `phy_only=false`、
    radio 级补 `phy_only=true`（无接口时用 radio 名）。
  - `luciRPCHostHints`：五源按 prio 合并（nl 10 / ethers 50 / leasefile 100 / ifaddrs 200 /
    uci 静态租约 250）+ rrdns 补名；同族同址去重取高 prio，收尾插入排序
    （prio DESC，同 prio 地址字节 ASC）。uci 静态租约的 `ip` 照抄上游**不生效**。
  - 新增 `luciInvokeExternal(obj,method,params)`：`ubusMu` + `sysConn()`（私有总线下系统
    对象在系统总线），返回 `(reply, found, ret)` 以区分 lookup 失败与 invoke 失败。
  - JSON 用 `json.Decoder.UseNumber()` 解码，保留整数原样。
- **门禁全绿**：`gofmt -l` 空；`go vet ./...` 0；`go test -count=1 ./...` 4 包全 ok；
  `go build -o build/gomolly-host` ok；`./tests/smoke.sh` **通过 284 失败 0**；
  `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` ok；
  真交叉编译出 aarch64 musl 动态 ELF（`build/gomolly-arm64` 17,625,480 B）。
- **偏离（记文档）**：外部 invoke 超时统一用包默认 30s（Odin：wireless 30s / rrdns 1s）。
  rrdns 请求自带 `timeout=250` 才是真正的界，差别只在 rrdns 完全无响应时可见，不影响输出。

### 2026-10-07 — M5 设备验收（真机 192.168.1.1，完成）

- **阻塞修复（定位过程与源码证据）**：`molly_uci_list_configs` 的 SIGSEGV 根因不是
  「`blobmsg_open_array` 的 cookie 在 `blob_buf` realloc 后失效」（读 `libubox/blob.c` 否定：
  cookie 是 offset，realloc 不影响），而是对 `uci_list_config_files`（`uci/file.c:887-905`）
  **单块 calloc 内部指针**逐元素 `free`——非法释放破坏 musl 堆，后续调用 SIGSEGV。
  上游 uci CLI（`cli.c:426-437`）只 `free(configs)`，`uci.h:249` 也只说释放 list 背后的内存。
  改为只 `free(list)` 后：`uci configs` 回 18 个 config、`uci changes` 回 `{}`、进程存活。
- **本轮修的真缺口**：`fileStatJSON` 只回 type/size/mode/mtime，**漏了 atime/ctime/inode**，
  而 Odin `file_stat_dump_json`（`file_object.odin:355-358`）是回的（旧注释「照抄 Odin 取舍」有误）。
  新增平台钩子 `fileStatMeta`（`darwin.go`/`linux.go` 同名同签名，取 `syscall.Stat_t` 的
  Atim/Atimespec、Ctim/Ctimespec、Ino，inode 截到 u32），`fileStatJSON` 补这三项；
  `file.list` 的 entry 与 target 共用它，一并补齐。
- **门禁全绿（本轮改动后重跑）**：`gofmt -l` 空；`go vet ./...` 0；`go test -count=1 ./...`
  4 包全 ok；`go build -o build/gomolly-host` ok；`./tests/smoke.sh` **通过 284 失败 0**；
  `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` ok；真交叉编译
  `build/gomolly-arm64` = **17,629,248 B**。
- **部署**：`scp -O build/gomolly-arm64 root@192.168.1.1:/tmp/gomolly`
  （覆盖运行中的文件会报 `Text file busy`，**必须先** `kill $(pidof gomolly)`），
  再 `setsid /tmp/gomolly --listen 0.0.0.0:8080 --ubus-socket /var/run/ubus/molly.sock`。
  真机 rpcd 未停——molly 走私有总线 `/var/run/ubus/molly.sock`，与系统总线互不干扰。
- **验收准则修正（重要）**：`tests/golden.sh compare` 把设备侧 **CLI 裸输出**（`ubus -v call`，
  无会话、无 JSON-RPC 信封）与 molly 侧 **HTTP 信封**（带 root SID）逐对 diff，两侧抓取
  方式不对称，其「零差异」不可达。正确做法是 **HTTP 对 HTTP**：设备
  `POST http://192.168.1.1/ubus/call/<obj>`（Bearer 设备 root SID）vs molly
  `POST http://192.168.1.1:8080/ubus/call/<obj>`（Bearer molly root SID），
  归一化（`json.dumps(..., sort_keys=True)`）后逐对 diff。
- **实测（10 探针）**：**7 对逐字节一致**——`session.list`、`uci.configs`、`uci.get`、
  `uci.changes`、`file.read`、`file.md5`、`luci-rpc.getBoardJSON`。**3 处差异全属已记录偏离**：
  1. `file.stat` / `file.list`：仅差 `uid`/`gid`/`user`/`group`（§9.3 第 2 条：Odin 的
     `File_Info` 不含 uid/gid，`user`/`group` 需 getpwuid/getgrgid；Go 侧保持与 Odin 一致，
     未补）。atime/ctime/inode 已一致。
  2. `session.get {}`：molly 回自身会话，真机回 `Access denied(-32002)`。真机的拒绝来自
     **uhttpd 的 HTTP 层 ACL**（root 的 acl.d 里 `ubus.session` 只有 access/login），
     而 rpcd 直连是自服务的；Odin 在 HTTP 层加了「session 自服务」例外
     （`session_self_service` / Go 侧 `SessionSelfService`），让 LuCI dispatcher 登录后能读会话。
- **实测 RSS**：gomolly **VmRSS 10,056 kB**（VmSize ~1.3 GB，Go runtime 的地址空间保留）。
  同机对照：rpcd 2,128 kB、uhttpd 932 kB、ubusd 940 kB。原「RSS < 2 MB」验收对 Go 二进制
  不成立，以实测值 + 对照值记录偏离。
- **部署形态**：本次未加 `--luci-cgi`，`/cgi-bin/luci/` 走内置 dispatcher，无会话时回
  403 + `X-LuCI-Login-Required: yes` + 「Login required」提示页（ADR 0003 既定行为，
  **不渲染登录表单**）；要看 LuCI 界面需以 `--luci-cgi` 启动。
- **设备现状**：gomolly 仍在 8080 运行（pid 19105）。清理：
  `ssh root@192.168.1.1 'kill $(pidof gomolly); rm -f /tmp/gomolly /tmp/gomolly.log'`。

### 2026-10-07 — M5 设备验收（第二轮：跑 tests/device_smoke.sh，完成）

本轮把项目自带验收脚本 `tests/device_smoke.sh` 真跑了一遍，并做同口径探针 A/B。

- **本轮修的两个真缺口（均已上机复验）**：
  1. **响应头名字节透传**：`internal/handlers/response.go` 的 `RespondFull` 原用
     `h.Add(name,...)`，Go 按 MIME 规范把 `X-LuCI-Login-Required` 规范化成
     `X-Luci-Login-Required`；Odin 是**原样透传**（`src/handlers/cgi_luci.odin:82`）。
     改为**直接写 map**（`h[e.Name]=append(...)`），绕过规范化。`tests/smoke.sh` 新增
     大小写敏感 helper `header_line` + 断言锁字节契约（host 门禁 284→**285**）。
     上机实证：`curl -D- .../cgi-bin/luci/admin/status/overview | awk '$1=="X-LuCI-Login-Required"'`
     → **命中** `X-LuCI-Login-Required: yes`（修复前为空）。
  2. **ACL 数组顺序确定性**：`internal/backend/session.go` 的 `sessionLoadACLFile` 用
     `for groupName := range groups`（Go map 随机序）把同一 object 的函数名 append 成数组
     → login/get 回包的 `acls` 数组顺序每次不同（修复前连续 3 次 sha1 全不同：
     `99396f69…`/`cd30ad9f…`/`a714e662…`）。改为先 `sort.Strings(groupNames)` 再遍历。
     上机复验：连续 3 次 login 的 `acls` 段 sha1 **全等** `7a0f5dc5baff5ac738efb13b25a7757cfd56ce5f`。
- **门禁全绿（本轮改动后重跑）**：`gofmt -l` 空；`go vet ./...` 0；`go test -count=1 ./...`
  4 包全 ok；`go build -o build/gomolly-host` ok；`./tests/smoke.sh` **通过 285 失败 0**；
  `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` ok；真交叉编译
  `build/gomolly-arm64` = **17,630,024 B**（md5 `2191829595cb9fbb839e83c0cc8e0297`）。
- **部署（沿用私有总线形态）**：`kill $(pidof molly)` → `scp -O build/gomolly-arm64
  root@192.168.1.1:/tmp/molly` → `setsid /tmp/molly --listen 0.0.0.0:8080
  --ubus-socket /var/run/ubus/molly.sock`。rpcd 未停，两总线互不干扰。
- **`tests/device_smoke.sh` 结果（宿主经转垫片访问设备）**：**通过 15，失败 7，跳过 2**。
  - §0 前置 ok；**§2 HTTP 面 9/9 全绿**（含头字节透传）；**§3 crypt 登录 3/3 全绿**；
    **§5 SSE 2/2 全绿**。
  - **§1 六项 FAIL = 脚本-环境不匹配，非 molly 缺陷**：本机 ubus（ImmortalWrt 25.12）输出是
    现代格式 `'molly.probe' @c89edfd6`（对象名**带单引号** + `@id`），`ubus -v call` 回 JSON 是
    **tab 缩进**；脚本按旧格式写 `grep -c '^molly\.probe'` / `grep -c "^session\$"` 与
    `tr -d ' \n'`。证据：系统总线上 rpcd 对象同样是 `'bridger' @a7c1d83d`，非 molly 独有。
  - **§6 golden compare DIFF 10/10 = 脚本抓取口径不对称**（两层）：(a) molly 侧未带会话，
    rpcd 侧 CLI 不经 ACL → molly 6 项回 `-32002`；(b) 设备侧是 `ubus` **裸回复**，molly 侧是
    **JSON-RPC 信封**（Odin `ubus_http.odin:464` 确认信封正确）→ 形状本就不同。
    **正确准则见上一轮记录：HTTP 对 HTTP（各带 root SID）**。
  - **§4 uci 写路径 skip**：未给 `--uci-write`（其前置 `session grant` 在设备 acl.d 下被
    `-32002` 拒，写 `set` 被 `6` 拒——与真机 rpcd 行为逐项一致，属脚本设计问题）。
  - **§7 `--rss` 未跑**：脚本 line 198 `$rss（` 全角括号 + `set -uo pipefail` → `rss: unbound
    variable` 崩溃（AGENTS.md/计划里记过的同一个坑），脚本自身缺陷；RSS 另行单测。
- **同口径总线 A/B（10 只读探针，均无会话）**：molly 私有总线
  `ubus -s /var/run/ubus/molly.sock -v call …` vs rpcd 系统总线 `ubus -v call …`，
  归一化后 → **7 对一致**（`session.get`、`uci.configs`、`uci.get`、`uci.changes`、`file.read`、
  `file.md5`、`luci-rpc.getBoardJSON`）；**3 处差异**：
  1. `file.stat` / `file.list`：仅差 `uid`/`gid`/`user`/`group`（§9.3 第 2 条已记录偏离）。
  2. `session.list`（无 sid 参数）：rpcd 回哨兵会话 dump（`ubus_rpc_session`+`timeout`+`acls`+
     `data`），molly 回 `{}`（molly 侧 `list` 无 sid 时构造的是**顶层数组**，blobmsg 回复不可表示；
     HTTP 侧同参数被 ACL 拒 `-32002`）。属已知 ACL/形状边界，非新缺口。
- **HTTP 头对照（原厂 uhttpd vs molly）**：差异全为替换层固有——molly **故意**不发
  `Date`/`Server`、用 `Content-Length` 而非 `Transfer-Encoding: chunked`、状态行文案不同。
  另：uhttpd 发小写 `x-luci-login-required`，molly 发 Odin 契约的 `X-LuCI-Login-Required`
  （device_smoke §2 断言按后者）。
- **设备清理（本轮结束，已复核）**：`kill 21947`（molly）→ 停两个私有总线 ubusd
  （`odin.sock` pid 21566、`molly.sock` pid 9330）→ 删 `/var/run/ubus/{odin,molly}.sock`
  与 `/tmp/{molly,molly.log,odin-molly.log,odin-ubusd.log}`。复核：系统 ubusd(981)、
  rpcd(16099)、uhttpd(2386) 均在；`/etc/config/mollytest` 不存在；系统总线正常应答。

### 2026-10-07 — golden 判据口径修正（§6 从「假失败」变为可用判据）

M5 记录里的「§6 golden compare DIFF 10/10」按当时的结论收在「脚本抓取口径不对称」。
本轮把口径落进了脚本本身（`tests/golden.sh`），§6 现在给出的是**有意义的判定**。

**改动（全在 `tests/golden.sh`）**：
1. **设备侧改走 HTTP**（`POST http://<host>/ubus/call/<obj>`，`Authorization: Bearer <设备
   root sid>`），与 molly 侧同层。**这一条是必须的**：`ubus` CLI 不经 uhttpd 的 ACL，
   同一份数据两个口径不同——实测 `uci configs` 的 CLI 回 18 个 config / HTTP 回 `-32002`；
   `file read /etc/hostname` 的 CLI 空 / HTTP `-6`。只做「剥信封 + 带 SID」会继续产生假差异。
2. **两侧各带 root SID**：设备 `MOLLY_DEVICE_PASS`，molly `MOLLY_SID` 或 `MOLLY_PASS`
   （脚本自己登录）。任一侧缺失 → `compare` **exit 2**，不再输出没有意义的「零差异」。
3. **compare 剥信封**：带 `jsonrpc` 的对象取 `result`（只有 `error` 时归一成
   `{"__rpc-error__":{code,message}}`），会话 id 掩成 `<sid>`，再 `sort_keys` 后逐对 diff。

**实测（10 只读探针，设备 rpcd 对 molly :8080）**：`session.list`、`uci.configs`、
`uci.get` 判 **ok**（`uci.configs` 两侧都 `-32002`，正是第 1 条修掉的那个假差异）；
`file.stat`/`file.list` 的 `uid`/`gid`/`user`/`group`、`session.get {}` 的 session
自服务例外属 §9.3 已记录偏离。

**新发现（真缺陷，非脚本问题）**：`uci changes`（**带 molly 自己的会话**）令 molly
**SIGSEGV**——连续 3 轮探针序列 **3/3** 都崩在这一条（`http=000`，进程消失）。现象不总是
「调用中死」：golden 抓取那轮它先回了正常包（35 B）再死，后续探针全 connection refused。
崩点/时机随分配模式漂移 → 与 M5 那个「非法释放破坏 musl 堆」同类。
复现要点：**sid 必须是 molly 自己签发的**（用 rpcd 的 sid，molly 的 handler 会被 ACL
挡掉，复现不到）。这与用户侧长期症状（「很容易退出」/页面报 `No related RPC reply`）同根：
molly 在批处理中途死掉，前端那批 RPC 拿不到回复。

### 2026-10-07 — 承接原版 LuCI（ADR 0003 的 T1）真机验收完成

用户选定的方向：把「molly 承接原版 LuCI」在 **Go 版**上做到可用，而不是继续在 Odin 版收尾。

**结论：Go 版不需要改代码即通过**。`--luci-cgi` / `--ubus-socket` / `MOLLY_UBUS_SOCKET`
注入 / CGI 环境与响应头透传在 M1–M5 期间已建齐（`internal/handlers/cgi.go` 与
`src/handlers/cgi_exec.odin` 逐条对齐：SCRIPT_NAME / PATH_INFO / REQUEST_METHOD /
CONTENT_LENGTH / HTTP_* / DOCUMENT_ROOT），**缺的只是真机验收**——M5 那轮明确记着
「本次未加 `--luci-cgi`，要看 LuCI 界面需以 `--luci-cgi` 启动」。

**部署形态（真机 192.168.1.1）**：

```sh
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="zig cc -target aarch64-linux-musl" \
  CGO_CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include" CGO_LDFLAGS="--sysroot=$SYSROOT" \
  go build -o build/gomolly-arm64 ./cmd/gomolly          # 17,630,024 B
scp build/gomolly-arm64 root@192.168.1.1:/tmp/molly
# 设备：停 Odin molly → 起私有总线 ubusd → 起 gomolly
/etc/init.d/molly stop
setsid /sbin/ubusd -s /var/run/ubus/molly.sock &
setsid /tmp/molly --listen 0.0.0.0:8080 --docroot /www-molly \
  --menu-dir /usr/share/luci-molly/menu.d \
  --luci-cgi "/usr/bin/ucode /www-molly/cgi-bin/luci" \
  --ubus-socket /var/run/ubus/molly.sock &
```

**`--luci-cgi` 必须指向 CGI 兜底脚本**（`/www-molly/cgi-bin/luci`），**不能**填
`/usr/share/ucode/luci/uhttpd.uc`——后者是 uhttpd 的**进程内模板**（首行 `{%`，靠 uhttpd
注入的 `uhttpd.recv/send` 收发），单独 execve 必然报 `Syntax error: Expecting expression`。

**验收（宿主门禁 gofmt/vet/test/smoke **285 全绿**、`CGO_ENABLED=0` 类型检查 ok）**：
- 私有总线对象齐全：`file luci-rpc molly.probe session uci`。
- `GET /cgi-bin/luci/` → 403 + `x-luci-login-required: yes` + 登录页；表单登录 → 302 +
  `set-cookie: sysauth_molly=…`（证明 `MOLLY_UBUS_SOCKET` 注入生效、dispatcher 走到补丁分支）。
- 9 个页面（概览/网络/无线/系统/路由/日志/管理/DHCP）全 200；5 个静态资源全 200。
- 6 条首屏 RPC（`session access`/`get`、`luci getFeatures`、`luci-rpc getBoardJSON`/
  `getNetworkDevices`、`system board`）全 `ret=0`。
- 12 条浏览器形态批量 → 合法 JSON **12/12**（原 `No related RPC reply` 场景不再出现）。
- **真实浏览器（Chrome 无头 + 同源临时表单登录）**：概览 DOM 30,538 / 系统 47,319 /
  系统日志 5,805 / 接口 36,306 字节，标题正确，**四处均无 `No related RPC reply` /
  `Session expired`**。
- 并发：40/80/120 页面（未带 cookie → 正确 403）+ 120 静态资源 → 全 200、**无 503**；
  进程存活，VmRSS 17,304 kB（M5 记录 10,056 kB，随负载增长；RSS 只记录、不作判据）。

**与 Odin 版的同口径对照（选 Go 版的直接收益）**：
- Odin 版：`uci changes`/`uci get` 令进程 **SIGSEGV**（崩点随运行漂移 → 堆损坏），浏览器
  打开「系统」「系统日志」两页即报 `No related RPC reply`；Go 版同一批调用全部 `ret=0`
  且进程存活（M5 已修 `molly_uci_list_configs` 的非法释放）。
- Odin 版另有 `MAX_CONNECTIONS=32` 的连接悬崖（已提到 100）；Go 版无此上限，120 并发无 503。

**设备现状**：:8080 由 `/tmp/molly`（gomolly）承接原版 LuCI，私有总线 ubusd 独立于 procd；
Odin molly 的 `/etc/init.d/molly` 已停。回到 Odin 版：`kill $(pidof molly)` →
`/etc/init.d/molly start`。

**同日追加：把验收固化成脚本 + golden 加 HTTP 面**

1. 新增 **`gomolly/tests/device_luci.sh`**（只走 HTTP，**与实现无关**，Odin 版同样可用）：
   固化「T1 桥接承接原版 LuCI」的验收——未登录 403 + `x-luci-login-required` → 表单登录
   302 + `Set-Cookie` → 9 页面（200 / 不再要求登录 / 非空）→ 5 静态资源 → 6 条首屏 RPC →
   12 条浏览器形态批量（条目数对齐 + 每条都有 result/error）→ 40 并发（断言不出现 503）。
   真机实跑 **通过 47，失败 0**；失败路径也验过：错密码 → 登录断言全 FAIL 且退出码 1，
   目标不可达 → 状态码空 + `000`（`MOLLY_DEVICE_PASS` 缺失时脚本直接拒跑）。
2. **`tests/golden.sh` 的 compare 新增 HTTP 面**（原厂 uhttpd(:80) vs molly(:8080)）：
   只比状态码 + 契约头——新 `norm_http` 剔除 `Date`/`Server`/`Content-Length`/连接类等
   实现固有的头，**头名一律小写**后比（实测 uhttpd 自己都不统一：页面响应发
   `content-type:`、静态发 `Content-Type:`——原先按字节比会出假阳性），cookie 名与 sid 掩掉。
   ADR 0003 那条「拿原厂 uhttpd 的响应做 golden 对比」至此落地。
3. **HTTP 面查出两条真实偏离（两版实现行为一致，记为 R7，未修）**：静态 `.html` 的
   `text/html; charset=utf-8`（uhttpd 只发 `text/html`）、404 的 `text/plain; charset=utf-8`
   （uhttpd 发 `text/html` + HTML 正文）。`.html` 那条被 `tests/http_smoke.sh:126` 与
   `src/http/mime_test.odin:15-16` 的契约断言锁着；对齐要同时改两版实现 + 断言。
   已记进 `docs/testing.md` §7.1 第 4 条（那一节标题也从「三处脚本-环境不匹配」改为
   「已知脚本-环境不匹配与已记录偏离」，并把 `device_luci.sh` 写进真机验收那一行的判据）。
4. 本轮 golden 实测（gomolly，:8080）：`/ubus` 10 对 → **7 ok**（含 `uci.changes`——Odin 版
   就是崩在这条），3 处为已记录偏离（`file.stat`/`file.list` 的 uid/gid/user/group、
   `session.get` 的自服务例外）；HTTP 7 对 → **5 ok**，2 处即上条 R7。

### 2026-10-07 — 静态面 R7 对齐 + Lua 依赖结论 + 前端资源 embed

**一、R7 静态/MIME 对齐（golden 的 HTTP 面因此归零）**

真机实测拿到 uhttpd 的规则（探针文件同时写进 `/www` 与 `/www-molly`，36 个扩展名，量完即删）：
- **从不带 charset**；`.js` = `text/javascript`（**不是** `application/javascript`）；
- **表外一律 `application/octet-stream`**——实测 ico/woff/woff2/ttf/eot/otf/mjs/map/
  webmanifest/md/csv/webm/webp/avif 全是它；
- **404 = `text/html`** + 正文 `<h1>Not Found</h1>The requested URL <路径> was not found on
  this server.`（uhttpd 原样回显路径；molly 做 HTML 转义，属故意偏离，正文不进 golden）。

两版实现同时改（Odin `src/http/mime.odin` + `src/handlers/static.odin`；Go
`internal/httpx/mime.go` + `internal/handlers/response.go`），契约断言同步更新并各加一条
404 Content-Type 断言：Odin `http_smoke` 265→**266**、Go `smoke` 285→**286**；两版
unit/test 全绿、`build.sh --target` 511,880 B 能交叉编译。
**结果：golden 的 HTTP 面 7 对全 ok**，只剩 `/ubus` 面 §9.3 的 3 处已记录偏离。

**二、Lua 依赖结论：运行时不依赖 Lua**

- 设备上**没有 Lua 运行时**：`/usr/bin/lua`、`lua5.1` 缺失，`opkg list-installed | grep ^lua`
  为空；`.lua` 与 `.htm` 文件数都是 **0**。
- menu.d 里 `type: template` 只有 **1 条**（概览页 `admin/status/overview` →
  `admin_status/index`）。ucode 的 `render_any` 是**先 `.ut`、再回落 Lua**，而
  `admin_status/index.ut` 存在（真机 `.ut` 共 11 个）→ 走 ucode；`.htm` 为 0 ⇒
  **`render_lua` 是死路径**。
- 唯一残留的「lua」是**翻译数据**：`/usr/lib/lua/luci/i18n/*.lmo`（5 个），由 **ucode 直接读**
  ——`dispatcher.uc:110` 就是 `load_catalog(lang, '/usr/lib/lua/luci/i18n')`。把
  `base.zh-cn.lmo` 临时改名后翻译端点从 **163,370 → 26,953 字节**（已还原），确认它是
  必需数据、不是运行时依赖。

**三、前端资源 embed 进 Go 二进制（可选 + 兜底）**

新增 `webassets/`（项目根）：默认构建不带资源；`-tags embed_assets` 时把
`webassets/luci-static/` 编进二进制，**docroot 找不到时兜底**（设备上那份与 ucode
同版本，永远优先——避免「二进制里的 JS 与设备上的 ucode 视图漂移」）。资源用
`gomolly/tools/embed-assets.sh <host>` 从设备抄，目录已 gitignore。

- **体积**：宿主 9,863,218 → 11,220,562 B（**+1.36 MB**）；aarch64 17,703,680 → 19,074,744 B。
- **A/B（同一份缺 `resources/` 的 fixtures docroot）**：默认构建
  `/luci-static/resources/luci.js` → **404**；带 tag → **200（29,565 字节，真 luci.js）**；
  docroot 里有的 `test.css` 两边都 200（docroot 优先 ✓）。
- **端到端（真机，`--docroot /tmp/empty-docroot` 空目录）**：`device_luci.sh` **通过 47 失败 0**；
  真实浏览器 概览 30,007 / 系统 47,326 字节 DOM、标题正确、无报错 —— **只丢一个二进制就能跑界面**
  （设备上仍需 ucode + menu.d + acl.d：159.5K + 36K + 21K，那是渲染侧，必须留在设备）。
- **踩到的坑（已写进脚本注释）**：设备上 `/www/luci-static/{bootstrap-light,bootstrap-dark}` 是
  **符号链接**，而 **`go:embed` 不跟随符号链接** → 第一版只 embed 到 134 个文件，表现为
  「`resources/luci.js` 能取到、主题 `cascade.css` 404」的半残状态。`tar -chf -` 解引用后
  142 个文件、0 链接；脚本现在抄完会**断言无符号链接**，有就报错退出。

## 2026-10-09 会话：给简洁版 /lite 加设备黑盒测试（tests/device_simple.sh）

- 诉求：验证 molly 单独提供「简洁版 + 专家版」时 /lite 各操作是否正常。设备现况：uhttpd(:80)+rpcd+ucode 与 molly(:8080) 并存；molly 的 /admin 走自 fork ucode（不依赖 uhttpd），故「停 :80 让 molly 单独扛两个界面」可行，但**专家版仍需 rpcd+ucode**（内置 Go dispatcher 的 view 尚未落地，会 501）。用户选择：molly 保持 :8080、uhttpd 停用并禁自启（本轮只确认结论，未执行部署改动）。
- 新增 `tests/device_simple.sh`（黑盒、只走 HTTP、浏览器形态旧式 `params:[SID,obj,m,p]`）：
  - A 路由与 SPA 外壳：`/`→302 /lite/；/lite 前缀任意子路径 200（深链）；`__CFG__` 已替换、注入 sid/menu/expert；POST /lite/→405。
  - B /auth：GET→404（只接 POST）；错口令 302+auth_error 且不发会话；正确口令 302+sysauth_molly=<32hex>。
  - C 各页读操作全 ret=0 且形状对得上：system.info/board、uci.get network/dhcp/wireless、luci-rpc.getWirelessDevices/getDHCPLeases、log.read、file.read /proc/mounts、file.exec /bin/df、file.list /etc/rc.d & /etc/config、file.exec /bin/ping(环回)、file.read /etc/config/network。
  - D ACL 兜底：匿名 uci.get 被拒；root 读 /etc/shadow 被拒；root 写 /tmp 被拒（acl.d/molly.json 的 write 只放行 /etc/config/*、/etc/init.d/*、/sbin/reload_config）。
  - E 并发：GET /lite/ 与并发 uci.get，不得 503。
  - F 登出：302 清 cookie；旧 SID 再读被拒（会话 destroy 落 rpcd）。
  真机：**39/0**，连跑两遍稳定。
- **活设备刻意不做**（破坏性；写逻辑由宿主 smoke.sh 覆盖）：真 uci set/commit/apply、network.reload、服务 start/stop/restart、system.reboot、/auth/password。
- Makefile：加 `device-simple` / `device-luci` 目标（缺 MOLLY_DEVICE_PASS 直接报错），经 make 这条路同样 39/0。
- 踩坑（已修）：初版用 `printf 大字符串 | grep -q` 判 SPA 外壳内容，在 `set -o pipefail` 下 `grep -q` 命中即关管道 → printf 收 SIGPIPE 退 141 → 整条 `&&` 判失败，表现为**偶发**误报（菜单那条抢跑失败、小响应头那几条没触发）。改纯 bash `[[ body == *needle* ]]` 后消除。
- **已执行部署改动**（用户选项：molly 保持 :8080 + uhttpd 停用并禁自启）：`/etc/init.d/uhttpd stop && disable` 已跑，:80 释放、/etc/rc.d 无 uhttpd 启动链接；molly(:8080)/rpcd/ucode 均在。uhttpd 关掉后重跑两套黑盒：**/lite 39/0、/admin 47/0** → molly 单独同时扛简洁版+专家版（专家版仍走 molly 自 fork ucode→rpcd，不需 uhttpd）。回滚：`/etc/init.d/uhttpd enable && start`。注：:80 现为空，访问入口是 http://192.168.1.1:8080。

## 2026-10-09 会话：专家版 URL 前缀 /admin/admin → /admin（消双写）

- **症状**：专家版 cgi 模式（`--luci-prefix /admin --luci-strip admin --luci-cgi …`）下，页面里每条链接、地址栏都是 `/admin/admin/…` 双写。
- **根因（实测坐实，非猜）**：双写来自**出站链接**，不在入站。ucode `build_url`（`dispatcher.uc:730` `let url=[http.getenv('SCRIPT_NAME')??'']` + 逐段拼）与前端 `luci.js` 的 `url(){return this.path(env.scriptname,…)}`（`header.ut:15` 把 `env.scriptname=http.getenv("SCRIPT_NAME")` 注入页面），都是 `SCRIPT_NAME + 菜单树路径`。菜单树顶层恒有 `admin` 段，而 molly 把 SCRIPT_NAME 直接设成前缀 `/admin` → 两个 admin 撞名 → `/admin/admin/…`。`--luci-strip` 只折算**入站**（`LuciTreePath`），管不到 ucode 出站拼接。
- **修法**（`internal/handlers/cgi.go`）：新增 `cgiScriptName()`，交给 ucode 的 SCRIPT_NAME = `TrimSuffix(LuciPrefix, LuciStripSegment)`。prefix=/admin、strip=/admin → SCRIPT_NAME=`""` → `build_url = "" + /admin/… = /admin/…`（单段）。strip 为空（上游默认）时返回 LuciPrefix，逐字节不变；PATH_INFO 仍给完整树路径（ucode 靠它找节点），入站照旧由 `LuciTreePath` 折算，两侧对齐。
- **门禁**：gofmt/vet 干净；新增两测 `TestCGIScriptNameWithStrip`（strip 时 SCRIPT_NAME 空、PATH_INFO 全树）与 `TestCGIScriptNameNoStrip`（默认不变）；`go test ./...` 全绿；宿主 `tests/smoke.sh` **334/0**。
- **真机**（make deploy 交叉编译上机、restart）：以浏览器表单 `/auth/login` 拿 cookie 后 `/admin/`、`/admin/status/overview`、`/admin/network/network`、`/admin/system/system` 全 200 且标题对（概览/接口/系统）；页面内 `/admin/admin` 计数 **0**；注入的 `env.scriptname` 变空；server 渲染的 translations href 从 `/admin/admin/translations/zh-cn` 收成 `/admin/translations/zh-cn`。回归：`device-luci` **47/0**、`device-simple` **39/0**。
- **未受影响**：`cgi_base = scriptname.replace(/\/?[^/]+$/,'')` 改前（/admin）改后（""）都算得 `""`，故 package-manager 那类 `POST /cgi-exec` 的 405（cgi-io 缺口，用户已定「只记录为已知限制」）与此改动正交，未因此变化。

## 2026-10-09 会话：cgi-io 三件套原生实现（推翻上次「只记录」的决定）

- **触发**：用户重贴浏览器 console —— `/admin/system/package-manager` 已 200（URL 前缀修好），但 `POST /cgi-exec` 仍 405，`fs.exec_direct → handleCgiIoReply Error: Method Not Allowed`，软件包列表出不来。AskUserQuestion → 用户选「**现在就实现（原生 Go）**」。
- **契约（实测 fs.js/ui.js/luci.js，不猜）**：`exec_direct`→POST `cgi_base/cgi-exec` body urlencoded `sessionid&command&stderr(0|1)`；`read_direct`→`cgi-download` body `sessionid&path`；`ui.uploadFile`→`cgi-upload` multipart `sessionid&filename(目标)&filedata`。`cgi_base = scriptname.replace(/\/[^/]+$/,'')`（本部署 scriptname=""→cgi_base=""→裸 `/cgi-*`；上游默认 →`/cgi-bin`）。`handleCgiIoReply` 只认 status==200 取 text/blob，非 200 映射 400 InvalidArgument/403 Permission/404 NotFound。request 对任何完成的 XHR 都 resolve Response（仅网络错才 reject），故 upload 里 `res.json()` 总会跑。
- **安全模型**：不 fork `/usr/libexec/cgi-io`（依赖 uhttpd 塞的环境，实测手动 fork 返 exit255）；不复刻 `cgi-io:[exec]` 那道闸（rpcd `session.access` 不暴露 cgi-io scope，实测恒 false）。改为**复用 ubus file.exec 那道 ACL**（`fileExecLookup`+`fileCanonicalizePath`+`fileExecCheckACL`，桥接态经 `sessionAccess→rpcdSessionAccess`，与原厂 file-exec 同源同判）→ `/cgi-exec` 能跑的命令 ⊆ `ubus file.exec`，**无新执行面**。差别只在回包：file.exec 是 JSON+64KB cap，cgi-io 流式吐原始 stdout。三件套都先要**已认证**会话（`cgiioRequireSession`：非空且≠SessionDefaultID），命令/路径本身再靠 ACL fail-closed 兜底。download 走 file `read`，upload 走 file `write`。
- **落地**：
  - `internal/backend/cgi_io.go`（新）：`cgiioTokenize`（反斜杠转义下一字符、未转义空格分隔、空 token 丢弃——还原 exec_direct 的 `\`→`\\`、空白→`\<空白>` 编码）、`CGIExec`（ACL→`exec.CommandContext` 流式 c.Stdout=out，wantStderr 并入；超时→7，其余退出码照旧 200 吐已产出内容）、`CGIDownload`（fileCheckPath read→io.Copy）、`CGIUpload`（fileCheckPath write→O_WRONLY|CREATE|TRUNC）。返 ubus 码。
  - `internal/handlers/cgi_io.go`（新）：`cgiBasePrefix()`（=SCRIPT_NAME 去末段，逐字节复刻 JS）、`cgiIOEndpointOf`/`IsCGIIOPath`（精确匹配 base+/cgi-{exec,download,upload}）、`ServeCGIIO`（非 POST→405；ParseForm 取 sessionid/command/stderr、ParseMultipartForm 取 filedata）。`streamWriter` 首次 Write 才发 200+octet-stream，令 handler 能在「还没发头」时把 ACL/校验失败映射 400/403/404/504。upload **恒 200+JSON**：成功 `{name,size,checksum(md5),sha256sum}`（TeeReader 边写边算），失败 `{failure:true,message}`。
  - `main.go`：在 `ServeStatic` **之前**接入 `IsCGIIOPath`→`ServeCGIIO`（默认部署 cgi-io 落 /cgi-bin/ 会被 ServeStatic 判 403，本部署裸 /cgi-exec 会被判 405，必须在静态兜底前拦）。
- **门禁（全绿）**：gofmt/vet 干净；新增 backend `cgi_io_test.go`（tokenize、需会话、ACL 兜底/NotFound/空命令 2、授权流式跑通、命令行 ACL 精确匹配、download read、upload write）+ handlers `cgi_io_test.go`（bare/default 两种 base 的路由判定、405/403/404/400 映射、upload JSON 契约）；`go test ./...` 全绿；`tests/smoke.sh` 加 7 条 cgi-io 断言（$B2=prefix/admin+strip 实例，用查无此人的会话走 fail-closed 验路由不再 405 + ACL 没放开 + /cgi-exec/x 不误吞）→ **341/0**（原 334+7）。
- **⚠ 真机部署被挡（非代码）**：交叉编译 `make target` 出 `build/molly-arm64` 成功；但**设备拒绝 root 的 SSH 口令登录**——`ssh -v`、`sshpass -e`/`-p` + `PubkeyAuthentication=no`/`PreferredAuthentications=password`、`scp -O` 一律 `Permission denied (publickey,password)`。同一口令 `yu678910` 走 **HTTP `/auth/login` 却成功**（302+sysauth_molly cookie）→ 是设备侧 dropbear 关了 root 口令登录（或 SSH 口令与控制台/HTTP 不同），不是 molly 代码问题。当前设备仍是**旧二进制**：`POST /cgi-exec` 实测仍 **405**。b5（真机验证 package-manager 出列表 / ACL 兜底 / 回归 device-luci47·simple39）**待 SSH 恢复**。molly 禁改 /etc/config，无法自行放开 dropbear。已就此询问用户。后续复核：`ssh -o BatchMode=yes`（纯 key）同样 `Permission denied (publickey,password)`——本机 `id_rsa` 也不在设备授权里，SSH 口令+key 双双被拒确认。也无 HTTP 路径能替换**运行中**的二进制（旧实例 `file.write` ACL 不覆盖 /usr/sbin；对运行中程序 O_TRUNC 触发 ETXTBSY）。故交付 `tests/deploy_cgi_io.sh`：一条命令做 scp→停→覆盖 /usr/sbin/molly→起→**只用 HTTP 自验**（POST /cgi-exec 断言不再 405 + 越权命令应 403）。已用当前旧设备跑其验证段，正确报 405（canary 有效，登录 sid 长度 32 正常）。用户跑该脚本即完成 b5。

## 会话：部署到全新设备 10.5.2.1 + 修 /admin 页 403（cookie 改名）

- **换机**：192.168.1.1 SSH 被拒且一度进入 `no_cmd_match` 异常态（:8080 已非 molly），本会话转用干净可达的 **10.5.2.1**（aarch64 mt7986a / ImmortalWrt 25.12.2 / **APK 系**，`root/yu678910` SSH 可进；`--docroot /www --luci-prefix /admin --luci-strip admin --luci-cgi /www/cgi-bin/luci`，procd `/etc/init.d/molly`，pid 8836 监听 :::8080）。
- **cgi-io 真机全绿**：`POST /cgi-exec package-manager-call list-installed`→**200 / 720028B**（原 405 彻底消失）；`list-available`→200/11.6MiB；越权 `/bin/rm`→**403**；bogus 会话+有效命令→403；bogus 命令/不存在二进制→**404**（exec 白名单先于会话判、fail-closed）；`GET /cgi-exec`→405。download/upload 忠实镜像 rpcd file.read/write ACL。
- **发现真 bug（桥接页 403）**：`/admin/*` 页带合法会话仍 **403**（正文却是完整页面）。根因＝**cookie 名不匹配**：molly 只下发 `sysauth_molly`，`buildCGIEnv` 把请求 Cookie 原样转发；设备上**未打补丁的 stock ucode dispatcher 只认 `sysauth_http`/`sysauth_https`**（`dispatcher.uc` 按 HTTPS 二选一）→ 子进程判未登录 → 每页 403。`session.access(scope=luci)` 显示会话有完整 grants，不是缺 ACL。
- **修复**（`internal/handlers/cgi.go` `buildCGIEnv`）：解析 `luciSIDFromCookie(r)` 得 SID 后，把 `sysauth_http=<sid>; sysauth_https=<sid>` 追加进 `HTTP_COOKIE`；通用头循环 `skip` 原 `Cookie`、末尾统一只发**一份**改名后的 `HTTP_COOKIE`（不双写 cookie）。SID 本就是 rpcd 发的，子进程拿它 access 即共享同一条会话。
- **门禁全绿**：新增 `cgi_test.go` 两测（`TestBuildCGIEnvRenamesSessionCookie` 断言三种名齐全且 HTTP_COOKIE 恰一份、`TestBuildCGIEnvAnonymousNoCookie` 断言匿名不伪造）；`make lint`+`make test` 绿、`make smoke` **341/0**。
- **验证**：重编译→停服→scp 覆盖→起（pid 8836）。HTTP 侧 `sysauth_molly`（真实浏览器路径）下 `/admin/system/package-manager`、`/admin/status/overview` 由 403→**200**。`make device-luci HOST=10.5.2.1 ... /admin` **47/0**（含多页「不再要求登录」，正是本修复的体现）。`make device-simple` **37/2**——两条 FAIL 是 `file.exec /bin/df`、`file.read /etc/config/network` 返 rpcd `err=6`：实测设备所有 rpcd acl.d 里**无 df、无 /etc/config read** 授权，桥接态 molly 原样代理 rpcd 判决，**非 molly bug、与 cookie 无关**（是这台 mocca.vod 固件 ACL 比基准机更严）。**浏览器实机确认**：登录 root 后进 package-manager，Console 0 报错、无 405，`/cgi-exec` 全 200，列表渲染出「可用 8090 / 已安装 237」条目。

## 会话：10.5.2.1 /lite/#/disk 读容量 Permission denied → 补装部署 ACL

- **现象/根因**：/lite 存储页 `file.exec /bin/df` 报 Permission denied（device-simple 里 `disk file.exec /bin/df`、`bk file.read /etc/config/network` 两条 FAIL，err=6）。**非 molly bug**：这台固件 rpcd acl.d 里本无 df/`/etc/config` read 授权；且**全新部署只 scp 了二进制+init.d，漏了站点 ACL 那一步**（docs/interfaces.md:107 明确要 `tools/molly-acl.json → /usr/share/rpcd/acl.d/molly.json`，里面已含 `/bin/df:[exec]`、`/etc/config/*:[read]`）。
- **修**：`scp tools/molly-acl.json → 设备:/usr/share/rpcd/acl.d/molly.json`（644）→ `/etc/init.d/rpcd reload`（SIGHUP 即重扫 acl.d，rpcd 不重启、会话不断）。桥接态 molly 的 file.exec ACL 经 `session.access` 拿 rpcd grants，故 rpcd 认了新 acl 后 molly 立刻放行。
- **⚠ 关键操作坑**：rpcd 在 **session.login 时**就把 grants 固化进会话，reload 只影响**新登录**。旧浏览器会话（reload 前建的）仍无 df 授权 → 用户浏览器里仍会 Permission denied，**必须登出再登入**（或换新 sid）才生效。用 curl 每次 `/auth/login` 新建会话所以一路都 200。
- **验**：新 sid 下 `file.exec {command:/bin/df,params:[-k]}`→`result[0,{code:0,stdout:Filesystem…}]`；`file.read /etc/config/network`→200。`make device-simple HOST=10.5.2.1` 由 37/2 → **39/0**。（另注：file.exec 的 RPC 签名是 `command`+`params[]`，不是 `path`/`args`；用错字段会得 code2 InvalidArgument，是探针写错非服务问题。）

## 风险与不确定性

- **cgo + zig cc 交叉编译**：**已排除**（M5 侦察实测通过，配方与两个坑见上）。
  剩余风险是 C 回调（`//export` + shim）与 uloop 线程在 Go 下能否安全落地。
- **net/http 与原语义差异**：keep-alive、请求行/头/体上限、超时、`Date`/`Server` 头、
  HEAD 处理等，需逐条对齐 Odin 版并在 M1 记录偏离。
- **`/ubus` 的 `result` 数值形态**：JSON 里 `result` 是数组（`[0, {...}]`），
  Go 侧要用 `[]any` 才能保持与上游一致的序列化顺序与形态。