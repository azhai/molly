# 双界面：专家版迁到 /pro，`/` 新增新手版

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

## Go 版（gomolly）同样落地

同一套形态在 `gomolly/`（独立 `go.mod`）里也做了，**设备现在跑的就是 Go 版**：
`/usr/sbin/molly` = gomolly aarch64（17.7MB），Odin 版备份在 `/usr/sbin/molly.odin.bak`。

| 点 | Odin 版 | Go 版 |
|---|---|---|
| 前缀 | `handlers.LUCI_PREFIX` 变量 + `luci_set_prefix` | `handlers.LuciPrefix` 变量 + `SetLuciPrefix` |
| 新手版页面 | `#load`（`src/novice/assets/index.html`） | `go:embed`（`internal/novice/index.html`） |
| 会话读取 | `luci_sid_from_cookie`（`sysauth_molly` 起三个名字） | 同名同义 `luciSIDFromCookie` |
| `/cgi-bin/*` | 403 | 403（同一策略） |
| 路由 | `handle()` 里加新手版分支 | `router.ServeHTTP` 里加同一分支 |
| 两份页面副本 | — | `internal/novice/sync_test.go` 守住逐字节一致 |

**为什么页面要复制一份**：`go:embed` 不能引用包目录之外的路径（`..` 会被拒），而两个二进制
各自要自包含。这与 `internal/webassets/` 抄 luci-static 是同一个约定（那里用
`tools/embed-assets.sh`）。一致性由那个测试兜底——改了 Odin 那份忘了 Go 那份会红。

**CLI 完全一致**（`--listen/--docroot/--menu-dir/--luci-prefix/--luci-cgi/--ubus-socket`），
所以设备上同一个 `/etc/init.d/molly` 两个二进制都能用，换二进制就能换实现。

Go 版门禁：`gofmt -l` 干净、`go vet` 干净、`go test -count=1 ./...` 全绿、
`tests/smoke.sh` **299/0**；真机 **23/23**（同 Odin 版的验证清单）。

顺手改掉 gomolly smoke 的两条旧断言：`/` 改判新手版；目录回落覆盖换到
`/luci-static/sub/`（因为共享 fixture 里我加了它自己的 `index.html`）；`/cgi-bin/luci-static`
的边界断言从 404 改 403（现在由 `/cgi-bin/*` 策略拒绝，与「被 dispatcher 抢走」的 404 可区分）。

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
