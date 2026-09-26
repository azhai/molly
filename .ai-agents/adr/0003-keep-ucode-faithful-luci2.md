# ADR 0003: Keep ucode for rendering; replicate LuCI2's wiring (faithful first, simplify later)

## Status
Accepted （用户 2026-09-26 决定：保留 ucode，参考 LuCI2 实现，先做复刻版本，将来再重构简化）
Supersedes [ADR 0002](0002-api-first-own-web-ui.md)（API-first + 自研 Mithril 前端）

## Context

用户目标：**实现 LuCI 的功能，去掉 Lua**，并明确「先复刻、后重构」。

渲染链的取证结论（`modules/luci-base/ucode/` 同一提交 `d6167ea`，2026-09-26 实测）：

| 事实 | 证据 |
| --- | --- |
| 页面主体由**浏览器**渲染，服务端只出骨架 | `ucode/template/view.ut` 全文 12 行：`include('header')` + `<div id="view">` + `L.require('ui').then(ui => ui.instantiateView('{{ view }}'))` + `include('footer')` |
| 渲染入口是 `luci.dispatcher`（ucode） | `ucode/dispatcher.uc` 的 `dispatch(req)`；`runtime.uc:118-129` `render_any`：`<path>.ut` 走 ucode 模板，否则回落 `render_lua`（Lua `.htm`，:68-71） |
| 真实 menu.d 的 action 分布（413 路径） | `view` 311 / `firstchild` 43 / `function` 31 / `alias` 21 / `template` 6 / `call` 1 —— 其中 `function`/`call`/`cbi`/`form` 都要求执行任意 app 的 ucode |
| Lua 只是遗留回落 | 仓库存量 228 个 `.lua` + 153 个 `.htm`（都在 legacy app 的 `luasrc/`），`.uc` 只有 26 个 |
| **uhttpd 的 ucode 接线（LuCI2 默认形态）** | `luci-base/Makefile:47-48`：`uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'`；`ucode/uhttpd.uc` 定义 `global.handle_request(env)`，用 `uhttpd.recv` / `uhttpd.send` 收发 |
| CGI 兜底形态 | `modules/luci-base/htdocs/cgi-bin/luci`：`#!/usr/bin/env ucode`，`dispatch(request(getenv(), read, write))` |
| 运行时依赖 | `luci-base` 依赖 `ucode` + `ucode-mod-{fs,log,uci,ubus,math,html}` + `liblucihttp-ucode` + `rpcd-mod-ucode` + `cgi-io` |

结论：在 Odin 里复刻渲染 = 实现一个 ucode VM（`function`/`call`/`cbi`/`form` 都要求执行任意 ucode），
与「去掉 Lua、精简栈」的初衷相悖；而**保留 ucode** 恰好是上游自己的形态，代价最小、行为最保真。

## Decision

1. **渲染与菜单交给设备上的 ucode**（`/usr/share/ucode/luci/uhttpd.uc` + `luci.*` ucode 库），
   molly 不实现渲染、不实现 ucode VM、不实现 Lua。
2. **molly 复刻 uhttpd 侧的接线**，分两步落地（先复刻、后优化）：
   - **T1（先做）**：molly 承接 `/cgi-bin/luci` 前缀，按 CGI 规范构造环境（`SCRIPT_NAME` /
     `PATH_INFO` / `REQUEST_METHOD` / `CONTENT_LENGTH` / `HTTP_*` …），以子进程方式执行
     `/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc`，把 stdout 作为响应流回。等价于上游的 CGI 兜底形态，
     零新增 C 绑定。
   - **T2（后续，可选）**：绑定 `libucode`（VM API）把 `uhttpd.uc` 跑在同一进程里，并自己实现
     `uhttpd.recv` / `uhttpd.send` 两个原语——这才是 uhttpd `ucode_prefix` 的进程内形态；等 T1 跑通、
     需要压掉 fork 开销时再做。
3. **molly 继续替代 rpcd**（P3-2…P3-5：`session`/`uci`/`file`/`luci` 对象）：ucode dispatcher 通过
   ubus 调这些对象，所以「保留 ucode」与「替代 rpcd」不冲突，可以逐步替换（先并存，再摘掉设备 rpcd）。
4. **ACL 的执行点在 ubus 层**：页面级 ACL 由 ucode dispatcher 依据 `session` 对象 + `acl.d` 判定，
   molly 只需正确实现 `session`/`session.access` 与入站调用的 ACL 校验（P3-6 的语义据此调整）。
5. **Odin dispatcher（`src/luci`）暂离请求路径**：P2/6b 建成的菜单树与 `depends` 语义、以及
   `.ai-memory/r8-*` 的离线取证**全部保留**，作为「将来重构简化（去 ucode）」的对照实现与回归基准，
   但 P3 不再需要它参与请求处理；`docs/architecture.md` 要标注它的当前状态。
6. **前端的取舍回到上游**：不写自研 Mithril 界面（ADR 0002 作废），继续用 LuCI 自带的浏览器端资源
   （`/luci-static/resources/view/*.js` 由 molly 的静态文件路径送出即可）。

## Options considered

- **T1 + 保留 ucode（本 ADR）** —— 采纳：行为最保真、零新增绑定、与上游 CGI 形态一致。
- **T2 进程内嵌入 libucode** —— 暂缓：需要绑定 ucode VM API 并实现 `uhttpd.recv/send`，等 T1 验证后再评估。
- **在 Odin 里实现 ucode 子集** —— 拒绝：等于重写一个语言 VM。
- **API-first + 自研 Mithril 前端（ADR 0002）** —— 被本 ADR 取代：改动最大、且放弃上游页面兼容。
- **只复刻 `.ut` 骨架模板（早前的 D 路线）** —— 拒绝：仍需 ucode 才能执行 349 条路径的 action，
  且界面一旦自研就没必要保留两套渲染栈。

## Consequences

- **更容易**：渲染/菜单/ACL 语义全部由上游代码负责，molly 只管 HTTP、静态文件、ubus 转发与（将来的）
  rpcd 对象；去掉 Lua 天然成立（`template` 的 6 条 Lua 页面在 25.12 里是回落路径，可单独补成 `.ut`
  或明确不支持）。
- **更难**：CGI 环境构造必须与 uhttpd 一致（`PATH_INFO` 语义、`SCRIPT_NAME`、请求体透传、headers 映射），
  这些要用真机 golden 对比逐条校准；每条 `/cgi-bin/luci` 请求在 T1 下多一次进程创建。
- **代价与边界（明确记录）**：
  1. 渲染不由 molly 掌控（符合「先复刻」的目标，但将来若要「去 ucode」需要重新走 P2 的 dispatcher 路）。
  2. 依赖设备存在 `ucode` 与 `luci` 的 ucode 库（25.12.2 默认有；`opkg` 依赖树已核对）。
  3. T1 下 `/cgi-bin/luci` 不再经过 molly 的 dispatcher，6b/6c 的 smoke 断言只在「直连 molly 的
     dispatcher 模式」下有意义，需要在文档里说清启用条件。
- **对既有工作的影响**：P3-1（ubus 服务线程）不变；P3-2…P3-5（对象）不变；P3-6 语义改为「ubus 层 ACL」；
  P3-7（SSE）不变；P3-8′（自研前端）取消，改为 P3-8″（ucode 接线 T1/T2）。

## Follow-ups

- [ ] P3-8″-T1：`/cgi-bin/luci` → 子进程 ucode 的桥接 + CGI 环境构造；拿原厂 uhttpd 的响应做 golden 对比。
- [ ] 设备侧核对：`uci get uhttpd.main.ucode_prefix`、`ls -l /usr/bin/ucode /usr/share/ucode/luci/`、
      `opkg list-installed | grep -E 'ucode|luci-base|lua'`（确认接线与「无 Lua」现状）。
- [ ] 在 `docs/architecture.md` 标注 Odin dispatcher 的「保留但不在请求路径」状态与两种模式的启用条件。
- [ ] T2 评估：fork 开销与 RSS 实测后再决定是否内嵌 libucode。
