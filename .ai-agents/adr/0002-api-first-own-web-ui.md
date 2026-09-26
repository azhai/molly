# ADR 0002: API-first server; own web UI (Mithril) instead of replicating LuCI's ucode/Lua rendering

## Status
Superseded by [ADR 0003](0003-keep-ucode-faithful-luci2.md) （2026-09-26 用户改为「保留 ucode、参考 LuCI2 复刻、先保真后重构」）

> 本条记录的是当时的决定与被否掉的理由，保留全文以便回溯（AGENTS.md §6.1）。结论已由 ADR 0003 取代。

## Context

P2/P3 原先的假设是「复刻 LuCI 的服务端渲染」。取证后（`modules/luci-base/ucode/runtime.uc`
186 行 + `ucode/template/*.ut` + `dispatcher.uc` 的 `run_action`）事实是：

| 事实 | 证据 |
| --- | --- |
| `view` 动作的服务端产物只有 12 行骨架 | `ucode/template/view.ut`：`include('header')` + `<div id="view">` + `L.require('ui').then(ui => ui.instantiateView('{{ view }}'))` + `include('footer')` |
| 页面主体由**浏览器**渲染 | 视图资源是浏览器 JS：`htdocs/luci-static/resources/view/status/include/10_system.js` 里 `rpc.declare({ object: 'luci', method: … })`，数据经 `/ubus` 取 |
| 渲染入口分派 | `runtime.uc:118-129` `render_any`：`<path>.ut` 存在 → ucode 模板；否则 `render_lua`（:68-71，Lua `.htm`） |
| 真实 menu.d 的 action 分布（413 路径） | `view` 311 / `firstchild` 43 / `function` 31 / `alias` 21 / `template` 6 / `call` 1 |
| Lua 是遗留栈 | 仓库 228 个 `.lua` + 153 个 `.htm`（都在 legacy app 的 `luasrc/`），`.uc` 只有 26 个 |
| 有 app 依赖 rpcd 执行 ucode 脚本 | `/usr/share/rpcd/ucode/{ddns,docker_rpc,tailscale,wifihistory,example}.uc` |

要在 Odin 里做到「渲染与上游一致」，等于实现一个 ucode 解释器（`function`/`call`/`cbi`/`form`
都要求执行任意 LuCI ucode），这与「去掉 Lua」的诉求方向相反、工作量也远超收益。

## Decision

molly 转为 **API-first**：

1. **API 是唯一的兼容面**：`/ubus`（旧式 POST + 新式 `/ubus/call/<path>`）+ 四个对象的契约
   （`session` / `uci` / `file` / `luci`）+ ACL，保持与 rpcd 一致（现有 app 与脚本依赖它们）。
2. **Web 界面自研**：HTML/CSS/JS，客户端框架 **Mithril.js**（用户指定）。**不引入 npm / 打包器**：
   Mithril 以单个 `mithril.min.js` vendor 进仓库（MIT），页面用普通 `<script>`/ES module 加载
   （与本仓库「bash + Odin、无 package.json」的现状一致）。
3. **菜单树以 JSON 暴露**：`src/luci` 已有的建树/`depends` 语义保留，但产物从 HTML 占位页改为
   JSON（供 SPA 渲染导航），`depends.acl` 由 P3-6 真正执行。
4. **放弃 ucode/Lua 渲染路径**：不复刻 `.ut`/`.htm` 模板，不实现 ucode VM，不支持 `function`/`call`/
   `cbi`/`form` 的服务端动作，也不支持依赖 rpcd `.uc` 脚本的第三方 app（除非另行复刻，见 Follow-ups）。
5. 静态资源仍由 molly 的 `--docroot` 提供，所以**前端可以零后端改动先跑起来**（复用现有 `/ubus` 转发）。

## Options considered

- **A. 在 Odin 里实现 ucode 子集** —— 拒绝：等于重写一个语言 VM，且要求能跑任意 app 的 ucode 函数。
- **B. 渲染委托设备上的 `ucode` 二进制** —— 拒绝：引入运行时依赖、与「去掉 Lua/精简栈」的诉求背离，
  且渲染仍不由 molly 掌控。
- **C. API-first + 自研前端（本 ADR）** —— 采纳。
- **D. 用 Odin 复刻 `.ut` 骨架模板** —— 曾经的最优解（骨架只有十几个小文件），但在「自研前端」的前提下
  已无意义：界面由我们写，不需要任何上游模板。

## Consequences

- **更容易**：无 ucode、无 Lua、无模板引擎；前端可独立迭代；界面部署就是静态文件。
- **更难**：整个 UI 由我们负责（每个页面都要写）；菜单/ACL 必须做成 API；`luci` 对象里只有我们
  真正用到的子集需要实现（其余按需）。
- **接受的代价（逐条明确，不隐藏）**：
  1. **不再与 LuCI 页面兼容**（用户已确认「复刻界面」即可，不要求与上游像素一致）。
  2. 只装 ucode/Lua 页面、或依赖 rpcd `.uc` 脚本注册对象的第三方 app **不可用**，除非逐个复刻。
  3. `session`/`uci`/`file` 的 ubus 契约仍须与 rpcd 对齐（脚本与 app 的数据面在这里，不能自创）。
  4. Mithril 需 vendor（无 npm、无构建步骤）；升级方式 = 替换那一个文件并回写版本号。
- **对既有代码的影响**：`src/luci/render.odin` 的 HTML 占位页将退化为「菜单 JSON」；`dispatcher` 的
  路径解析从「页面路由」变成「菜单树查询」（SPA 自行路由）；`docs/interfaces.md`、`README.md`、
  `docs/architecture.md` 需同步（P3-8' 之后做）。

## Follow-ups

- [ ] P3-2…P3-7：`session` / `uci` / `file` / `luci` 对象 + ACL + SSE（API 面，纯 Odin）。
- [ ] P3-8'：SPA（HTML/CSS/Mithril）+ 菜单 JSON API + vendor `mithril.min.js`。
- [ ] 定义我们自己的 API 面（菜单 JSON、静态资源布局、错误形状），并在 `docs/interfaces.md` 登记。
- [ ] P4：应用覆盖清单 —— 哪些内置页面要复刻、哪些第三方 app（尤其 ddns/dockerman/tailscale 这类
      依赖 rpcd ucode 脚本的）明确不做。
