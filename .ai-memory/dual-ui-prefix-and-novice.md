# 双界面：专家版 + 新手版（当前布局：专家版 `/plus`、新手版 `/lite`、`/` 是入口）

> **当前布局（2026-10-07 最后一次改动）**
>
> | 界面 | 路径 | 说明 |
> |---|---|---|
> | 专家版 | `/plus/`（`--luci-prefix /plus`，备份 `/etc/init.d/molly.bak-plus`） | 完整 LuCI，内容由设备 ucode dispatcher 渲染 |
> | 新手版 | `/lite/` | 一页六件事，编译进二进制的单文件 |
> | 入口 | `/` | **302** → `/lite/`（用 302 不用 301：前缀还会再挪，301 会被浏览器永久缓存） |
>
> 下面是这条线一路演进的过程记录（更早的 `/pro`、新手版挂在 `/` 的形态留在正文里，
> 那些描述在各自的时间点都是准确的）。

## 需求原文（第一版：前缀改 /pro）

需求（2026-10-07，用户原话）：「将当前的网址前缀从 `/cgi-bin/luci/` 改为 `/pro/`，这套称为专家版；
在 `/` 下面再增加一套新手版，只需要常见功能并简化操作界面，主要是系统状态、实时负载图、重启路由、
内外网设置、无线中继、DHCP 的 IP 分配和 Mac 绑定等。」

## 形态

| 界面 | 路径 | 内容 |
|---|---|---|
| 专家版 | `--luci-prefix`（本站 `/pro`） | 完整 LuCI，内容仍由设备 ucode dispatcher 渲染 |
| 新手版 | `/`、`/index.html` | 一页六件事：状态 / 负载图 / 重启 / 内外网 / 无线中继 / DHCP 绑定 |

设备上的启动命令（`/etc/init.d/molly`，备份 `molly.bak-prefix`）：

```sh
/usr/sbin/molly --listen 0.0.0.0:8080 --docroot /www-molly \
  --menu-dir /usr/share/luci-molly/menu.d --luci-prefix /pro \
  --luci-cgi "/usr/bin/ucode /www-molly/cgi-bin/luci" \
  --ubus-socket /var/run/ubus/molly.sock
```

## 决策与理由

1. **前缀做成变量而不是常量**（`handlers/cgi_luci.odin` 的 `LUCI_PREFIX` + `luci_set_prefix`）。
   这**一个值同时决定三件事**：路由判据、CGI 的 `SCRIPT_NAME`、`PATH_INFO` 的切分点。
   dispatcher 的 `build_url()` 就是拿 `SCRIPT_NAME` 拼所有页面 URL 的，所以必须同源；
   散着写就会出现「路由换了、SCRIPT_NAME 没换」这种 ucode 侧全错的组合。

2. **设备侧不需要打补丁**。先查过：`dispatcher.uc` 用 `http.getenv('SCRIPT_NAME')` 建 URL
   （`build_url`）、用 `PATH_INFO` 解析路径，天然前缀无关；设备上唯一硬编码 `/cgi-bin/luci`
   的是 `/www/luci-static/resources/view/status/include/11_upgrades.js`（升级检查，与本次无关）。
   真机验证印证：换前缀后登录下发的 cookie 是 `path=/pro/`，说明 `SCRIPT_NAME` 确实到位。

3. **新手版不做成 LuCI 应用**。要的是「功能少、界面简单」，套进 menu.d/ACL/视图体系反而更重。
   做法是一页静态 HTML（CSS/JS 内联）+ 既有 `/ubus` JSON-RPC：
   - 页面用 `#load` 在**编译期**编进二进制（Odin 版的 go:embed），不依赖 docroot 文件、不碰 ucode；
   - 服务端只做两件事：把 `/` 与 `/index.html` 路由到 `serve_novice`，以及替换两个占位符
     （`__SID__`、`__EXPERT_PREFIX__`）；
   - **没有新手版专属 API**，数据面就是 `params: [sid, obj, meth, args]` 那套。

4. **两套界面共用会话**。都从同一个 cookie 取 sid（`luci_sid_from_cookie` 现在认
   `sysauth_molly`（molly 侧补丁后的专属名）/ `sysauth_https` / `sysauth_http`）。
   于是「在专家版登录过，新手版直接可用」是自然结果，不是额外协调出来的。
   代价是 sid 要拼进页面的 JS 字符串——所以按**白名单**收窄到「只可能是 32 位 hex」，
   非法输入整串丢弃（不做转义：HTML 与 JS 两种上下文各转义一遍容易漏）。

5. **写操作统一走 `uci set/add/delete → commit → apply`**（与 LuCI 的「保存并应用」同一条路）。
   `apply` 不带 `rollback`，所以不需要二次确认。

## 真机验证（2026-10-07，192.168.1.1）

- 专家版：`POST /pro/` → 302 + `set-cookie: sysauth_molly=…; path=/pro/`；
  `/pro/`、`/pro/admin/network/network`、`/pro/admin/system/system` 全 200（标题正确）。
- 新手版：`GET /` → 200（30KB），页面里**注入了同一个 sid**，`EXPERT_PREFIX = "/pro"`；
  无 cookie 也 200（客户端再弹登录卡）。
- 六项功能数据面全通（用真实 root 会话逐条打过）：`system board/info`（型号 Netcore N60 Pro、
  `load` 是 ×65536 定点）、`uci get network|dhcp|wireless`、`luci-rpc getWirelessDevices|getDHCPLeases`、
  `session access {object:"system", function:"reboot"}` → `true`。
- 写路径：`uci add dhcp host` → `changes` 可见 → `delete` → 线上 `/etc/config` 一个字节没动
  （只在会话 delta 里操作，未 commit）。
- 门禁：unit 4/0、http_smoke 279/0、cgi_smoke 31/0。

## 顺手修掉的一个面：docroot 的 `/cgi-bin/*` 会变成可下载的纯文本

换前缀之前 `/cgi-bin/luci` 被 `serve_luci` 吃掉，看不到这个面；前缀一挪，文档根里那个 CGI
兜底脚本就退化成静态文件（真机上实测 200 + 脚本正文）。上游 uhttpd 是把 docroot 的
`/cgi-bin/*` 当 CGI **执行**、从不吐正文，所以 `handlers/static.odin` 里改成一律 **403**（策略性
拒绝，不是「文件不存在」）。这条在 http_smoke 里有三条断言钉住。

## Go 版落地（2026-10-07 后期，仓库只剩 Go 实现）

原来 Odin 与 Go 两份实现并存（Odin 在 `src/`、Go 在 `gomolly/`）。**现在仓库只剩 Go 版，
且它已经提升到仓库根**（`go.mod` 在根；module 名 2026-10-07 之后是 `github.com/azhai/molly`，
原先叫 `gomolly`）；Odin 的 `src/`、`build.sh`
已从工作区移除（git 历史里还在，最近一次相关提交是 `34acda7 修改URL，分为新手版与专家版`）。
设备上跑的是 Go 版：`/usr/sbin/molly` = gomolly aarch64，Odin 版备份在 `/usr/sbin/molly.odin.bak`。

| 点 | 实现 |
|---|---|
| 前缀 | `handlers.LuciPrefix` 变量 + `SetLuciPrefix`（`--luci-prefix`） |
| 新手版页面 | `go:embed`，落在 **`webassets/novice/index.html`** |
| 会话读取 | `luciSIDFromCookie`（`sysauth_molly` 起三个名字） |
| `/cgi-bin/*` | 403（上游 uhttpd 只执行它、从不吐正文） |
| 路由 | `router.ServeHTTP` 里 `IsNovicePath` 分支，排在静态文件之前 |

### 前端资源统一到项目根 `webassets/`

`internal/webassets/` 搬到根目录并改名 `webassets/`（import 变成 `gomolly/webassets`），
同时把新手版页面也并了进去——它们本来就是同一类东西：**要编进二进制的前端资源**。

- `webassets/luci-static/`：设备 LuCI 静态资源的**兜底副本**，可选（`-tags embed_assets`），
  由 `tools/embed-assets.sh` 从设备抄入（已 gitignore）；
- `webassets/novice/index.html`：新手版整页，**恒编入**（`webassets.NoviceHTML`）。

页面不再需要第二份副本（Odin 实现已不在仓库），当初那个 `sync_test.go` 一致性守卫随之删除。
`go:embed` 不能引用包目录之外的路径（`..` 会被拒），所以「资源挨着包放」是这个结构的前提。

### 两套界面是同一条会话（本次的第二个改动）

改之前：新手版由页面里的 JS 自己调 `session login`，sid 存在 `localStorage`；专家版由
ucode dispatcher 登录、cookie 作用域是 `path=/pro/`。结果是**两条互不相认的会话**：在哪边
登录，另一边都还得再登一次。

改法两条，缺一不可：

1. **登录/退出改成服务端**（`handlers.ServeNovice` 的 POST 分支）：
   `action=login|logout` → `deps.CallObject("session","login"|"destroy", …)` →
   `Set-Cookie: sysauth_molly=<sid>; path=/; HttpOnly; SameSite=strict` → 302 回 `/`
   （失败回 `/?login_error=1`）。用的就是**专家版那一个** `session` 对象，所以「统一」是
   同一条链路的自然结果，不是又实现了一套鉴权。页面里的 `localStorage`/影子会话随之删掉。
2. **专家版会话 cookie 的 path 放宽到 `/`**（`internal/handlers/cgi.go` 的
   `widenSessionCookiePath`）：上游 dispatcher 用 `path=${build_url()}`，也就是专家版前缀
   `/pro/`；而 cookie 是**按 path 作用域**收发的，`/pro/` 作用域的 cookie 浏览器不会在 `/`
   上发回来。放宽到 `/` 之后两套界面读写同一个 cookie 槽位 —— 这才叫一条会话。
   只动名字以 `sysauth` 开头的 cookie，其余 Set-Cookie 逐字节透传。

**验证**（真机 18/0）：新手版登录下发的 cookie（`Path=/`）拿去专家版页面 → 200 且标题正确；
专家版登录下发的 cookie 现在是 `path=/`（被放宽了）→ 新手版页面注入同一个 sid 且 RPC 可用；
退出清掉共用 cookie，之后该 sid 立刻不可用（403）；密码错回 `/?login_error=1` 且不下发 cookie。

### 门禁

`gofmt -l` 干净、`go vet` 干净、`go test -count=1 ./...` 全绿、`tests/smoke.sh` **310/0**
（含新增的会话统一一节）；真机会话统一 **18/0**、功能面 23/23。

## 顺带修掉的重构遗留

这次仓库提升（Go 实现上移一级）打断了几处相对路径，一并修了：

- Go 测试里的 fixture 路径 `../../../tests/…` → `../../tests/…`（`internal/luci`、
  `internal/backend`、`internal/handlers`）；`luci_darwin.go` 的兜底路径改成**相对进程 cwd**
  的 `tests/fixtures/board.json`（与 `darwin.go` 里 acl.d 的写法一致）。
- `tests/smoke.sh` 的 `ROOT="$(cd .. && pwd)"` → `$(dirname "$0")/..`（写死 `cd ..` 只在
  「脚本位于仓库根的子目录」时成立）。
- **`tests/fixtures/` 从工作区被删掉了**（它是 Odin 仓库的测试数据，Go 的测试与 smoke 都在用，
  `go-port-plan` 也写明直接复用）——已从 git 恢复。
- `README.md` 与 `docs/*.md` **仍是 Odin 时代的内容**（描述已删除的 `src/`），本次没动；
  要不要整篇改写成 Go 版由用户定。

## 遗留 / 未实测

- **`apply` 没在真机上触发过**：「保存并生效」的最后一步是 `uci apply` → `/sbin/reload_config`，
  会真实 reload 网络/无线/dnsmasq（有一瞬中断），所以验证只做到 `commit`。代码路径与 ACL 都确认过
  （`uci apply` 参数是 `rollback`/`timeout`），但第一次点「保存并生效」时值得人在旁边。
- **无线中继的写路径没落盘**：UI 会 `uci add wireless wifi-iface name=wwan` + `uci add network interface name=wwan`
  + 打开所用频段 + commit + apply。真机上只验证了读侧（`radio0`/`radio1` 当前都是 `disabled='1'`，
  所以「扫描附近 Wi-Fi」在这个设备上会走兜底提示「可直接手填 SSID」）。
- **重启没真按**：只验证了 ACL 放行（`session access … reboot → true`）。
- 设备 `/tmp/molly` 还留着一份 17MB 的旧二进制（12:02，上一次手工运行留下的），它那次占着
  `:::8080` 导致 init 启动报 `Address_In_Use`。要不要删由用户定。
