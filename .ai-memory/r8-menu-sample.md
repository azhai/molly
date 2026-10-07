# R8 离线抽样：真实 menu.d vs molly dispatcher

> 工作记忆（不提交）。方法、证据、结论。脚本：`.ai-memory/r8_sample.py`（统计）、`.ai-memory/r8_probe.py`（量化 + 合成探针实测）。

## 1. 抽样对象（与目标固件严格对齐）

`feeds.conf.default` 里 25.12.2 钉住的 luci 提交：

```
src-git luci https://github.com/immortalwrt/luci.git^d6167ea0645cbd1327708d85f94824f42d0eb872
```

取 `codeload.github.com/immortalwrt/luci/tar.gz/d6167ea…` → 全部 `*/root/usr/share/luci/menu.d/*.json` = **138 个文件 / 413 条路径**（`applications/` 应用菜单 + `modules/` + `protocols/`）。同一提交的 `modules/luci-base/ucode/dispatcher.uc` 作为语义基准。

样本里另有一条事实：`luci-app-filebrowser` 与 `luci-app-filebrowser-go` **都**装 `/usr/share/luci/menu.d/luci-app-filebrowser.json`（内容不同，ipk 层面互斥，实际只装一个）。抽样时按模块名区分保留两份。

## 2. R8 结论：**不成立，实现与上游一致**

`dispatcher.uc:400-402`（同一提交）：

```js
node.children ??= {};
node.children[s[0]] ??= { satisfied: true };   // ← 隐式中间层默认 satisfied
node = node.children[s[0]];
```

隐式中间层在上游就是 `satisfied: true`，所以「上游靠中间层 depends 不满足隐藏整枝」的假设错了：**中间层缺显式 spec 不会让上游隐藏该枝**，molly 的 `descend` + 默认 `satisfied = true` 与上游逐字一致。

真实样本里中间层缺显式 spec 的有 **8 例**（全部在 lxc / dockerman 的通配端点下）：

```
admin/services/lxc                        <-- admin/services/lxc/lxc_create/* 等 6 条
admin/services/dockerman/docker           <-- admin/services/dockerman/docker/events
admin/services/dockerman/container/archive<-- .../archive/put/* · .../archive/get/*
```

合成探针 `imp/a/b`（`imp`、`imp/a` 都无 spec）molly = 200，与上游语义一致。

## 3. 但同一段代码里发现 4 类**真实偏差**（8/11 探针不一致）

| # | 偏差 | 上游（行号） | molly 现状 | 真实样本影响 |
|---|---|---|---|---|
| D1 | schema 之外/类型不符时**丢弃整条 spec** | `:406-408` 只 `for k,t in schema if type 匹配 → node[k]=spec[k]`，逐键忽略 | `apply_spec` 遇任一不合法键即 `return`，整条消失 | **13 条路径**（`order` 写成 string 7 例：adblock/banip/dockerman/mwan3/travelmate/unbound/lorawan-basicstation；`title_hide` 4 例、`depends_comment` 1 例：dockerman `container/*` `network/*` 等、olsr） |
| D2 | `depends.fs` 语义错 | `:171-196` + `:279-292`：值可为 object 或 array；array = **任一备选**成立，object = **所有条目**成立，条目是 `路径 → 要求类型`（`file`/`executable`/`directory`/**`absent`**） | 把 fs 的键当路径、**任一存在**即满足；不看类型要求 | **41 条**（object 形式 35、array 6、含 `absent` 3）——`absent` 方向被**完全反过来** |
| D3 | `depends.uci` 语义错 | `:258-276` + `:294-307`：object = 所有 config 条目成立（`true` = 至少一个 section；object = 逐 section/option 精确匹配）；array = 任一备选 | 取 uci 对象的键，**任一** `uci_has(键)` 命中即满足 | **74 条**（其中 5 条取值是 object，需精确匹配 section/option） |
| D4 | 通配节点只有一个 action 字段 | `:410-414` 存 `wildcardaction`，`:1010-1011` **有剩余段时**改用它，否则用 `node.action` | 单字段，后处理的文件覆盖前者 | 真实样本 19 条通配路径；探针 `/wv` 实测 view=`wild-card`，上游应为 `wild-base` |

另有一条待定：`luci-app-sms-tool-js.json` **不是严格 JSON**（对象尾部多余逗号），ucode 的解析器是否容忍未验证；molly 用严格 `.JSON` → 整文件丢，**7 条路径**。真机可拿 ucode 验一次。

**受影响量级**：真实 413 条路径里 **117 条（28%）** 的「是否显示」或「用哪个 action」与上游不同。R8 本身的机制没问题，但 `satisfied` 的计算方式（D2/D3）和取 spec 的方式（D1/D4）偏差很大。

## 4. 取证方式

- 统计：`python3 .ai-memory/r8_sample.py /tmp/r8/menu.d`（schema 逐键核对、路径前缀分析、depends 形状分布）。
- 实测：`python3 .ai-memory/r8_probe.py` —— 落地 `/tmp/r8/probe.d` 合成菜单（每条偏差一个最小用例），起 `build/molly-host --menu-dir /tmp/r8/probe.d`，逐条 curl 比对「上游语义期望 vs molly 实测」，输出 `不一致条目: 8 / 11`。
- 上游行号与代码片段均来自 `d6167ea` 那一份 `dispatcher.uc`（本地解包在 `/tmp/r8/luci-d6167ea…/`，可复查）。

## 5. 建议的修法（按上游语义，一处一改）

1. `apply_spec`：白名单键逐键处理，类型不符只跳过该键，**不再** `return` 整条；`wildcard` 命中时 action 存到独立的 `wildcard_action_*` 字段（D1/D4）。
2. `check_depends` 重写：`fs`/`uci` 都按「array → 任一备选，object → 全部条目」；fs 条目按要求类型判定（`absent` = 必须不存在）；uci 条目按 `config` → `true`/object 判定（D2/D3）。
3. `uci_has` 之外要能判定「config 是否有 section」与「section.option == 值」，darwin 假配置要跟着扩（D3）。
4. 严格 JSON 保留还是容忍尾逗号：等真机拿 ucode 试过再定，先在计划里记为待验。
5. smoke 里那条 `白名单外的键整条丢弃 → 404` 是**按错误语义钉的**，要一并改成上游期望（200）。