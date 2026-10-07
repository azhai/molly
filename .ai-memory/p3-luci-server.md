# P3：把 rpcd 与渲染也接过来（molly 成为完整的服务端）

P2 已交付：HTTP/1.1、静态文件、`/ubus` 转发、dispatcher（菜单树 + `depends` 语义，对齐上游 `d6167ea`）。
P3 的目标是把**过渡期**去掉：molly 自己提供 `session` / `uci` / `file` / `luci` 四个 ubus 对象、
把入站 ACL 收到自己身上；**渲染交给设备上的 ucode**（复刻 LuCI2 的 uhttpd 接线，见 ADR
`.ai-agents/adr/0003-keep-ucode-faithful-luci2.md`）。完成后启动时不再打印 transitional WARN，
且不再依赖设备上的 rpcd（ucode dispatcher 仍在，它通过 ubus 调 molly 提供的对象）。

权威来源：本文件（P3 的计划 + 进展）。P2 的计划与全部历史在
`.ai-memory/p2-runtime-skeleton.md`（两者互为前后阶段，冲突时以本文件为准的是 P3 范围）。

## 0. 每个步骤的统一要求（用户要求：实现 / 测试 / 文档同步交付）

任何一步都必须按下面的顺序走，缺一项就不算完成：

1. **先取证**：拿到上游契约（源码 + 行号，或设备上 `ubus -v list` 的实测签名）写进「依据」，
   不允许凭印象实现协议。
2. **实现**：平台差异只出现在 `src/backend/{linux,darwin}.odin` 与 `bindings/`（架构规则见
   `docs/architecture.md` §5）。
3. **测试**：单元（`src/*/*_test.odin`，纯函数/判定）+ 接口（`tests/http_smoke.sh` 或新增的
   `tests/ubus_smoke.sh`）+ 集成（真 server）。覆盖面与判据写进 `docs/testing.md`。
4. **文档**：`docs/interfaces.md`（契约）+ `docs/architecture.md`（分层）+ `README.md`（阶段表）同步。
5. **门禁**：`./tests/unit.sh` → `./build.sh --host` → `./tests/http_smoke.sh` → `./build.sh --target`，
   数字回写本文件的进度表。**linux 侧新增代码必须在设备上跑一次**（见 §3）。

## 1. 前置取证（P3-0，先做，因为它同时闭合 P2 的遗留项）

设备已确认可达：**192.168.1.1**（ImmortalWrt 25.12.2 / aarch64_cortex-a53）。

| 取证项 | 命令 / 来源 | 用途 |
|---|---|---|
| 四个对象的精确签名 | 设备上 `ubus -v list session uci file luci` | P3-2…P3-5 的契约基准 |
| 行为 golden 样本 | 设备上按方法逐条 `ubus -v call …` 抓响应存档（放 `.ai-memory/golden/`） | 替换后的逐字段对比 |
| rpcd 上游源码 | `feeds.conf.default` 钉住的提交（`package/…/rpcd`）解包到 `/tmp` | 语义细节、错误码、ACL 判定顺序 |
| ACL 目录 | 设备 `/usr/share/rpcd/acl.d/*.json` + `/etc/config/rpcd` | P3-6 的自持 ACL |
| 设备库与 libc | `ls -l /usr/lib/lib{uci,ubus,ubox,blobmsg_json}.so*`、`/lib/ld-musl-aarch64.so.1` | 与 sysroot 一致性（P2 R1） |
| ucode 版本与容错 | `ucode -v`，并对 `luci-app-sms-tool-js.json`（对象尾逗号）实测一次 | 闭合 P2 的 `7 / 413` 剩余偏差 |
| 原厂 HTTP 行为 | 原厂 uhttpd 的 `curl -si` 抓包（headers/状态码/错误页） | HTTP 层契约校准（P2 风险 R7） |

### 已完成的取证（契约已钉死，设备侧 golden 仍待抓）

**源钉点**（ImmortalWrt 25.12.2 SDK 的 `feeds.conf.default` → 各仓提交）：

| 对象 | 权威源码 | 方法数 |
|---|---|---|
| `session` | `rpcd@e37ed9d814699098eb7e26c8b33c054840782dfb` 的 `session.c` | 10 |
| `uci` | 同上，`uci.c` | 15 |
| `file` | 同上，`file.c` | 8 |
| `rc` | 同上，`rc.c` | 2 |
| `rpc-sys` | 同上（`sys.c`） | 7 |
| `luci` | **不在 rpcd 仓**：`luci@d6167ea0645cbd1327708d85f94824f42d0eb872` 的 `libs/rpcd-mod-luci/src/luci.c` | 见该文件 |

源码已解包在 `/tmp/rpcd-src/rpcd-e37ed9d8…/`（`session.c`/`uci.c`/`file.c`/`rc.c`/`sys.c` +
`include/rpcd/session.h`）与 `/tmp/r8/luci-all/`。**每处实现的注释里都写上游行号**，
改语义前先回去看那一行（§0 规则 1）。

`session` 的关键常量与语义已落进 `docs/interfaces.md` §7：`RPC_SID_LEN 32`、默认超时 300s、
`/dev/urandom` 生 sid、ACL = `scope → (object, function)` 且用前缀 + `fnmatch` 匹配、
哨兵会话 `000…0` 不可销毁、`login` 依赖 `/etc/config/rpcd` 的 `config login` section
（默认 `root` + `$p$root` → `/etc/shadow`）。

**仍未取**（真机在线时一次做完）：`ubus -v list` 的签名与 golden 样本、`/etc/config/rpcd`、
`/usr/share/rpcd/acl.d/*.json` 的实际内容、设备库版本与 ucode 容错实测。

**同时要做的事**：把 P2 编好的 `build/molly` 部署到设备（**用 8081 端口与原厂 uhttpd 并行**，
不动原服务），跑 P2 第 7 步的验收：RSS 压测（连续请求后 `ps -o rss` 应收敛，目标 <2MB）、
`/ubus/list` 与 `ubus list -v` 对比、linux 侧 `uci_config_sections` 的运行期验证。

## 2. 分步实施计划（按依赖顺序）

### P3-1 R4 机制：专用 ubus/uloop 线程 + 探针对象 —— **已完成**（设备验收待做）
- **依据**：ADR `.ai-agents/adr/0001-ubus-uloop-thread.md`（含 sysroot 头文件与导出符号的实测核对）。
- **范围**：`bindings/uloop.odin`（`uloop_fd` 布局 + `uloop_init/fd_add/fd_delete/timeout_set/run_timeout/done`）+
  扩充 `bindings/ubus.odin`（`struct ubus_context` 前缀布局、`ubus_object`/`ubus_method`、`ubus_add_object`、
  `ubus_send_reply`、`ubus_complete_deferred_request`、`ubus_register_subscriber`、`ubus_send_event`）+
  `src/backend/ubus_server.odin`（linux：起线程、注册对象、`ubus_add_uloop` 的等价实现；darwin：假实现）
  + `main.odin` 启动时起该线程。先只注册一个探针对象 `molly.probe`（方法 `ping`）。
- **验收**：`./build.sh --target` 通过；设备上 `ubus -v list` 出现 `molly.probe`，
  `ubus -v call molly.probe ping '{}'` 返回预期 JSON；与原厂 rpcd 并存、不抢对象。
- **测试/文档**：`bindings` 的 `#assert` 尺寸/偏移断言；`docs/interfaces.md` 增「内部：ubus 服务线程」节。

### P3-2 `session` 对象 —— **已完成**（真实 `/etc/shadow`+`crypt` 路径待真机验证）
- **依据**：`session.c`（`rpcd@e37ed9d8`）逐方法对照；常量与语义摘要见 `docs/interfaces.md` §7。
- **范围**（已交付）：`src/backend/session.odin` —— 平台无关的十方法（`create`/`list`/`get`/`set`/
  `unset`/`destroy`/`access`/`grant`/`revoke`/`login`），含会话存储、`/dev/urandom` 生 sid、
  默认 300s 超时与惰性过期、ACL 前缀 + `fnmatch` 匹配、`login` 的 `/etc/config/rpcd`
  login-section 模型；`linux.odin` —— 注册对象（10 方法表）、blobmsg ⇄ JSON 桥、
  `$p$<user>` → `/etc/shadow` + `crypt()` 校验；`darwin.odin` —— 假 `rpcd` 配置 +
  替身密码校验 + 让 `/ubus/call/session` 走**真实现**（于是 macOS 上能端到端跑）。
- **关键设计**：会话数据（store / sid / data / acls）一律用**默认堆分配器**，不是每请求 arena。
  这是本轮抓到的两个真 bug（store 与 map 键变成悬垂）的根因；只有回复 JSON 用调用方 `alloc`。
- **验收**：macOS 上十方法端到端（状态码 2/3/4/6、`fnmatch` 通配、`access-group`、哨兵会话保护、
  `get(keys)` 过滤、`set`/`unset` 的无回复语义）；真机验收需先 `/etc/init.d/rpcd stop` 再接管。
- **测试/文档**：`src/backend/session_test.odin`（10 用例）+ `tests/http_smoke.sh` 的
  「P3-2 session 对象」节（13 项断言）；`docs/interfaces.md` §7 契约节（含 5 条已知偏离）。

### P3-3 `uci` 对象 —— **S1/S2/S3/S4 全部完成**（15 个方法齐全；**待真机验证**）

**契约（`uci.c`，1808 行；`include/rpcd/uci.h`）**

15 个方法（`uci.c:1766-1784` 的方法表，顺序即注册顺序）：

| # | 方法 | 入参（策略） | 备注 |
|---|---|---|---|
| 1 | `configs` | 无 | `rpc_uci_configs`（`:1382`） |
| 2 | `get` | `config`/`section`/`option`/`type`/`match` | `rpc_uci_get`（`:665`）→ `rpc_uci_getcommon`（`:601`） |
| 3 | `state` | 同 `get` | `rpc_uci_state`（`:673`），只读内存态（未提交的 delta） |
| 4 | `add` | `config`/`type`/`name`/`values` | `rpc_uci_add`（`:681`） |
| 5 | `set` | `config`/`section`/`type`/`match`/`values` | `rpc_uci_set`（`:875`）+ `rpc_uci_merge_set`（`:816`） |
| 6 | `delete` | `config`/`section`/`type`/`match`/`option`/`options[]` | `rpc_uci_delete`（`:1009`）+ `rpc_uci_merge_delete`（`:955`） |
| 7 | `rename` | `config`/`section`/`option`/`name` | `rpc_uci_rename`（`:1081`） |
| 8 | `order` | `config`/`sections[]` | `rpc_uci_order`（`:1132`） |
| 9 | `changes` | `config` | `rpc_uci_changes`（`:1225`）+ `rpc_uci_dump_change`（`:1189`） |
| 10 | `revert` | `config` | `rpc_uci_revert`（`:1366`） |
| 11 | `commit` | `config` | `rpc_uci_commit`（`:1374`）→ `rpc_uci_revert_commit`（`:1324`） |
| 12 | `apply` | `rollback?`(bool)/`timeout?`(int32) | `rpc_uci_apply`（`:1566`），60s 确认窗口 |
| 13 | `confirm` | 无 | `rpc_uci_confirm`（`:1654`） |
| 14 | `rollback` | 无 | `rpc_uci_rollback`（`:1686`） |
| 15 | `reload_config` | 无 | `rpc_uci_reload`（`:1721`） |

每个方法都还有一个隐藏入参 `ubus_rpc_session`（由 ubus/HTTP 层注入，与 P3-2 同机制）。

**关键常量与模型**（`include/rpcd/uci.h`）：

```
RPC_UCI_DIR           "/etc/config/"
RPC_UCI_DIR_PREFIX    "/var/run/rpcd"
RPC_UCI_SAVEDIR_PREFIX RPC_UCI_DIR_PREFIX "/uci-"      # 每会话一个 savedir
RPC_SNAPSHOT_FILES    RPC_UCI_DIR_PREFIX "/snapshot-files/"
RPC_SNAPSHOT_DELTA    RPC_UCI_DIR_PREFIX "/snapshot-delta/"
RPC_APPLY_TIMEOUT     60
```

- **每会话 savedir**：`rpc_uci_set_savedir(sid)`（`:289`）把 uci 的 savedir 指到
  `/var/run/rpcd/uci-<sid>`——改动以 delta 形式存在会话私有的 savedir 里，`commit` 才落盘，
  `revert` 丢弃。会话销毁时有回调 `rpc_uci_purge_savedir_cb`（`:1740`，注册于 `:1796`）清理它。
  这与 P3-2 的会话存储是**配套**的：P3-3 要用到 session 的「会话销毁回调 / 按 sid 存取」能力。
- **ACL 钩子**：`rpc_uci_read_access` / `rpc_uci_write_access`（`:311-337`）就是
  `session.access(scope="uci", object=<config 名>, function="read"/"write")`——**直接复用 P3-2 的
  ACL 引擎**（`session_acl_allowed`）。`sid` 缺失时不做访问控制（内部调用路径，`:315-316`）。
- **名称校验**：`rpc_uci_verify_str`（`:187-213`）——字母/数字/`_`，type 与扩展形式额外允许 `-`，
  扩展形式是 `@type[idx]`；三种入口 `verify_name` / `verify_type` / `verify_section`（`:218-235`）。
- **`apply` 系**：`apply` 把当前 delta 提交并起一个 60s（或 `timeout`）的 uloop 定时器 + 记录
  `apply_sid`；`confirm` 取消定时器；超时或 `rollback` 则回滚并触发 ubus 事件
  （`rpc_uci_trigger_event`，`:1304`）。这是本对象里唯一需要**定时器与事件**的部分。

**待补的取证**（实现每个方法前先读那一处，不许凭印象）：各方法的**回复形状**
（`rpc_uci_dump_section`/`_dump_package`/`_dump_change`/`_getcommon` 的 blob 结构、`configs` 的
数组形状、写操作的返回值）、`rpc_uci_lookup`（`:391-390`）的 ptr 语义与错误码映射
（`rpc_uci_status`，`:242`）、`match` 表的匹配语义（`rpc_uci_match_section`/`_match_option`，`:416-509`）。

**实现分片**（每片自带测试与文档）：

| 片 | 内容 | 依赖 |
|---|---|---|
| S1 ✅ | `configs` / `get` + 名称校验 + `match`/`type` 筛选（**已完成**）。`state` 移到 S2：它要 savedir 模型，跟前面的 `get` 不是一回事 | P3-2 的 ACL 引擎（读权限）✅ |
| S2 ✅ | savedir 模型 + `state` / `changes` / `revert` / `commit`（**已完成**）+ 会话销毁时清理 delta 目录。实现选择：**每会话一个短命 uci_context**（不碰私有的 `delta_path`；理由见 `docs/interfaces.md` §8.3 第 5 条） | libuci 的 `uci_unload`/`uci_commit`/`uci_revert`/`uci_set_savedir` 绑定 ✅ |
| S3 ✅ | 写操作 `add` / `set` / `delete` / `rename` / `order` **全部完成**：写计划层（`uci_write.odin`）+ 方法层（五个 `uci_method_*`）+ linux 写事务（`Uci_Write_Txn`：一次调用 = 建会话 ctx → load → 改 → save → unload，事务期间持 `g_lock`）+ 接线 + 绑定（含 `uci_reorder_section`）。darwin 侧只有方法层能跑（校验 2/6），provider 回 8。**唯一待办**：真机验证（备份 `/etc/config` 后用**副本**对 `uci` CLI 逐条比） | S2 的 savedir + 写权限 ACL ✅ |
| S4 ✅ | `apply` / `confirm` / `rollback` / `reload_config` 全部完成：快照目录（snapshot-files/delta）、`apply_sid` 门禁（pending 期间 commit/revert → 6）、60s 确认窗口与超时回滚、`reload_config` 的 fork+sleep(2)+execv。定时器用**自清理线程 + 代际号**代替 uloop_timeout（少一个结构体绑定，语义等价） | S3 ✅ |

**关键设计决策：darwin 侧的 uci 读写——已定（用户 2026-09-26）**
用户选择「**先只在 linux 上实现**」：不在 darwin 另做一份 uci 读写替身（不做文件后备的
fixture 存储）。落地方式：
- 平台无关的 `uci_object.odin` 只依赖**读**的 provider（`uci_config_sections` /
  `uci_list_configs`，两边都有：darwin 是 FAKE_UCI，linux 是真 libuci）。
- 写路径（S2/S3/S4）只在 linux 侧实现，darwin 侧永远回 `NOT_SUPPORTED(8)`。
后果与代价（已知并接受）：macOS 上只能断言到「回 8」，写操作的真实验证只能在设备上做；
好处是不必维护第二份 uci 语义（那份第二实现本身就可能与 libuci 漂移）。

**验收**：
- macOS：fixture 存储上的读写链路（delta → `changes` → `commit`/`revert` 的可观测差异）、
  ACL 钩子（无 `uci`/`<config>`/`read` 权限时被拒）、名称校验的非法输入。
- 设备：与 `uci` CLI 在同一份配置上逐条对照；**写操作只碰副本或可回滚的容器**
  （`/etc/config` 是设备的关键状态，绝不能在未备份时直接改）。

### P3-4 `file` 对象 —— **已完成**（8 方法全实现；真机 golden 待对比）
- **依据**：`file.c`（`rpcd@e37ed9d8`）逐行对照；契约见 `docs/interfaces.md` §9。
- **范围**（已交付）：`src/backend/file_object.odin` —— 路径核心三步
  （文本规范化 `file_canonicalize_path`（`file.c:189-248`，纯函数）→ ACL
  `session.access("file", <路径>, "read"/"write")`（`:180-187`，复用 P3-2 引擎）→
  **符号链接复查**（`file.c:261-359`：`realpath` 后对解析路径再查一遍 ACL，悬空链接 → 6））
  + `read`（`data`/`size`，`base64` 选项）。其余 7 方法（`write`/`list`/`lstat`/`stat`/
  `md5`/`remove`/`exec`）一律回 8。
- **接线**：darwin `/ubus/call/file` 路由 + linux `register_file_object`；
  `realpath` 绑定在 `bindings/libc.odin`（linux）/ `libc_darwin.odin`（darwin，需补
  `_XOPEN_SOURCE` 或直接声明）。
- **验收**：macOS 端到端（smoke 12 项）：授权内读、base64、符号链接指向授权外 → 6、
  悬空链接、`/tmp/../etc/hosts` 文本规范化后落授权外 → 6、未实现方法穷举 → 8。
  真机 golden 对比待做。
- **测试/文档**：`file_object_test.odin`（2 用例组：canonicalize 16 条折叠表 + ENOENT→4）；
  `docs/interfaces.md` §9。

### P3-5 `luci-rpc` 对象 —— **6 方法 + iwinfo 全部完成**（真机 golden 待对比）

**对象名是 `luci-rpc`**（不是 `luci`！`luci.c:2043`）——smoke 的透传探针打在假对象
`luci` 上，不受接管影响。6 方法（`luci.c:2033-2040`，源码
`luci@d6167ea` 的 `libs/rpcd-mod-luci/src/luci.c`，本地 `/tmp/r8/luci-all/`）：

| # | 方法 | 入参 | 依据 |
|---|---|---|---|
| 1 | `getNetworkDevices` | 无 | `:860`，getifaddrs + /sys/class/net |
| 2 | `getWirelessDevices` | 无 | `:1174`，iwinfo |
| 3 | `getHostHints` | 无 | `:1253+`，netlink + /etc/ethers + 租约 + getifaddrs + uci 静态租约 |
| 4 | `getDUIDHints` | 无 | 租约里的 DUID |
| 5 | `getBoardJSON` | 无 | `blobmsg_add_json_from_file("/etc/board.json")`，失败 → 9 |
| 6 | `getDHCPLeases` | `family?`（int32：0/4/6，其它 → 2） | `:1937+` |

**getDHCPLeases 契约**：
- leasefile 发现（`luci.c:394-473`）：uci `dhcp` config 里 `dnsmasq` section 的 `leasefile`
  option；没有 → 回退 `/tmp/dhcp.leases`；`odhcpd` section 同理 → `/tmp/odhcpd.leases`。
  打不开的文件跳过。
- **dnsmasq 行格式**（`:561-634`）：`ts mac ip hostname clientid`——ts>now → 剩余秒，
  >0 → 0，**==0 → -1（永久）**；ip 先试 v6 再试 v4，都不是跳行；`!mac && af==v4` 跳行
  （v6 无 MAC 合法）；hostname/duid 字段**必须都在**（`*` → 缺省）；v4 的 clientid：
  `ff:` 开头且长 → `ff:<iaid>:<duid>` 拆分、`01:` 开头且长 20 → MAC、`*` → 缺省、
  否则去冒号。
- **odhcpd 行格式**（`:489-560`）：`# iface duid_or_mac iaid_or_"ipv4" name ts id length addr/…`——
  iaid=="ipv4" → v4 + MAC 来自第二字段；否则 v6 + duid/iaid 保留；ts>=0 → 0（注意与
  dnsmasq 的 `>0` 不同，0 是过期不是永久）；`length` 非 0 覆盖 mask；地址按 `/` 和空白切。
- **回复**：`{"dhcp_leases":[…]}` / `{"dhcp6_leases":[…]}`（family=0 两个键都有；4/6 只给
  对应键）。每条按序：`expires`（-1 → u8 0！与过期同形）、`interface?`、`hostname?`、
  `macaddr?`、`duid?`、`iaid?`、`ipaddr`/`ip6addr`（**只回第一个地址**，`:2000`）。
- `duid2ea`（`:296-330`）：全 hex 字符串；len 28 且前缀 `00010001` → 偏移 16 的 6 字节；
  len 20 且前缀 `00030001` → 偏移 8；否则 NULL。
- **无 ACL 检查**（两个 policy 都没有 session 字段，handler 也不查）。

**分片**：
| 片 | 内容 | 依赖 |
|---|---|---|
| S1 | 接线（`luci-rpc` 注册/路由）+ `getBoardJSON` + `getDHCPLeases`（纯解析函数可单测） | uci 的读 provider（leasefile 发现）、board.json 路径 provider |
| S2a ✅ | `getDUIDHints`（**已完成**）——纯租约解析，可移植，darwin 也能端到端测 | S1 的 leasefile 发现/解析 ✅ |
| S2b ✅ | `getNetworkDevices`（**已完成**，linux-only）：sysfs 全字段 + getifaddrs 绑定（`bindings/libc.odin`）。**iwinfo 字段未做**（上游 dlopen 可选，无线设备的 golden 会缺 hwmodes/crypto 等，S2b′ 补）；darwin 回 8。**待真机验证** | getifaddrs/freeifaddrs 绑定 ✅ |
| S2c ✅ | `getWirelessDevices`（**已完成**）：同步 `ubus_invoke`（`bindings.ubus_invoke_fd`，早就绑好了）+ 重塑（跳过 netifd 的 iwinfo、interfaces 逐表去 iwinfo）+ **iwinfo（S2b′/S2c′ 已实现）**：dlopen libiwinfo、接口级与 radio 级两次取字段 | ubus_invoke_fd ✅；dlfcn ✅ |
| S2b′/S2c′ ✅ | **iwinfo**（`src/backend/iwinfo.odin`）：按 iwinfo master 的 `include/iwinfo.h` 对齐 `struct iwinfo_ops`（含 center_chan1/2、mbssid_support、htmode、phyname…）+ 六张名字表；**两层失效保护**（ops.name 白名单 + hwmodes/mode 范围检查）保证布局/版本不符时**不吐垃圾**，只当作「没装 iwinfo」 | dlfcn（`core:sys/posix`）✅ |

**注意（更正）**：iwinfo **只在 `getWirelessDevices` 里用**（luci.c:1150/1163），
`getNetworkDevices` 不调它——之前把 S2b′ 记到 getNetworkDevices 名下是错的。
| S2d ✅ | `getHostHints`（**已完成**）：五源按优先级合并 + rrdns 补主机名；netlink 用**裸 socket**（不引 libnl）。顺带**修正 S2b 的 sockaddr_ll 偏移错误**（把 sll_protocol 当 hatype、ifindex 取错位——真实布局 family 0-1/protocol 2-3/ifindex 4-7/hatype 8-9/pkttype 10/halen 11/addr 12-19） | 裸 netlink ✅；linux-only |

**设计决策**：board.json 路径做成 provider（linux `/etc/board.json`，darwin
`tests/fixtures/board.json`）；darwin 的 FAKE_UCI 加 `dhcp` config（leasefile 指向
/tmp 固定路径，测试自己写租约文件）。


### P3-6 ACL：自持 `/usr/share/rpcd/acl.d/*.json` —— **已完成**（S1 + S2 + dispatcher 裁树）
- **依据**：设备 ACL 文件 + rpcd 上游判定（`session.c` 的 `rpc_login_setup_acls` 与匹配引擎）
  + 上游 uhttpd `ubus.c` 的 `uh_ubus_allowed`（前置校验）。契约见 `docs/interfaces.md` §11。
- **已交付 S1（加载与匹配）**：`session.odin` 的 `session_load_acls` —— glob `session_acl_dir()/*.json`
  （linux `/usr/share/rpcd/acl.d`，darwin `tests/fixtures/acl.d/`）；按 login section 的 `read`/`write`
  组列表加载（`fnmatch`、`!` 取反、write 蕴含 read）；默认/哨兵会话只吃 `unauthenticated`；
  acl.d 的**表形态**（`"ubus": {"file": ["list"]}`）与**数组形态**（`"uci": ["system"]`）都要认；
  `access-group` 元 scope 照样授。
- **已交付 S2（前置校验）**：`ubus_http.odin` 的 `invoke` —— 对象查找 `-32000` → ACL `-32002`
  → 参数 `-32602`（上游 uhttpd 顺序）；判定委托 `backend.session_access_ubus`（scope `"ubus"`，
  object=对象名、function=方法名）；**fail-closed**（查不到 sid 一律拒）。
- **已交付 S3（dispatcher 裁树与只读）**：`menu.odin` 不再把 `depends.acl` 只当展示——组名在
  建树时解析进 `Node.acl_groups`（数组/对象/裸串三种形态都认），判定**每请求按 sid 现算**
  （`node_visible` / `node_acl_missing` + `backend.session_acl_level` 的三态）；缺组 → 节点不可见
  （路径 404、firstchild 跳过），只有 read → 页面标只读。会话来自 LuCI 的 cookie
  （`sysauth_http`/`sysauth_https`，`cgi_luci.odin` 里解析）。占位页的「ACL 未实施」横幅已删，
  改为按需打只读提示 + `<dt>readonly</dt>` 行。**树是跨请求缓存的，所以判定不写回节点**——
  这是与上游 `apply_tree_acls` 唯一的实现差异（可观测行为一致）。
- **已交付 S3b（无会话 → 403 + 登录提示，2026-09-27）**：真实 menu.d 里 `admin` 标了 `auth.login`。
  无会话时上游会把 ACL 缺组的后代也放行进 firstchild 竞选（`resolve_firstchild:593`），最终回
  **403 + `X-LuCI-Login-Required: yes` + 登录页**（`:930-960`）。molly 现在照做：
  `Node` 解析 `auth`（`has_auth`/`auth_login`，按上游 `:406-408` 的条件拷贝语义）；
  `Auth_State` 同时表达「`ctx.auth` 最后者胜」与「firstchild 的 login 模式粘滞」；
  `first_child` 带 login 放行（只豁免 ACL 缺组，`satisfied` 照旧要过）；`dispatch` 在解析前与
  下钻后各判一次、**先判登录再判 404**（与上游顺序一致）；`cgi_luci.odin` 回 403 +
  `X-LuCI-Login-Required: yes` + `render_login_required` 提示页（含请求路径与取 sid 的办法）。
  内置 dispatcher 仍**不渲染登录表单**（那是 `--luci-cgi` 的 ucode 侧），偏离因此只剩正文
  （`docs/interfaces.md` §11.5 第 2 条已改口）。
- **验收**：无权限调用被 `-32002` 拒、对象不存在优先 `-32000`、会话销毁后 fail-closed；
  dispatcher：无 cookie → **403 + `X-LuCI-Login-Required: yes` + 提示页**、哨兵会话（有会话但
  缺组）→ 404、只读会话 → 200 + `readonly=yes`、撤销 write 后 firstchild 恢复该节点。
- **测试/文档**：`session_test.odin` 3 用例（组判定 / acl.d 两形态 / 哨兵）；
  `menu_test.odin` 5 用例（裁树与只读、firstchild 跳过与恢复、无会话→登录提示、有会话照常+缺组 404、
  `ctx.auth` 最后者胜与 `auth` 类型不符整键忽略）；
  fixture `tests/fixtures/acl.d/`（含**测试专用**的 `smoke-full.json`，真机不存在）；
  `tests/fixtures/menu.d/luci-base.json` 的 `admin` 补 `auth.login`（与设备真实文件同形）。
- **泄漏已清（2026-09-26）**：`./tests/unit.sh` 四个包全 `ok` 且 **0 条 `leak` 警告**。
  根因是三类「隐式 `context.allocator`」：从 map 取出的零值 `[dynamic]T` 上 `append`、
  往零值 `map`（`json.Object{}`）里插入、不带分配器的 `strings.clone`/`join`——
  在设备上是**每请求泄漏**（详见 `docs/testing.md` §2 的「写用例时别踩的坑」）。
- **同时修掉一个假的绿灯**：`test_session_acl_grant_revoke_access` 曾真失败——darwin fixture
  的 root login 列了 `read/write = '*'`（与真机 `rpcd.config` 一致），P3-6 起 acl.d 全量加载，
  于是**测试专用的 `smoke-full` 组**（`ubus: *`）让任何 `access` 都成了 `true`。
  该用例改为自建会话 + 只按 luci-base 的窄列表加载 acl.d；坑记进 `interfaces.md` §11.4 第 5 条。

### P3-7 `/ubus/subscribe`（SSE）—— **S1 已完成**（S2 的 linux 真订阅待做）
- **依据**：`/tmp/uhttpd-ubus.c:373-424` 的 `uh_ubus_handle_get_subscribe`（ACL 点是伪方法
  `:subscribe`；不过回 `{"code":-13}`；成功回 `text/event-stream`；帧 `event: <m>\ndata: <j>\n\n`）
  + ADR 0001 的 pipe 方案。契约见 `docs/interfaces.md` §4.7。
- **已交付 S1（协议 + 总线 + darwin 端到端）**：
  - `src/backend/event_bus.odin`（平台无关）：每条订阅一根管道（写端给事件源、读端给 HTTP
    线程），`event_bus_subscribe/unsubscribe/publish`；上限 32（与并发连接上限对齐）；
    写端非阻塞，满了**丢事件**而不是卡死 ubus 线程。
  - `src/handlers/ubus_sse.odin`：`GET /ubus/subscribe/<path>` —— ACL `:subscribe` → 对象存在性
    → 订阅 → 200 + `text/event-stream` → poll 管道发帧，30s 一条心跳注释帧，断开即注销。
  - darwin 的假事件源：`molly.probe` 的 `emit`（**测试专用**，真机没有）往总线推一条通知，
    于是 SSE 这条链路在 macOS 上能被端到端驱动。
- **已交付 S2（linux 真订阅）**：
  - 布局证据：`/Users/ryan/openwrt-sdks/src/ubus/libubus.h:145-152`（`list_head 16 +
    ubus_object 120 + 三个回调 24 = 160`，`obj` 在 +16）；`avl_node = 56`（avl.h:56-95，
    与 `Ubus_Object` 里既有的 `[56]byte` 对上）。`bindings/ubus.odin` 加了
    `Ubus_Subscriber` + 两条 `#assert`。
  - **一个坑**：`ubus_unregister_subscriber` 是 `static inline`（`libubus.h:329-335`），
    .so 里没有符号——链接期才暴露（`ld.lld: undefined symbol`）。按源码复刻成
    `list_empty? → list_del_init` + `ubus_remove_object`。
  - **另一个坑**：通知回调是 `proc "c"`，**没有 context、不能分配**，所以回调里只把
    `(path, method, json)` 搬进定长环形槽（16 槽，满了丢），由 ubus 线程主循环排空
    并 `event_bus_publish`。
  - 命令方向：HTTP 线程往 `g_sse_cmds` 排 `Start/Stop`，ubus 线程在
    `uloop_run_timeout(SSE_LOOP_POLL_MS=100)` 的间隙排空（不再用 -1 死等）。
    按 **path** 一个 subscriber（上游是每条连接一个），发布本来就是按 path 匹配的。
- **待做**：真机验证（`/ubus/subscribe` 收到设备上真实对象的通知；`ubus -v list` 后
  用 `ubus call` 触发 notify 看帧）。交叉编译已过，`#assert` 不等于运行期正确。
- **验收（已做）**：哨兵订阅被 `{"code":-13}` 拒、授权会话拿到 `text/event-stream`、
  未知对象回 `{"code":4}`、假事件源推一条后 SSE 收到 `event: emit` 与 `data:` 帧（smoke 7 项）。
- **测试/文档**：`src/handlers/sse_test.odin`（分帧 + 拆记录 2 用例）；smoke 新增「/ubus/subscribe（SSE）」节；
  `interfaces.md` §4.7（含五条实现差异表）、`testing.md`、`README.md`、`architecture.md` §8 同步。

### P3-8″ 渲染交给 ucode（复刻 LuCI2 的接线）—— **路线已定（ADR 0003），待实现**
用户 2026-09-26 决定：**保留 ucode**，参考 LuCI2 实现，**先复刻、将来再重构简化**（自研 Mithril 前端的
ADR 0002 已作废）。

- **T1（先做）**：molly 承接 `/cgi-bin/luci`，按 CGI 规范构造环境（`SCRIPT_NAME` / `PATH_INFO` /
  `REQUEST_METHOD` / `QUERY_STRING` / `CONTENT_LENGTH` / `CONTENT_TYPE` / `HTTP_*`），以子进程执行
  `/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc`，把 stdout 流回响应。等价于上游 CGI 兜底形态
  （`modules/luci-base/htdocs/cgi-bin/luci` 就是 `#!/usr/bin/env ucode` + `dispatch(request(getenv(), read, write))`），
  **零新增 C 绑定**。
- **T2（后续可选）**：绑定 `libucode` VM 把 `uhttpd.uc` 跑在同一进程，自己实现 `uhttpd.recv/send` ——
  这才是 uhttpd `ucode_prefix` 的进程内形态；等 T1 跑通、实测 fork 开销与 RSS 后再定。
- **验收**：`GET /cgi-bin/luci/` 与原厂 uhttpd 的响应逐字节/逐头对比（golden）；登录、菜单、页面可用；
  `template`（Lua）那 6 条要么补成 `.ut`、要么明确不支持。
- **接线依据**：`luci-base/Makefile:47-48` 的 `uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'`；
  依赖包 `ucode` + `ucode-mod-{fs,log,uci,ubus,math,html}` + `liblucihttp-ucode` + `rpcd-mod-ucode` + `cgi-io`。
- **连带影响**：`src/luci`（Odin dispatcher）**离开请求路径**，但保留为「将来去 ucode」的对照实现与
  回归基准；`docs/architecture.md` 与 `docs/interfaces.md` 要标注它的当前状态与两种模式的启用条件。
**真实样本的 action.type 分布**（138 文件 / 413 路径，提交 `d6167ea`，2026-09-26 实测统计）：
`view` 311、`firstchild` 43（中间层，已实现）、`function` 31、`alias` 21（已实现）、`template` 6、`call` 1。
**每种非 view 在上游怎么渲染**（`dispatcher.uc` 的 `run_action`）：

| action.type | 上游实现 | 行号 | molly 现状 |
|---|---|---|---|
| `view` | `runtime.render('view', { view: action.path })` —— 渲染 ucode 视图模板 | :804-806 | 200 占位页（P2 决策 6） |
| `function` | `require(action.module)` + 调该模块导出的 **ucode 函数** | :817-829 | 501 |
| `call` | `runtime.call(action.module, action.function, …)` | :808-815 | 501 |
| `template` | `runtime.call('luci.dispatcher', 'render_lua_template', …)` —— **Lua** 模板 | :795-802 | 501 |
| `cbi` / `form` | `invoke_cbi_action` / `invoke_form_action`（ucode 模块） | :831-847 | 501 |
| `alias` | 按 `action.path` 重新 dispatch | :849-851 | 已实现 |
| `firstchild` | `resolve_firstchild`（纯权重竞选，**不读** `preferred`/`recurse`） | :582-624 | 已实现（并列时按段名定序，见 `architecture.md` §7） |

**结论：349 / 413 条路径的渲染都要 ucode（或 Lua），纯 Odin 复刻等于重写一个 ucode 解释器。**
但这不重要了——**用户 2026-09-26 已定路线**（ADR `0002-api-first-own-web-ui.md`）：

> 新版本**只提供 API**；Web 界面用 HTML/JS/CSS **自行复刻**，JS 用 **Mithril.js**。

于是渲染这一块从「复刻上游」变成「不涉及」：不实现 ucode VM、不复刻 `.ut`/`.htm`、不做
`function`/`call`/`cbi`/`form` 的服务端动作。兼容面收窄为 **ubus 契约 + HTTP API**。

补充取证（供后续参考，不再驱动决策）：

- `view` 的服务端产物只有 12 行骨架（`ucode/template/view.ut`），页面主体本来就在浏览器渲染：
  `L.require('ui').then(ui => ui.instantiateView('{{ view }}'))`；视图资源是浏览器 JS
  （`rpc.declare({ object: 'luci', method: … })` → 经 `/ubus` 取数据）。
- Lua 只是**回落路径**（`runtime.uc:68-71` / `render_any` :118-129；`dispatcher.uc:795-802` 的
  `template` 动作直接走 `render_lua_template`）；仓库存量 228 个 `.lua`、153 个 `.htm`，都在
  legacy app 的 `luasrc/` 下。
- `preferred`（3 例）/`recurse`（10 例）**上游 `resolve_firstchild` 根本不读**（逐行核对 :582-624），
  molly 忽略它们不是偏差，不必改。
- **明确不做的（避免以后被当成 bug）**：只装 ucode/Lua 页面的第三方 app；依赖
  `/usr/share/rpcd/ucode/*.uc` 脚本注册对象的 app（ddns / docker_rpc / tailscale / wifihistory / example）。
  要支持就必须逐个复刻，列入 P4 清单。

### P3-9 收尾 —— **代码/文档侧已完成**（真机项待跑）
- **已交付（2026-09-27）**：
  1. **transitional 模式移除**：删掉 `src/main.odin` 里无条件打印的
     `WARN: transitional mode …`（它与「molly 已自持对象」自相矛盾；设备上 rpcd 占位时
     由 ubus 线程**逐对象**打诊断，那条是事实陈述）。占位页横幅已在 P3-6 收尾删掉。
  2. **文档全面改口**：`README.md`（过渡期提示 → **接管步骤** + P3-9 行）、
     `docs/architecture.md` §8（过渡期已成历史）、`docs/interfaces.md` §2.1、
     `docs/build-and-run.md`（启动输出样本）、`AGENTS.md`（「安全提示」那节的例子换掉）。
  3. **真机验收脚本**（P3 一直缺的「每步在设备上跑一次」载体）：
     - `tests/golden.sh`：`device`（ssh 抓 rpcd 的签名/10 条只读探针/acl.d/rpcd.conf/库版本/
       原厂 uhttpd 的 HTTP 样本）→ `molly`（同一批探针打 molly）→ `compare`
       （**先归一化 key 顺序再逐字段 diff**，避免 blobmsg 插入序 vs map 遍历序的假差异）。
       molly 侧的 HTTP 样本写 `http-molly/`（2026-09-27 修：原先与原厂样本同目录，会把
       R7 的校准物覆盖掉，而 `compare` 并不比 HTTP，覆盖后无从查证）。
     - `tests/device_smoke.sh`：设备上一把跑 —— `molly.probe` 在 `ubus list` 里、
       四对象、HTTP 面与 P3-6 的 `-32002`/404 边界、**真实 `/etc/shadow`+`crypt` 登录**、
       uci 写路径（**只碰自建的 `/etc/config/mollytest`**，跑完删）、`/ubus/subscribe` 真收帧、
       可选 golden 对比与 RSS 观察。
  4. **编译器警告清零**（2026-09-27）：`uci_apply.odin` 的 `import "core:runtime"` →
     `"base:runtime"`（其余用 runtime 的文件早已迁移，只漏了这一处）。两端编译与全套门禁复跑过。
  5. **真机 SSE 的触发源**：`molly.probe` 加 `notify` 方法（linux = `ubus_notify`，
     darwin = 直接推事件总线，两平台**同一命令** `ubus call molly.probe notify`），
     于是 P3-7 在设备上也能验收；smoke 里那条假 `emit` 一并改名统一。
  6. **linux-only 路径的分配审计**（2026-09-27 追补，见下面的会话记录）：ubus 的四个 handler
     原先把**默认（堆）分配器**当请求 arena 用，每次调用漏整份回复（设备上 RSS 会单调上涨）；
     SSE 命令/订阅的克隆串没释放、`event_bus` 的分配与释放用了不同分配器（UB）——都已修。
     这一类的根因与判据写进了 `docs/testing.md` §2、契约写进 `docs/architecture.md` §4。
- **待做（要设备在线）**：`./tests/golden.sh device <host>` → `/etc/init.d/rpcd stop` +
  重启 molly → `./tests/golden.sh molly <url>` → `compare`；跑 `./tests/device_smoke.sh --pass …`；
  RSS 曲线与并发压测（**这一项现在是分配审计的验收判据**：改动前 baseline 会单调上涨，
  修完后应平稳）；然后输出 P4（若有）清单。
- **已知但故意不修**：`uci_apply.odin` 的 `g_uci_apply_sid` 每轮 apply 克隆一串（store 分配器）、
  窗口结束时只置空不释放（约 36B/次 apply，且有「被新 apply 顶掉」的路径同样丢指针）。
  **不修**是因为 apply 定时器线程**可能正在读**它：释放就会变成 UAF。要修得先给这一对读写
  加同步——现在的「代际号」只保证取消之后不再**进入**，挡不住已经进去的那一次。
- **P3-8″-T2（内嵌 libucode）**：仍待评估，判据是设备上的 fork 开销与 RSS 实测——没有数据前不动。

## 3. 验证边界（必须知道）

- **darwin 侧**：所有共享逻辑（HTTP、dispatcher、ACL 判定、blobmsg ⇄ JSON）在 macOS 上跑真代码，
  只把 ubus/uci 换成假数据 —— 单元测试与 `http_smoke.sh` 覆盖的就是这一层。
- **linux 侧**：只能 `./build.sh --target` 编译 + 链接校验；`#assert` 保证结构体尺寸/偏移，**不保证**
  libubus/uloop 的运行期行为。每个 P3 步骤的验收都包含「在 192.168.1.1 上跑一次」，这一步不能省。
- **不能只靠 golden 对比**：golden 只覆盖抓过样本的输入；新写的错误分支要有独立的错误用例。

## 4. 进度表

| 步骤 | 状态 | 最近一次门禁/设备实测 |
|---|---|---|
| P3-0 取证 | 进行中（**契约已全部钉死**；设备侧签名/ACL/golden 待抓） | 六对象源码钉点：`rpcd@e37ed9d8`（session/uci/file/rc/sys）+ `luci@d6167ea`（rpcd-mod-luci）；源码在 `/tmp/rpcd-src/`、`/tmp/r8/luci-all/` |
| P3-1 R4 机制 + 探针对象 | **已完成**（**设备验收达成**：molly 跑在设备上时 `ubus list` 出现 `molly.probe`，四对象注册被 rpcd 占位挡住 → 逐对象诊断按预期打印） | ADR 0001；绑定与线程已落地 |
| P3-1a dispatcher 501 可诊断化 | 已完成 | 501 正文改为 `not implemented: action.type=… view=… menu=…`；smoke 通过 129 失败 0 |
| P3-2 `session` | **已完成**（真实 `/etc/shadow`+`crypt` 路径待真机；ACL 来源已由 P3-6 补上） | unit 4 包 31 用例；http_smoke 通过 146 失败 0；十方法端到端含状态码 2/3/4/6 |
| P3-3 `uci` | **S1/S2/S3/S4 全部完成**（15 个方法；写路径与 apply 系待真机验证） | unit 4 包 47 用例（backend 26）；http_smoke 通过 191 失败 0；host 1,076,296B / target 397,776B |
| P3-4 `file` | **已完成**（8 方法全实现；真机 golden 待对比） | unit 4 包 51 用例（backend 30）；http_smoke 通过 222 失败 0；host 1,154,632B / target 427,600B |
| P3-5 `luci-rpc` | **6 方法 + iwinfo 全部完成**（3 个 linux-only 待真机验证） | unit 4 包 58 用例（backend 37）；http_smoke 通过 239 失败 0；host 1,178,184B / target 491,936B |
| P3-6 ACL | **已完成**（acl.d 加载 + `/ubus` 前置校验 + dispatcher 的 `depends.acl` 裁树与只读 + **无会话 → 403 + 登录提示**；真机 golden 待对比） | unit 4 包 68 用例（luci 18 / backend 40）**全 ok、0 leak**；http_smoke 通过 265 失败 0；cgi_smoke 通过 30 失败 0；host 1,214,920B / target 508,880B |
| P3-7 SSE | **已完成**（协议 + 事件总线 + linux 真 ubus 订阅 + darwin 端到端；真机验证待做） | unit 4 包 65 用例（handlers 6）**全 ok、0 leak**；http_smoke 通过 259 失败 0；cgi_smoke 通过 30 失败 0；host 1,214,952B / target 506,304B |
| P3-8″-T1 ucode 接线（子进程 CGI） | **已完成**（待设备 golden 对比） | unit 4 包 23 用例；cgi_smoke 通过 30 失败 0；host 914,680B、target 330,192B |
| P3-8″-T2 内嵌 libucode | 待评估（按 fork 开销与 RSS 实测） | — |
| P3-9 收尾 | **代码/文档侧已完成**（transitional 移除 + 真机验收脚本 + linux-only 分配审计 + 段错误修复；真机项待跑） | unit 4 包 68 用例（handlers 6）全 ok、0 leak；http_smoke 265/0；cgi_smoke 31/0；host 1,215,320B / target 509,728B；`tests/golden.sh` 与 `tests/device_smoke.sh` 语法与用法自测过 |

会话记录（新在前）：
- 2026-09-27 — **设备段错误（SIGSEGV）定位与修复：四个 linux handler 的 `params` use-after-free**。
  1. 现场：用户贴的设备日志在 6 行 `[molly-debug] session params=… method=…` 之后直接
     `Segmentation fault`，最后一行是没有落盘的**下一次**调用（`…"object":"uci","function":"get"}`）。
  2. 取证：用 `GOSYMS=1` 的符号版在设备上复现（第 1 轮即 `退出码=139`），拿回 13.8MB 的 aarch64 core。
     `lldb -c core build/molly` 得 `pc=0x7f88b60640` → `/lib/libc.so+0x13640` = **`memcpy+0x90`**
     （故障指令 `ldp x6, x7, [x1]`，`x1` 未映射、`x2=x3=0x57`）；`lr` 落在 `molly`bufio::_writer_proc+492`；
     栈扫描认出 `fmt::fmt_string` → `bufio::_writer_proc` → `memcpy`，以及 `os::file_io_stream_proc` + `os.files`（stderr）
     → 崩溃点就是 handler 入口的 `fmt.eprintfln(… %s …, params)`。
     长度对账：`{"ubus_rpc_session":"…","object":"uci","function":"get"}` = **87** 字节，与 memcpy 的 `0x57` 精确吻合。
  3. 根因：`js := blobmsg_format_json(msg, true)` 是 malloc 串，原本写成
     `if js != nil { defer c_free(js); params = string(js) }`；**Odin 的 `defer` 是块作用域**，
     在 `if` 结束即执行 `c_free`，`params` 从此悬垂；下一次打印把 87 字节悬垂数据拷进栈缓冲即崩。
     这也解释了「加插桩就不复现」——额外打印改变了堆布局，掩盖了该块被 unmap 的时机。
  4. 修复：`src/backend/linux.odin` 四处（`session_handler` / `uci_handler` / `file_handler` / `luci-rpc handler`）
     改为 `params = strings.clone(string(js), alloc)` 后再 `bindings.c_free(rawptr(js))`，
     即先克隆进**请求 arena** 再释放——与 `luci-rpc` 两个回调（`:2279` / `:2898`）的既有正确写法一致。
     同时删除本会话 4 处 `[molly-debug]` 插桩与 `session.odin` 的 A1-A4 临时打印。
  5. 验证：去插桩最终版在设备上跑 15 轮 × 30 次 × 5 调用全存活、`/tmp/*.core` 为空；
     同一脚本在修复前第 1 轮即 139。门禁：unit 4 包 68 用例全 ok、0 leak；host 1,215,320B；
     http_smoke 265/0；**target 509,728B**。**教训**：`defer` 写进 `if`/循环体内只在该块存活期内有效，
     「克隆进请求 arena」是本仓库处理 libc 返回串的固定姿势。
- 2026-09-27 — **复跑门禁抓出一处编译期回归并修复**。`src/main.odin` 的 `USAGE` 是反引号原始字符串字面量，
  P3-9 改这段帮助文本时，第 34 行 `` `#!/usr/bin/env ucode` `` 与第 37 行 `` `{%` `` 两处嵌入的反引号
  提前闭合了外层原始字符串，导致后面的中文被当代码解析，`host` 编译在 `main.odin:35` 报
  `Illegal character: ， (65292)`。删掉这两处内嵌反引号（换成单引号 / 裸 `{%`）后，`--host` 重新通过，
  全套门禁复跑全绿：unit 4 包 68 用例 0 leak、http_smoke 265/0、cgi_smoke 31/0、
  host 1,215,352B、target 509,360B。**教训**：原始字符串字面量里不能出现反引号，
  之后改 `USAGE` 这类帮助文本要避开 `` ` ``（用单引号或中文引号替代）。
- 2026-09-27 — **P3-6 收尾之二：无会话 → 403 + 登录提示（把上游的 `auth.login` 语义补进内置 dispatcher）**。
  1. 起因：用户在设备上「总是 404，看不到任何页面」。定位到两条叠加：P3-6 起菜单按会话 ACL 裁树
     （没有 cookie 就是无会话 → 真实 menu.d 的叶子全带 `depends.acl` → 整站不可见），而内置
     dispatcher 不像上游那样渲染登录页（`interfaces.md` §11.5 第 2 条的已知偏离）。
  2. 取证上游：`resolve_page:632-671`（沿途 `ctx.auth = node.auth || ctx.auth`，**最后者胜**）、
     `resolve_firstchild:582-624`（`login = !session && (login_allowed || child.auth?.login)`，
     命中就把 ACL 缺组的子节点也放进竞选）、`:927-961`（无会话 + `ctx.auth.login` → 先拿表单凭据试
     登录，失败则 **403 + `X-LuCI-Login-Required: yes` + 主题登录表单**）。注意状态码是 **403**，
     不是 200；`apply_tree_acls:435-445` 才是把 acl 折进 `satisfied` 的那一半。
  3. 实现：`menu.odin` 解析 `auth`（`has_auth`/`auth_login`，遵循上游 `:406-408` 的「类型匹配才拷、
     缺键不清空」）、新增 `Auth_State`（最后者胜 + login 模式粘滞，两个字段不能合并——
     `/admin/uci/apply_rollback` 自带的 auth 没有 login，必须把 `admin` 的顶掉）、
     `node_visible(n, sid, login)`、`first_child` 加 login 放行与当选支路的 auth 归并、
     `resolve` 沿途聚 auth（下降失败也带回，因为「被 ACL 截断」正是要判登录的形态）；
     `render.odin` 新增 `Kind.Login_Required` + `render_login_required`（正文含请求路径与
     取 sid 的办法），`dispatch` 在解析前与下钻后各判一次（先判登录再判 404，与上游一致），
     alias 目标按上游「重新 dispatch」语义**替换** auth；`cgi_luci.odin` 用 `respond_full`
     回 403 + `Content-Type: text/html` + `X-LuCI-Login-Required: yes`。
  4. 测试：`menu_test.odin` +3 用例（无会话→登录提示且正文带路径 / 有会话照常+缺组仍 404 /
     `ctx.auth` 最后者胜 + `auth` 类型不符整键忽略）；fixture 的 `admin` 补 `auth.login`；
     smoke 改口 11 条旧断言（原「无 cookie 打 /admin/**」——它们以前靠「无会话照常渲染」），
     新增 6 条（403 + 响应头 + 提示页正文与路径 + `HEAD` 到登录提示页无 body +
     `/admin/nope` 无会话 → 403），并把「缺组 → 404 / firstchild 跳过」改用**哨兵会话**继续验
     （有会话但无权限，因而不触发登录分支）。
  5. 门禁：unit 4 包 **68 用例**（luci 18）全 ok、0 leak；http_smoke 通过 **265** 失败 0；
     cgi_smoke 通过 30 失败 0；host 1,214,920B / target 508,880B。
  6. 文档：`interfaces.md` §5.2（分派结果表 + 两条语义）、§5.3（登录提示页结构）、
     §11.4/§11.5（登录页偏离收窄为「正文不是模板」）、§12 权威来源表；
     `testing.md`（单元/集成/接口三处判据与数字 65→68、259→265）；`README.md` 接管提示；
     `architecture.md` §3.2/§3.3/§5/§8。
  下一步：真机验收（`tests/golden.sh` + `tests/device_smoke.sh` + RSS 曲线）；这一条在设备上
  的可见效果就是「无 cookie 打开 `/cgi-bin/luci/` → 403 登录提示页，而不是裸 404」。
- 2026-09-27 — **设备启动日志的文案过期 → 连带审出三类「本机看不见」的内存问题**。
  1. 起因：用户贴的设备日志里写着 `uci（只读 configs/get，写方法回 NOT_SUPPORTED）` 与
     `file（read；其余方法待 P3-4 续…）`。核对方法表后确认是**文案过期**（uci 15 / file 8 /
     luci-rpc 6 / session 10 / probe 2 全都在），不是功能缺失——分片收尾时忘了改日志。
     改为 `log_object_registered(name, len(方法表))`：方法数从表里取，这类文案不可能再停。
  2. 顺着「过期口径」清 `src/`（4 个文件头：uci_object / luci_object / darwin / linux 的
     四段 handler 注释）与 `docs/interfaces.md`（§8 标题「S1 只读 + S2 delta」→ 15 方法全实现、
     §8.1「已实现（S1）」、§10.1「已实现（S1）」）。grep 校验零残留。
  3. 然后审**只能在设备上第一次跑**的 linux-only 路径（本机 `#+build linux` 根本不编译），
     查出三类问题，全在同一根因上：**隐式 `context.allocator` / 分配器不配对**。
     - **主问题（设备上每请求泄漏）**：四个 ubus handler 用 `alloc := context.allocator`
       （默认**堆**分配器）当请求 arena 传给 `*_call`，params/中间树/回复串/cstring 副本
       全落在堆上且无人释放。改成 HTTP 侧同样的做法：每次调用一个 `Dynamic_Arena`，
       `defer destroy`，并把 `context.allocator` 也指向它（兜住调用链里不带分配器的隐性分配）。
       契约本来就是这么写的（`docs/interfaces.md` §7.1「回复串一律指向调用方给的 alloc
       （每请求 arena）」）——linux 侧一直没照办。**长期状态不受影响**：会话 store 用的是
       `session_store_allocator()`（显式默认堆分配器，不读 context），已逐条核过
       （`session.odin:403/406/589/789/1123`、`g_uci_apply_sid`、`new(Sse_Sub)`
       都是 store 分配器）。
     - **`context.temp_allocator` 那条**：`prune_expired` 每次都把收集数组放进 temp arena，
       而 Odin 的默认 temp 分配器设计上要「每帧 loop 一次 `free_all`」——molly 全仓**没有**
       一处 `free_all`，且 ubus 线程拿到的是**全局**那一个。改成用调用方的请求 arena。
     - **克隆/释放不配对**：`event_bus_publish` 用 `alloc` 分配却 `delete(record)`（= 环境
       `context.allocator`）；darwin 的调用方传连接 arena，于是「arena 的内存交给 malloc 去
       free」（实测不崩，属静默 UB）；`event_bus_subscribe` 满员路径 `free(sub)` 同样不配对
       且漏 `sub.path`。另修 SSE 侧三处从没释放的克隆串（命令队列的 `path`、订阅对象的
       `path`、lookup/注册失败路径上的 `path_c`）。`luci_sa2str` 也改成收 `alloc`
       （它被地址/邻居遍历反复调用）。
  4. 门禁（代码零行为变更，只有分配策略与文案）：unit 4 包 65 用例全 ok、0 leak；
     http_smoke 通过 259 失败 0；cgi_smoke 通过 30 失败 0；host 1,214,920B / target 508,880B。
     **注意**：本机验不到 linux 侧的行为——`--target` 只保证编译通过，真正的判据是设备 RSS。
  5. 文档：`docs/architecture.md` §4 新增「每次请求的内存 / 长期状态不走 arena」两段；
     `docs/interfaces.md` §7.1 补「linux 的 ubus handler 也照此办」；`docs/testing.md` §2 新增
     「分配与释放必须配对同一个分配器」与「本机测不到的那一半」两条。
  6. **故意不修**：`g_uci_apply_sid` 的克隆串（36B/次 apply）——定时器线程可能正在读它，
     释放会引入 UAF（详见 P3-9 节的「已知但故意不修」）。
  下一步：设备上的真机验收（`tests/golden.sh` + `tests/device_smoke.sh` + RSS 曲线）。
- 2026-09-27 — **P3-9 代码/文档侧收尾 + 真机验收脚本就位；设备接管只差 golden 抓取**。
  1. 设备实况（用户贴的启动日志）：molly 在设备上跑起来了，`ubus 对象已注册: molly.probe`
     —— **P3-1 的设备验收项达成**；四个对象注册失败（错误码 2）是因为 rpcd 还占着，
     这正是「接管前先 stop rpcd」那条流程要解决的问题，日志逐对象诊断按预期工作。
  2. **本机连不到那台设备**：`192.168.1.1:8081` 拒连、22 也关；本机在 10.10.20.0/24
     （网关是小米路由），我这边能 ping 通的 192.168.1.1 是另一台 CPE（80 端口 gb2312 登录页、
     `/ubus/list` 404）。所以真机动作只能在**设备 shell** 上跑——脚本都写成「在设备上执行」。
  3. transitional 模式移除（`src/main.odin` 那条无条件 WARN）+ 五处文档/AGENTS 改口。
  4. 新增 `tests/golden.sh`（device/molly/http/compare，compare 先归一化再 diff）与
     `tests/device_smoke.sh`（设备上一把验收：探针对象/四对象/HTTP 边界/真实 crypt 登录/
     uci 写路径只碰自建 `/etc/config/mollytest`/SSE 真收帧/可选 golden 与 RSS）。
  5. 给 `molly.probe` 加 `notify`（linux `ubus_notify`、darwin 推总线），两平台同一条命令，
     真机 SSE 因此可验收；smoke 的假 `emit` 改名统一，断言从 `event: emit` 改 `event: ping`。
  6. 门禁：unit 4 包 65 用例全 `ok`、0 leak；http_smoke 259/0；cgi_smoke 30/0；
     host 1,214,968B / target 506,576B；两个脚本 `bash -n` + `--help` 自测过。
  下一步（需要设备 shell）：`mkdir -p /tmp/golden && ./tests/golden.sh device 127.0.0.1`
  （或在设备上直接跑那串只读探针）→ `/etc/init.d/rpcd stop` + 重启 molly →
  `./tests/golden.sh molly http://127.0.0.1:8081` → `compare /tmp/golden` →
  `./tests/device_smoke.sh --pass '<root 密码>'`。
- 2026-09-26 — **P3-7 S2：linux 侧真 ubus 订阅接进事件总线（P3-7 收口）**。
  1. 取证（这次找到了）：`/Users/ryan/openwrt-sdks/src/ubus/libubus.h:145-152` ——
     `ubus_subscriber = list_head(16) + ubus_object(120) + 三个回调(24) = 160`，`obj` 在
     +16；`avl.h:56-95` 给出 `avl_node = 56`（与既有 `Ubus_Object` 的 `[56]byte` 对上）。
     **教训**：上一次我判定「本地已无 libubus.h」是因为只在工程目录里搜，SDK 目录
     （`$HOME/openwrt-sdks`）不在工程内——以后取证先确认搜索范围。
  2. 两个只在**链接期/编译期**暴露的坑：
     （a）`ubus_unregister_subscriber` 是 static inline（.so 没符号）→ `ld.lld: undefined
     symbol`，按 `libubus.h:329-335` 复刻（`list_empty? → list_del_init` + remove_object）；
     （b）通知回调是 `proc "c"`，**没有 context 不能分配** → 回调里只做字节搬运进
     16 槽环形缓冲，由 ubus 线程主循环排空后 `event_bus_publish`。
  3. 命令方向：HTTP 线程排 `Start/Stop` 命令，ubus 线程把 `uloop_run_timeout(-1)`
     改成 `uloop_run_timeout(100)` 循环并在间隙排空（ADR 0001 写的是把命令管道挂进
     uloop；这里用轮询，少一个 uloop fd 绑定，命令延迟 ≤100ms，已记进 ADR 的偏离）。
     按 **path** 一个 subscriber（上游每条连接一个，我们按 path 去重即可）。
  4. 门禁：两端编译通过（target 506,304B —— 说明 `ubus_register_subscriber` /
     `ubus_subscribe` / `ubus_unsubscribe` 都在库里）；unit 4 包全 `ok`（65 用例）、
     0 leak；http_smoke 259/0；cgi_smoke 30/0。
  5. 文档：`interfaces.md` §4.7（差异表补两行 + linux 实现要点）、`testing.md`、
     `README.md`、ADR 0001 的 follow-up 勾掉、本计划同步。
  下一步：**真机验证 P3-7**（`/ubus/subscribe` 订阅设备上的真实对象，用 `ubus call`/
     真实事件源触发 notify，看 SSE 帧），顺带把 P3-2…P3-7 的 golden 一次抓齐。
- 2026-09-26 — **P3-7 S1：`/ubus/subscribe` 的 SSE 打通（darwin 端到端可验）**。
- 2026-09-26 — **P3-7 S1：`/ubus/subscribe` 的 SSE 打通（darwin 端到端可验）**。
  1. 取证：`/tmp/uhttpd-ubus.c:373-424`。要点——ACL 点是**伪方法** `:subscribe`（:382），
     不是 call 的方法名；被拒回 `200` + json + `{"code":-13}`（`uh_ubus_posix_error` 的
     posix **负码**，与 -32002 不同体系）；失败分支（lookup/subscribe）回正的 ubus 码；
     帧是 `event: <method>\ndata: <json>\n\n`（:345）；断开走 `ubus_unregister_subscriber`。
     响应头只保证 `Content-Type: text/event-stream`（:405），chunked/其它头由 uhttpd 通用
     逻辑加——**本地没有 uhttpd.c，这属于待 golden 核对项**。
  2. 实现：`src/backend/event_bus.odin`（平台无关的事件总线：每订阅一根管道，写端非阻塞，
     满了丢事件；上限 32）+ `src/handlers/ubus_sse.odin`（路由 → ACL → 存在性 → 订阅 →
     `text/event-stream` → poll 管道发帧 + 30s 心跳 → 断开注销）。`ubus_http.odin` 里那条
     501 分支删掉（`not_implemented` 一并删）。
  3. darwin 的假事件源：`molly.probe` 加进 FAKE_OBJECTS，并带一个**测试专用**的 `emit`
     方法往总线推通知——SSE 因此在 macOS 上能真收帧（真机没有 `emit`，golden 时记得）。
  4. 测试：单测 2 个（分帧、拆记录）；smoke 新增 SSE 节 7 项（哨兵被 -13 拒、授权会话
     拿到 text/event-stream、未知对象 code 4、推一条事件后收到 event/data 帧）；
     darwin 的 `/ubus/list` 因 `molly.probe` 多一项，三条 list 断言同步更新。
  5. 门禁：unit 4 包全 `ok`（65 用例 / handlers 6）、0 leak → host 1,214,552B →
     http_smoke 通过 259 失败 0 → cgi_smoke 通过 30 失败 0 → target 501,760B。
  6. 文档：`interfaces.md` §4.7（契约 + 五条实现差异表：管道桥/chunked/心跳/retry/丢事件）、
     §2 的 501 行与 §4.1 的表、`testing.md`、`README.md`、`architecture.md` §8、本计划同步。
  下一步：**P3-7 S2** —— linux 侧真 ubus 订阅（要 `struct ubus_subscriber` 的布局证据：
  本地 `libubus.h` 已不在，需重新取头文件或上设备 `nm`/`pahole` 核对），然后真机 golden 轮。
- 2026-09-26 — **P3-6 收尾：`depends.acl` 真裁树 + 删掉 P2 那条横幅，P3-6 收口**。
  1. 取证：上游 `check_acl_depends`（`dispatcher.uc:312-331`）是**三态**——任一要求的组没拿到
     → `null`；全组只有 read → `false`；任一组有 write → `true`。`apply_tree_acls`（`:435-445`）
     据此把节点标 `satisfied=false`（裁出菜单）或 `readonly=true`；最终判权在 `:993-1004`。
     **`resolve_page` 下降时 `!satisfied` 就 break**，所以直接请求被裁掉的路径走的是
     「解析不到」这条路，molly 的 404 与之等价。
  2. 实现（三个新接口）：`backend.session_acl_level(sid, groups)` 三态（`Acl_Level`）；
     `menu.odin` 建树时把 `depends.acl` 解析进 `Node.acl_groups`（数组/对象/裸串都认，
     真机 menu.d 是对象形态），判定**每请求现算**（`node_visible`）——**树是跨请求缓存的，
     判定绝不能写回节点**（写回会串会话，这是与上游唯一的实现差异）；`cgi_luci.odin` 从
     LuCI 的 cookie（`sysauth_http`/`sysauth_https`）取 sid 传给 `luci.dispatch`。
     只读口径按上游取**路径上组名的并集**（含 firstchild 当选支路与 alias 目标）。
  3. render：删掉「ACL 未实施」横幅，改成只读时打提示 + `<dt>readonly</dt><dd>yes|no</dd>`。
  4. **顺手修一个真 bug**：404/501 分支没设 `head_only`，HEAD 到 404 路径会带 body 回去
     （以前 404 只出现在「直接请求不存在的路径」，没被断言碰到；现在 404 是常态）。
  5. 踩坑：这个 Odin 版本的 `fmt` 用 `{{` / `}}` 转义字面大括号（全库惯例），
     单写 `{` 会让参数被当格式指令吞掉——单测里表现为 `grant` 回 status=2，
     查了半天才发现是**测试自己拼的 JSON** 坏了。`append(dst, slice...)` 也不合法
     （Odin 的展开是 `..`，且对 `append` 直接用循环更稳）。
  6. smoke 调整：dispatcher 节改成带 `-b "sysauth_http=$P2SID"` 请求（登录会话 = 有 write），
     新增「无 cookie → 404 / firstchild 跳过 / 只读会话 → 200 + readonly=yes / 撤销 write
     后恢复可见」5 项；`depends.acl 展示不执行`、`占位页有 ACL 未实施横幅` 两条旧断言删掉。
  7. 门禁：unit 4 包全 `ok`（63 用例 / luci 15）、0 leak → host 1,196,312B →
     http_smoke 通过 252 失败 0 → cgi_smoke 通过 30 失败 0 → target 498,864B。
     文档：`interfaces.md` §5.3（占位页结构）、新 §11.3（裁树）+ §11.5（偏离：403 角与登录页）、
     `testing.md`、`README.md`、`architecture.md` §8、本计划同步。
  下一步：**P3-7 `/ubus/subscribe`（SSE）**，或真机 golden 轮（四个对象 + ACL 都齐了，
  一次抓 `ubus -v list` + `acl.d` + 逐方法样本最划算）。
- 2026-09-26 — **清掉 `leak` 警告 + 抓到一个假绿灯（P3-6 收尾前置）**。
  1. 用户以为只有 2 处泄漏，实际扫出三类「隐式 `context.allocator`」：
     （a）`luci_parse_mac`/`duid_to_mac` 的 `strings.clone` 不带分配器（设备上**每租约条目
     泄漏 17B**）→ 加 `alloc` 参数并把调用链（含 linux.odin 两处）穿下去；
     （b）`session_dump`/`session_do_get` 里 `values := json.Object{}` 零值 map 插入 →
     改 `make(json.Object, len(ses.data), alloc)`；
     （c）`session_dump_acls_json` 里从 map 取出的零值 `[dynamic]json.Value` 上 append →
     显式 `make([dynamic]json.Value, 0, 4, alloc)`；另修测试侧
     `uci_object_test.odin` 的 `strings.join` 与 `acl_test_login` 的 options、md5 用例的 hex 缓冲。
  2. **抓到一个真失败（不是泄漏导致的）**：`test_session_acl_grant_revoke_access` 3 条断言
     失败——darwin fixture 的 root login 列了 `read/write = '*'`（与真机 `rpcd.config` 默认值
     一致），P3-6 起 acl.d 会全量加载，于是**测试专用的 `smoke-full` 组**（`"ubus":{"*":["*"]}`）
     生效，任何 `access` 都成了 `true`。改法：该用例自建会话 + 只按 luci-base 的窄列表加载
     acl.d（登录→acl.d 整链路由另两个用例覆盖）；坑写进 `interfaces.md` §11.4 第 5 条。
     **教训**：上一轮的「unit 4 包全 ok」是错报——`leak` 只是警告，真正让包判失败的是断言。
  3. 门禁：unit 4 包全 `ok`（61 用例 / backend 40）、**leak 计数 0**；host 1,195,416B →
     http_smoke 通过 245 失败 0 → cgi_smoke 通过 30 失败 0 → target 494,656B。
  4. 文档：`docs/testing.md`（判据改回「无 `leak` 警告」+ 新增「写用例时别踩的坑」）、
     `docs/interfaces.md` §11.4 第 5 条、本计划同步。
  下一步：P3-6 收尾（`depends.acl` 裁树 + 删占位页横幅），或 P3-7 `/ubus/subscribe`（SSE）。
- 2026-09-26 — **P3-6 S1+S2 落地：入站 ACL 从 acl.d 加载到 `/ubus` 入口都自己做了**。
  1. 先取证：`session.c` 的 `rpc_login_setup_acls`（`:1112-1125`）与匹配引擎（前缀剪枝 +
     `fnmatch`）；上游 uhttpd 的 `ubus.c`（`json_errors` `:80-106`、`uh_ubus_allowed`）。
  2. **S1**：`session_load_acls` glob `session_acl_dir()/*.json`（linux `/usr/share/rpcd/acl.d`、
     darwin `tests/fixtures/acl.d/`）；组名 `fnmatch` + `!` 取反 + **write 蕴含 read**；
     默认/哨兵会话只吃 `unauthenticated`（所以 `login` 自己也要先过前置校验）；
     acl.d 的**表形态**（`"ubus": {"file": ["list"]}`）与**数组形态**（`"uci": ["system"]`）都认；
     `access-group` 元 scope 照旧授。
  3. **S2**：`/ubus` 入口（`ubus_http.odin` 的 `invoke`）按上游顺序——对象查找 `-32000` →
     ACL `-32002` → 参数 `-32602`；`Rpc_Error.Access = -32002`（`Access denied`）启用；
     **fail-closed**（sid 查不到 / 会话已销毁一律拒）。判定委托
     `backend.session_access_ubus`（scope `"ubus"`，object=对象名、function=方法名）。
  4. fixture 三件：`unauthenticated.json`（真机同款）、`luci-base.json`（真机裁剪版）、
     `smoke-full.json`（**测试专用组，真机不存在**：放行 `/ubus` 前置校验，好让既有断言继续
     验各对象的对象级语义）。
  5. smoke 239 → **245**：新增 ACL 断言（对象不存在优先 `-32000`、未授权 `-32002`、
     会话销毁后 fail-closed、acl.d 与 grant 合并进同一张 ACL 表、哨兵读 uci 被前端拦）。
  6. 门禁：unit 4 包断言全过（静态 61 用例 / backend 40）→ host 1,195,432B →
     http_smoke 通过 245 失败 0 → cgi_smoke 通过 30 失败 0 → target 494,432B。
  7. 文档：`interfaces.md` 新增 **§11 入站 ACL**（旧 §11→§12）+ §7.3「ACL 来源不完整」改口；
     `testing.md`（判据与覆盖点，并把「无 leak 警告」这句改口）、`README.md`（过渡期提示 +
     P3-6 行）、本计划同步。
  待办：`depends.acl` 真正裁树 + 删占位页「ACL 未实施」横幅；`src/backend` 2 处测试分配未释放
  （`acl_test_login` 的 options、md5 用例的 hex 缓冲——只出 `leak` 警告，断言全过）。
  下一步：P3-6 收尾，或 P3-7 `/ubus/subscribe`（SSE）。
- 2026-09-26 — **P3-5 收尾：iwinfo 落地（S2b′/S2c′），luci-rpc 语义齐了**。
  1. **契约先取**：本地 SDK 没有 `iwinfo.h`，而 `struct iwinfo_ops` 是**函数指针数组**，
     顺序错一个字段就会静默调到错误函数。按 §0 规则 1（权威来源优先）用 web_fetch 取了
     iwinfo 官方头文件（master 的 `include/iwinfo.h`），拿到完整字段顺序、三个结构体布局
     （crypto 8 字节 / hardware_id 136 字节）与六张名字表的长度（80211=8、HTMODE=19、
     AUTH=2、KMGMT=5、CIPHER=11、OPMODE=10）与位宏规律（首成员对应 1<<0）。
  2. **更正一处记错**：iwinfo 只在 `getWirelessDevices` 里用（luci.c:1150/1163），
     `getNetworkDevices` 根本不调——之前的 S2b′ 记错了归属。
  3. `src/backend/iwinfo.odin`：dlopen `/usr/lib/libiwinfo.so*` + dlsym 三函数 + 六表；
     按接口（phy_only=false）与 radio（phy_only=true）两次取字段，字段集与上游一一对应
     （含 hwmodes_text、hardware.id 四元组、encryption 的 wep/wpa/authentication/ciphers）。
  4. **版本敏感 + 失效保护**（关键设计）：字段顺序与表长随 iwinfo 版本变，所以
     `ops.name` 必须命中已知后端名（wext/nl80211/madwifi/wl/unknown），且 hwmodes 位不得
     越过 80211 表、mode 必须落在 OPMODE 表内；任一不满足 → 当作「没装 iwinfo」，
     **一个字段都不加**。宁可缺字段，也不在设备上吐垃圾。
  5. 单测两个点（纯逻辑，macOS 可跑）：`iwinfo_add_bit_array` 的 zero 兜底/小写/位选择，
     `iwinfo_ops_name_ok` 的白名单。iwinfo 本体只能在设备上验。
  6. 踩坑：Odin 里 `string(cstring_ptr, alloc)` 不是合法转换，而且 `string(cstring)` 是
     **别名**（buf 复用会串值）——必须 `strings.clone(string(cstring(ptr)))`，又是一次
     「Odin 字符串生命周期要显式管理」的实例。
  7. 门禁：unit 通过 4 失败 0（58 用例）→ host 1,178,184B → http_smoke 通过 239 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 491,936B（+12KB）。文档：§10.2.2 补 iwinfo 段
     （含失效保护）、`docs/testing.md`、`README.md`、本计划同步。
  下一步：**P3-5 已无欠账，建议真机 golden 轮**（session/uci/file/luci-rpc + iwinfo 全都能
  在设备上对比）或 **P3-6 ACL**（入站 ubus 的 ACL 校验 + `acl.d` 加载）。
- 2026-09-26 — **P3-5 S2d：`getHostHints` 落地——luci-rpc 6 方法全部实现**。
  1. 契约（luci.c:1192-1828）：五源按优先级合并（netlink 邻居表 10、/etc/ethers 50、
     租约 100、getifaddrs 200、uci 静态租约 250；**数字越大越靠前**），回复是
     「MAC 文本 → {ipaddrs[], ip6addrs[], name?}」，同族地址按 prio DESC + 地址字节 ASC
     排序，重复地址保留高优先级；最后一轮 rrdns（network.rrdns lookup）补主机名
     （v6 缺才填、v4 覆盖）。
  2. 实现：`getHostHints` 的五个来源 + 排序 + 回复组装全在 linux.odin；
     **netlink 用裸 socket**（RTM_GETNEIGH dump + 自己解 nlmsghdr/ndmsg/nlattr，
     `state & ~NUD_NOARP`），故意不引 libnl——少一个设备端运行时依赖。rrdns 复用 S2c 的
     同步 ubus_invoke 机制。
  3. **照抄的上游行为**：uci 静态租约的 `ip` **从不生效**（上游 `!= UCI_TYPE_STRING`
     写反了，:1499-1503），所以静态租约只贡献 MAC + hostname——golden 对比会看到。
  4. **修正 S2b 的真 bug**：`sockaddr_ll` 偏移第一版写错了（拿 sll_protocol 当 hatype、
     ifindex 位置也错）。做 S2d 的 ifaddrs 来源时按 `linux/if_packet.h` 的布局
     （family 0-1/protocol 2-3/ifindex 4-7/hatype 8-9/pkttype 10/halen 11/addr 12-19）
     重新推导，一并改掉——S2b 的 mac/type/ifindex/parent 之前会全是错的，
     这类**只能靠设备验证**的错误在家编译期完全看不出来，是自己重读契约时抓到的。
  5. 门禁：unit 通过 4 失败 0（56 用例）→ host 1,178,216B → http_smoke 通过 239 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 479,200B（+13KB）。smoke 的 S2 断言改为
     「三个绑设备方法在 darwin 回 8（linux-only，不假装实现）」。
  下一步（P3-5 收尾建议）：
  （a）**iwinfo（S2b′/S2c′）**：dlopen libiwinfo + 几组名字表（hwmodes/crypto/auth/kmgmt/
      cipher），补无线设备的字段；
  （b）**真机 golden 轮**：P3-4/P3-5 攒了 3 个 linux-only 方法 + 5 个已实现方法没在设备上
      比对过，一次抓齐最划算；
  （c）**P3-6 ACL**：入站 ubus 调用的 ACL 校验 + `acl.d` 加载（设备侧数据要等 golden 轮）。
- 2026-09-26 — **P3-5 S2c：`getWirelessDevices` 落地（netifd 代理，linux-only）**。
  1. 契约（luci.c:1098-1190）：对 `network.wireless status` 的代理 + 重塑——跳过
     `iwinfo` 键、`interfaces` 数组逐表去掉 `iwinfo`、其余属性原样；netifd 对象不存在
     → 4（`:1187`）。
  2. 实现：**同步** `ubus_invoke`（`bindings.ubus_invoke_fd` 早就在绑定里，不用新增；
     之前 S2c 预估「需要 ubus 客户端绑定」是误判——`ubus_invoke_fd` 就是那个客户端入口）。
     回调里 `blobmsg_format_json` → 全局暂存 → 方法层用 json 重塑。上游用 async +
     defer_request 避免在方法回调里重入 uloop；molly 同步取（偏离记 §10.2.2）。
  3. **iwinfo 仍未做**（与 S2b′ 同一项）：上游会给 radio/接口补一整套 iwinfo 字段，
     molly 现在只是跳过——真机 golden 对比无线设备会缺键。
  4. 门禁：unit 通过 4 失败 0（56 用例）→ host 1,178,072B → http_smoke 通过 239 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 465,920B（+3KB）。smoke 的 S2 断言改了措辞：
     getNetworkDevices/getWirelessDevices 在 darwin 回 8 是「linux-only、不假装实现」，
     与 getHostHints 的「未实现」区分开。文档：§10.2.2/§10.2.3、`README.md`、本计划同步。
  下一步：**S2d `getHostHints`**（netlink 邻居表绑定 + 五源按优先级合并，最重的一片），
  然后建议收 iwinfo（S2b′/S2c′，dlopen libiwinfo + 那几组名字表）或真机 golden 轮。
- 2026-09-26 — **P3-5 S2b：`getNetworkDevices` 落地（linux-only）**。
  1. 契约（luci.c:648-896）：逐 /sys/class/net 条目一张表——bridge 族（brif 存在时）、
     master（readlink basename）、wireless（phy80211/index）、up（operstate up/unknown）、
     mtu?/qlen?、devtype（uevent DEVTYPE= 缺省 ethernet）、ipaddrs/ip6addrs
     （getifaddrs：address/netmask/remote|broadcast）、mac?/type/ifindex/parent?
     （AF_PACKET 第一个匹配 + iflink!=ifindex 时找父设备）、stats 十计数器、
     flags 七位、link 五字段（speed?/duplex?/carrier/changes/up_count/down_count）。
  2. 绑定：`getifaddrs`/`freeifaddrs` 进 `bindings/libc.odin`（#+build linux）。
     sockaddr 按偏移手工解析（in 的地址在 4、in6 在 8、ll 的 hatype 在 2/ifindex 在 16），
     v4/v6 用 posix.inet_ntop，MAC 手工十六进制。
  3. **iwinfo 字段未做**：上游 dlopen libiwinfo 给无线设备加 hwmodes/crypto 等——
     设备缺库时同样没有，真机 golden 对比会缺键，记 S2b′。
  4. 踩坑：`bindings/libc.odin` 是**混合行尾**（LF/CRLF 并存）且 `---` 与 `}` 之间没有
     空行——python 的整段 replace 连续失败三次，最后按行定位修好；追加时还把
     `c_realpath` 的声明行误删了一半（`@(link_name)` 悬空），`--target` 当场抓住。
     另外确认：Odin 的 `os.read_directory_by_path` 返回 `(files, err: Error)`——
     `if err` 不合法（Error 不是 bool），必须 `== nil`；Go 式 `if init; cond` 不存在。
     `strconv.parse_int/parse_uint` 签名是 `(s, base)`，没有宽度参数。
  5. 门禁：unit 通过 4 失败 0（56 用例）→ host 1,178,008B → http_smoke 通过 239 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 463,008B（+17KB，getNetworkDevices + getifaddrs）。
     文档：§10.2.1（S2b 语义与偏离）、`README.md`、本计划同步。
  下一步：**S2c `getWirelessDevices`**（先做 ubus 客户端绑定 `ubus_invoke` + 延迟回复，
  再代理 netifd 的 `network.wireless status`）或 **S2d `getHostHints`**（netlink 最重），
  或真机 golden 轮。
- 2026-09-26 — **P3-5 S2a：`getDUIDHints` 落地**。
  1. 契约（luci.c:1831-1900）：只收 v6+duid 租约；key = `duid`（无 iaid）或
     `duid%iaid`；回复以 key 为键的对象，字段序 interface?/duid/iaid?/hostname?/macaddr?。
     完全复用 S1 的 leasefile 发现与解析——**可移植**，darwin 上就能端到端断言。
  2. 顺手确认了 S2b/c/d 的实现路径：`getWirelessDevices` 是对 netifd
     `network.wireless status` 的**代理**（要 ubus_invoke + 延迟回复 → molly 需要先有
     ubus **客户端**绑定）；`getNetworkDevices` 是 sysfs + getifaddrs（需 ifaddrs 绑定，
     结构体布局 darwin/linux 不同）；`getHostHints` 五源合并最重。三片都 linux-only。
  3. 踩坑：Odin 的 `map` 用 `make(map, cap, alloc)`（不是 `make(map, 0, cap, alloc)`）——
     写错三次，编译器报错信息要看清是哪个 make 重载；`fmt` 的 `%%` 转义行为不确定，
     字符串拼接（strings.concatenate）更稳；`for k := range obj` 是 Go 语法，Odin 是
     `for k in obj`（又混了一次 Go 语法，写循环时默念 Odin 的 for-in）。
  4. 门禁：unit 通过 4 失败 0（56 用例）→ host 1,177,784B → http_smoke 通过 239 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 445,072B。文档：§10 补 getDUIDHints 行与
     S2b/c/d 的实现路径、`docs/testing.md`、`README.md`、本计划同步。
  下一步：**S2b/c/d**（建议顺序：b→c→d，c 需要先做 ubus 客户端绑定，d 的 netlink
  最重；三片都只能交叉编译 + 设备验证），或先真机 golden 轮——现在 luci-rpc 的
  三个已实现方法 + session/uci/file 都可以在设备上直接对比了。
- 2026-09-26 — **P3-5 S1：`luci-rpc` 的 getBoardJSON/getDHCPLeases 落地**。
  1. 取证：对象名是 **`luci-rpc`**（`luci.c:2043`），不是 `luci`——smoke 的透传探针
     打在假对象 `luci` 上不受接管影响。6 方法；S1 实现两个文件/解析驱动的，
     其余 4 个（netlink/iwinfo/getifaddrs 绑定）回 8（S2，linux-only）。
  2. `getDHCPLeases`（luci.c:394-473、:1937-2027）：leasefile 发现走 uci `dhcp` config
     （darwin 用 FAKE_UCI 新增的 dhcp fixture，leasefile 指向 /tmp 固定路径）；
     dnsmasq 与 odhcpd 两种行格式分开解析；**expires 语义两格式不同**——dnsmasq 的
     ts==0 是永久（-1）、odhcpd 的 ts==0 是过期（0）；回复只带第一个地址（:2000）；
     `01:` 前缀 clientid 只在行内 MAC 解析失败时兜底（上游 `if(!ea)`，:621）；
     family **类型不符按 blobmsg 规则当缺省 0**，只有整数值不在 {0,4,6} 才回 2。
  3. **抓到一个真 bug（老朋友）**：`string(栈上定长数组[:])` 是**别名**不是拷贝——
     `luci_parse_mac` 返回后内容即失效，.smoke 里表现为 macaddr 变成 "4d" 这种碎片。
     与 P3-2 的 arena 悬垂、P3-3 的 delete 分配器同族：Odin 的字符串生命周期
     必须显式管理，修成 `strings.clone`。单元测试在单跑时能过（栈内容恰好没被覆盖）、
     全量跑时随机炸——这类 bug 的典型特征，别信「单测绿了」。
  4. 踩坑重演：改完 luci_object.odin 忘了重建 host，smoke 拿旧二进制跑出诡异失败
     （macaddr "4d"）——第三次踩了，计划里已有专门条目，下次动手前先 `build.sh --host`。
     另外 S2 循环的请求体又用双层引号拼 → -32700，统一 printf。
  5. 门禁：unit 通过 4 失败 0（56 用例）→ host 1,176,680B → http_smoke 通过 237 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 441,200B。文档：`docs/interfaces.md` §10（新契约节）、
     `docs/testing.md`、`README.md`、本计划同步。
  下一步：**S2** —— `getNetworkDevices`/`getWirelessDevices`/`getHostHints`/`getDUIDHints`
  （netlink/iwinfo/getifaddrs，linux-only；darwin 回 8），或先真机 golden 轮
  （session/uci/file/luci-rpc 四对象已齐）。
- 2026-09-26 — **P3-4 收尾：`exec` 落地，file 对象 8 方法全部完成**。
  1. 契约（file.c:846-1203）：PATH 查找（无 PATH 用 `/bin:/usr/bin:/sbin:/usr/sbin`，
     找不到 → 4）；**带会话的调用不允许 env**（`:1047`，先于 ACL）→ 6；**两层 ACL**——
     先查可执行文件路径，不过再把整条命令行（≤1024B、≤255 参数）当第二个对象查
     （`:1060-1083`）；超时 120s（`RPC_EXEC_DEFAULT_TIMEOUT`）→ SIGKILL + 7；
     输出超 ustream 缓冲 → 8；回复 `{code, stdout?, stderr?}`。
  2. **同步化实现**：上游是 uloop 定时器 + ubus 延迟回复（进程退出后异步回包）；
     molly 的对象层是同步 RPC，就在本线程 poll 双管道到 EOF（EINTR 继续），
     对调用方可观测行为一致、服务端并发行为不同（记 §9.3）。**不做 shell 拼接**：
     argv 数组直接 execv（AGENTS.md §2.2；与 cgi_exec 同一条纪律——fork 前把 C 串
     全部构造好，子进程里只做 async-signal-safe 调用）。
  3. 踩坑：`posix.poll` 的 nfds 在 linux 是 u64（nfds_t）、darwin 是 u32——**又一处
     只在 --target 暴露**；`os.get_env` 要带分配器且返回单值；`setenv` 第三参是 b32
     要传 `true`；`append(&buf^, …)` 的 `&buf^` 不是合法语法（用 ^[dynamic]u8 参数 +
     `append(buf, b)` 直通）。
  4. smoke 新增 6 条（exec 节共 26 项）：env+会话 → 6、未授权 → 6、PATH 找不到 → 4、
     路径对象授权放行（stdout 断言）、**整条命令行串授权**——精确参数放行、
     参数不同 → 6（file.c:1081 那条很容易漏掉的第二 ACL 形态）。
  5. 门禁：unit 通过 4 失败 0（51 用例）→ host 1,154,632B → http_smoke 通过 222 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 427,600B。文档：§9 的方法表补 exec 行 + 语义段、
     偏离 1 改为「同步化 + 超限杀进程」，`docs/testing.md`、`README.md`、本计划同步。
  下一步：**P3-5 `luci` 对象**（`luci@d6167ea` 的 `libs/rpcd-mod-luci/src/luci.c`，
  契约在 `/tmp/r8/luci-all/`），或真机 golden 轮（现在 file/uci/session 三对象都齐了，
  一次抓齐 `ubus -v list` + `acl.d` + 逐方法 golden 样本最划算）。
- 2026-09-26 — **P3-4 第二批：`stat`/`lstat`/`list`/`md5`/`write`/`remove` 落地（只剩 `exec`）**。
  1. 契约（file.c）：**各方法的权限名不同**——`read`/`md5` → "read"、`write`/`remove` →
     "write"、`list`/`stat`/`lstat` → "list"（`:512/664/734/756/829`）。`stat` 用 "list"
     是上游的实际行为，照抄（smoke 专门断言：只授 read/write 时 stat 被 6 拒）。
     符号链接：`read`/`write`/`list`/`stat`/`md5` 解析并复查；`lstat`/`remove` **不解析**
     （lstat 看链接本身、remove 靠 unlink 的 no-follow）。`remove` 的目录递归里
     **每个条目单独过 write ACL**（`:792`）。
  2. 实现：`file_check_path` 从返回 `size` 扩成完整 `os.File_Info`（`use_lstat` 时走
     `os.lstat`）；`file_stat_dump_json` 复刻 `_rpc_file_add_stat`，mode 用
     `Permissions 位号 | 类型位` 拼回完整 st_mode（Odin 的 mode 只有权限位）；
     `md5` 用 `core:crypto/legacy/md5`（RFC 1321 向量进单测）；`write` 用
     `os.open` 的 File_Flags + `transmute(os.Permissions)` 建权限位。
  3. 踩坑：Odin 的 string 切片越界读不出错但语义错——调试 `canonicalize` 时我数错了
     `/a/../b` 的长度（7 不是 6），`..` 后面是 `/` 所以确实折叠；用独立小程序加打印
     定位，别靠脑内 trace。`fmt.appendf`/`time.unix_seconds`/`os.remove_directory`
     在这个 Odin 版本里都不存在（分别是手动 hex、`to_unix_seconds`、`os.remove`
     ——POSIX `remove(3)` 对空目录就是 rmdir）。`const` 也不是 Odin 关键字。
  4. smoke 踩坑：jq 表达式在**单引号**里时 `$(md5 -q …)` 不会展开——要
     `'… == "'"$(cmd)"'"'` 这种断引拼接。`list` 对普通文件 ENOTDIR → `2`
     （与上游 `rpc_errno_status` 一致），不是拍脑袋的 9。
  5. 偏离（记进 §9.3）：stat 类回复没有 uid/gid/user/group（Odin File_Info 不含）；
     `write` 无全局 `sync()`；md5 整文件读内存无上限。
  6. 门禁：unit 通过 4 失败 0（51 用例）→ host 1,134,968B → http_smoke 通过 217 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 420,848B。文档：§9 改成方法表（含权限名列）、
     `docs/testing.md`、`README.md`、本计划同步。
  下一步：**P3-4 收尾 `exec`**（`file.c:846-1205`：PATH 查找、fork/exec、两条管道、
  超时杀进程；`AGENTS.md` §2.2 不做 shell 拼接——需要把 cron 触发与 ucode 转义那条
  经验带过来），或先安排真机 golden 轮。
- 2026-09-26 — **P3-4 第一批：`file` 的路径/权限核心 + `read` 落地**。
  1. 契约（file.c）：`rpc_canonicalize_path`（`:189-248`）、`rpc_file_access`
     （`:180-187`）、`rpc_check_symlink_access`（`:261-359`）、`read` 的回复形状。
  2. `file_object.odin`：三步路径核心 —— **文本规范化**（只折 `//`、`/./`、`/../`（`..` 后接
     `/` 或结尾时）与结尾 `/`）→ **ACL**（`session.access("file", 路径, perm)`，复用 P3-2
     引擎）→ **符号链接复查**（realpath 不同则对解析路径再查一遍 ACL；悬空链接 → 6）。
     `read` 支持 `base64`；其余 7 方法一律 8。
  3. **抓到一个真 bug（自测抓的）**：canonicalize 的第一版用 `[dynamic]u8` + `pop` 模拟
     上游的「指针回退」，但上游语义是**游标停在 `/` 上、下一个字符覆盖它**——pop 版会
     保留 `/` 再追加，产生 `/a//c` 这种双斜杠。改成定长缓冲 + 游标（逐字节复刻 C）后修复。
     调试时用独立小程序验证，别跟测试框架纠缠。
  4. smoke：透传探针从 `file`/`list` 换到 `luci`/`getBoardJSON`（file 已是真实现；
     P3-5 接管 luci 后这套断言要改成对真实现断言）；新增 file 节 12 项。**踩坑**：
     macOS 上 `/tmp` 是指向 `/private/tmp` 的符号链接，授权范围必须写真实路径，否则
     realpath 复查后 ACL 必然失败。
  5. 门禁：unit 通过 4 失败 0（49 用例）→ host 1,095,144B → http_smoke 通过 206 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 404,256B。文档：`docs/interfaces.md` §9（新契约节）、
     `docs/testing.md`、`README.md`、本计划同步。
  下一步：**P3-4 第二批** —— `stat`/`lstat`/`list`/`md5`（只读，风险低），然后
  `write`/`remove`（要写权限 ACL），`exec` 最后（`AGENTS.md` §2.2：不做 shell 拼接）；
  之后 P3-5 `luci` 对象。
- 2026-09-26 — **P3-3 S4 完成：apply 系落地，uci 对象的 15 个方法齐了**。
  1. 契约：`apply`（`:1566-1651`）、`confirm`（`:1653-1683`）、`rollback`（`:1685-1718`）、
     `reload_config`（`:1720-1734`），以及辅助的 `apply_config`（`:1443-1455`）、
     `copy_file`（`:1457-1478`）、`apply_access`（`:1480-1505`）、`do_rollback`（`:1507-1548`）、
     `apply_timeout`（`:1550-1563`）。
  2. 新增 `src/backend/uci_apply.odin`（平台无关）：快照目录常量、`uci_snapshot_files`
     （列目录 + 跳过 dotfile/空文件）、`uci_copy_file`、`uci_apply_access`（权限 + 5/6）、
     `uci_do_rollback`（含「发起者会话已消失就只恢复 /etc/config」）、四个方法的完整状态机。
  3. 两个设计选择（都写进了 `docs/interfaces.md` §8.3）：
     * 60s 确认窗口用**自清理线程 + sleep + 代际号**，不是 uloop_timeout（uloop 定时器绑定
       在 P3-1 时留给了 P3-7；这里没必要为它绑一个结构体）。可观测行为一致：到点回滚、
       confirm 取消、同一时刻最多一个 apply 待确认（线程数有界）。
     * 列目录用 `os.read_dir` + 显式过滤，而不是上游的 `glob(GLOB_PERIOD)`（那个把 `.`/`..`
       也算进结果，所以 rpcd 里有 `gl_pathc < 3` 的拐弯判断）。等价：没有可用 delta → 5。
  4. 回滚路径的关键细节：上游在回滚前把 delta 目录换成 `/dev/null`
     （`rpc_uci_replace_savedir`，`:1524-1525`），否则「恢复旧配置」会被**当前未提交的 delta**
     污染。我们的每调用一 ctx 实现里就是 `uci_apply_config(name, no_delta = true)` →
     该 ctx 的 savedir 指向 /dev/null。
  5. linux provider：`uci_apply_config`（load + commit + 触发事件，支持 no_delta）、
     `uci_reload_config`（fork → 子进程 `time.sleep(2s)` → `execv("/sbin/reload_config")`；
     照 `cgi_exec.odin` 已验证的形式用 `core:sys/posix`）。darwin 两个都回 8。
  6. 测试：`test_uci_apply_family_neutral_paths`（apply 缺 sid → 2、confirm/rollback → 5、
     apply → 4、reload_config → 8）；smoke 的 uci 节 31 → 36 项。
     **已知覆盖缺口**：apply 的状态机（pending → confirm/rollback → 定时器回滚）在 macOS 上
     没测——它依赖包级全局状态，而 `odin test` 并行跑用例，改全局会把别的用例带跑偏。
     这条链只能靠设备验证（窗口内 confirm / 超时回滚）。
  7. 门禁：unit 通过 4 失败 0（47 用例）→ host 1,076,296B → http_smoke 通过 191 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 397,776B。文档：`docs/interfaces.md` §8.1 表格补 4 行、
     §8.1.4 新增 apply 系语义、§8.2 改成「实现状态」（15/15）、§8.3 加两条差异；
     `docs/testing.md`、`README.md`、本计划同步。
  下一步（建议按序）：
  （a）**真机验证**（现在最该做的）：`cp -a /etc/config /tmp/config.bak` → 只在副本上跑五个写
      操作与 apply 系（窗口内 confirm + 超时回滚两条路径）→ 对 `uci` CLI 逐条比；顺带抓
      S1/S2 的 golden（`ubus -v list`、`/etc/config/rpcd`、acl.d 实际内容）。
  （b）**P3-4 `file` 对象**（8 方法，契约在 `/tmp/rpcd-src/…/file.c`），然后 P3-5 `luci`、
      P3-6 ACL、P3-7 SSE。
- 2026-09-26 — **P3-3 S3 完成：`delete` / `rename` / `order` 落地，五个写操作齐了**。
  1. 契约：`delete`（`:1008-1078`）、`rename`（`:1080-1129`）、`order`（`:1131-1186`）。
     三者的**必需参数校验在 ACL 之前**，而 `type`/`section`/`name` 的语法校验在 ACL
     **之后**——这点与 `add`/`set` 一致，smoke 里专门断言了「未授权 + 非法 section → 6」。
  2. `delete` 的三种形态：`options`（数组，一个都没删到才回 4）/ `option`（具名，找不到回 4）/
     都不给（删整个 section）；没给 `section` 时按 `type`/`match` 遍历、**一个都没命中 → 4**。
  3. **一个内存安全坑**：上游用 `uci_foreach_element_safe` 边走边删（删 section 会释放元素），
     而 molly 的方法层拿的是**快照**（`uci_package_sections` 返回的字符串是指向 libuci 内存的
     视图）。所以 `delete` 的实现里先把命中项的名字 `strings.clone` 出来，再做删除动作——
     行为与上游一致，且不会读到已释放的内存。这一条在代码注释里写清楚了。
  4. `order` 的位置计数只对**成功**的项递增（上游 `i++` 的位置），错误按「首个优先」聚合；
     新增绑定 `uci_reorder_section`（`uci.h:205-211`）。`rename` 不做 section 语法校验、
     但 `name` 要过 `verify_name`。
  5. 测试：`test_uci_delete_rename_order_validation`（参数校验顺序 + ACL + darwin 回 8）；
     smoke 的 uci 节 27 → 31 项。
  6. 门禁：unit 通过 4 失败 0（46 用例）→ host 1,056,264B → http_smoke 通过 190 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 391,216B。文档：`docs/interfaces.md` §8.1.3 新增
     delete/rename/order 语义、§8.2 缩到只剩 `apply` 系、§8.3 更新「写路径待真机验证」；
     `docs/testing.md`、`README.md`、本计划同步。
  下一步（两条，建议按序）：
  （a）**真机验证写路径**：`cp -a /etc/config /tmp/config.bak` → 只在副本上跑五个写操作
      （或先只读验证：把 molly 指向一个副本 confdir）→ 对 `uci` CLI 逐条比 delta；
      这一轮同时把 S1/S2 的 golden 样本一起抓（`ubus -v list`、`/etc/config/rpcd`、acl.d）。
  （b）**S4 `apply` 系**：`apply`/`confirm`/`rollback`/`reload_config`（60s 确认窗口 +
      uloop 定时器 + `apply_sid` 阻塞 commit/revert——`g_uci_apply_sid` 已经占好位）。
- 2026-09-26 — **P3-3 S3 第二步：`set` / `add` 端到端落地**。
  1. 契约补全：`delete`（`:1008-1078`，删 section 时用 `uci_foreach_element_safe`）、
     `rename`（`:1080-1129`，`(option && !ptr.o) || !ptr.s` → 4、name 用 verify_name）、
     `order`（`:1131-1186`，字符串校验 + lookup，`i` 只对命中的 section 递增）。
  2. 方法层（平台无关）：`uci_method_set`（**最后一个 rv 覆盖**、命中计数用 `hit` 代替上游的
     `ptr.s`、成功不发回复）、`uci_method_add`（**首个错误优先**、具名/匿名建 section、
     回 `{"section":…}`）；写计划层补 `uci_plan_add_value`（数组不删旧值、任一坏元素即 2）。
  3. linux 写事务 `Uci_Write_Txn`：`begin`（建 ctx + load，**持 `g_lock` 到 `end`**）/
     `end`（unload + free ctx + 解锁）/ `sections` / `add_section`（具名走 `uci_set` +
     `ptr.value=type`，匿名走 `uci_add_section`）/ `merge_set` / `add_value` / `save`。
     每条 op 都重新 `uci_lookup_ptr`（delete/set 会改元素，缓存 ptr 会踩已释放的 section）。
  4. 接线：`uci_call` 的 `add`/`set` 走真实现；`delete`/`rename`/`order` 仍回 8。
     darwin 的写事务返回 8，但**参数校验与 ACL 在 provider 之前**，所以 darwin 上仍能断言
     2（缺参/非法名）与 6（没权限）——smoke 里三条新断言正是这个顺序。
  5. 踩坑：`bindings.Uci_Ptr` 的字段名是 `pkg`/`opt`（`package`/`option` 是 Odin 关键字），
     我第一次写成了 `option = …`；linux.odin 还要补 `core:encoding/json` 导入（新签名里有
     `json.Value`）。两条都被 `--target` 抓住，host 侧看不见——再次印证 linux-only 代码
     必须每次交叉编译。
  6. 门禁：unit 通过 4 失败 0（45 用例）→ host 1,038,488B → http_smoke 通过 186 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 385,488B（写路径 +9KB；与上一次测量的 ±32B 差异是 ELF 构建号）。文档：`docs/interfaces.md`
     §8.1.2 新增写语义、§8.2 缩到 `delete`/`rename`/`order` + `apply` 系、§8.3 加「写路径
     尚未真机验证」；`docs/testing.md`、`README.md`、本计划同步。
  下一步：`delete`/`rename`/`order`（契约已在手，`order` 需加 `uci_reorder_section` 绑定，
  `delete` 的 section 遍历要照上游用 safe 迭代 + 删完判 `!ptr.section` → 4），
  然后**真机验证**：先 `cp -a /etc/config /tmp/config.bak`，只在副本上跑写 + 对 `uci` CLI 比。
- 2026-09-26 — **P3-3 S3 第一步（写路径的计划层 + 写绑定）**。
  1. 契约：`rpc_uci_add`（`:681-804`，含「首个错误优先」的聚合与 `{"section":…}` 回复）、
     `rpc_uci_merge_set`（`:806-872`，5 种分支）、`rpc_uci_set`（`:875-946`，注意这里的聚合是
     **最后一个 rv 覆盖**，与 `add` 相反；且 `set` **不发回复**）、`rpc_uci_merge_delete`
     （`:948-1006`，3 种形态）。
  2. 新增 `src/backend/uci_write.odin`（平台无关，纯函数）：`Uci_Option_State` /
     `Uci_Merge_Plan` / `uci_plan_merge_set`（含「值没变就不 set」这条防噪声优化、
     数组里坏元素跳过但整体算成功、空数组与全坏元素 → 2）、`uci_plan_merge_delete`
     （字符串/数组/其它类型的分流）、`uci_delete_status`（数组形态的聚合码）。
     关键约定：**status != 0 时 ops 一条都不执行**——上游出错分支可能已经删过内存里的
     option，但 `set` 只在 `!err` 时 `uci_save`，所以落盘行为一致且不留半执行现场。
  3. 绑定：`uci_set`/`uci_delete`/`uci_rename`/`uci_add_list`/`uci_del_list`/
     `uci_add_section`/`uci_save`（签名照 `uci.h:167-232`），`./build.sh --target` 通过。
     只加声明不动行为，所以 host/smoke 无变化。
  4. 测试：`uci_write_test.odin` 两组用例（21 条断言）。门禁：unit 通过 4 失败 0（43 用例）
     → host 1,036,584B → http_smoke 通过 183 失败 0 → cgi_smoke 通过 30 失败 0 →
     target 376,464B（与上一步同尺寸：只加未调用的绑定）。
  下一步（S3 第二步）：读 `uci.c:1008-1188`（`delete`/`rename`/`order` 的 handler 本体），
  然后在 linux 写 provider（按计划层执行 `uci_set`/`uci_add_list`/`uci_delete`/
  `uci_rename`/`uci_save`，`add` 还要处理具名/匿名 section 与 `{"section":…}` 回复），
  接线到 `uci_call`，最后在设备上用**副本配置**对着 `uci` CLI 逐条比对（动手前先备份 /etc/config）。
- 2026-09-26 — **P3-3 S2 落地（delta：`changes`/`state`/`commit`/`revert` + savedir）**。
  1. 契约（uci.c）：savedir 替换（`:264-303`）、`changes` 的两条分支（`:1224-1301`）、
     `dump_change` 的七种 type（`:1189-1222`）、`commit`/`revert`（`:1324-1379`）、
     事件触发（`:1304-1321`，是**同步调 `service.event`**，不是广播）、purge（`:1414-1441`、
     `:1739-1746`）。布局从本地 `uci.h` 取：`uci_package.saved_delta` 在 112 字节处、
     `uci_delta` 56 字节（都加了 `#assert`）。
  2. **实现选择**：上游每次调用替换 ctx 的 `delta_path` 整表，而 `delta_path` 是私有的
     （`uci.h` 只给不透明句柄）。molly 改成**每会话一个短命 context**（用完 free）：新 ctx 的
     delta 路径天然只有要的那一个，没有跨会话串味，也不用碰内部结构。代价是每次多一次
     `uci_alloc_context`（相对 `uci_load` 的解析开销可忽略）。
  3. `uci_object.odin` 补 `state`/`changes`/`commit`/`revert`、`uci_dump_change_json`、
     `uci_purge_dir`/`uci_purge_savedir`；ACL 抽成 `uci_check_read`/`uci_check_write`
     （顺带做 savedir 切换，与上游 read/write_access 一一对应）。**ACL 先于平台能力**：
     未授权 `commit` 回 6，授权后才回 8——与上游顺序一致，S3 直接复用。
  4. linux：`uci_unload`/`uci_commit`/`uci_revert`/`uci_set_savedir`/`uci_add_delta_path`
     绑定 + 五个 provider（含 `uci_trigger_event` 同步调 `service.event`，把 ubus ctx 记进
     `g_ubus_ctx`）；darwin：`changes` 回一组固定假 delta（形状可断言），`state`/`commit`/`revert` 回 8。
  5. 会话销毁与惰性过期都会调 `uci_purge_savedir`（uci.c:1739-1746 的回调）。
  6. 测试：单测 +4 组（dump_change 七种 type 与 `order` 数字、changes 两形态、写方法的 6/8
     顺序、`uci_purge_dir` 用临时目录验「删文件但不递归」）；smoke 的 uci 节 15 → 22 项。
  7. 踩坑：**改完 darwin 忘了重建 host**，smoke 拿旧二进制跑出「changes 不存在的 config
     返回空数组」的假失败——`odin test` 与 `build/molly-host` 是两条独立的产物，两边都要重建。
  8. 门禁：unit 通过 4 失败 0（41 用例）→ host 1,036,584B → http_smoke 通过 183 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 376,464B。文档：`docs/interfaces.md` §8（8.1.1 新增
     S2 语义、§8.3 补 3 条差异）、`docs/testing.md`、`README.md`、本计划同步。
  下一步：**S3 写操作**（`add`/`set`/`delete`/`rename`/`order` + `merge_set`/`merge_delete`
  的 blob 语义），这是第一次会真改 `/etc/config` 的一步——先在设备上把 `/etc/config` 备份
  好，再用副本/可回滚容器验证。
- 2026-09-26 — **P3-3 S1 落地（`uci` 只读）+ 一个真 bug**。
  1. 契约（`uci.c`，1808 行）：15 方法表与入参策略（`:1766-1784`）、`configs`（`:1382-1408`）、
     `get/getcommon`（`:600-662`）的三层回复形状、dump（`:510-597`）、`match`/`type`
     （`:415-499`）、错误映射（`:242-258`）、ACL 钩子（`:311-337`）、每会话 savedir
     （`uci.h` 的 `RPC_UCI_SAVEDIR_PREFIX`）。已落进 `docs/interfaces.md` §8。
  2. 新增 `src/backend/uci_object.odin`（平台无关）：`configs`/`get` 真实现（含 `@type[idx]`
     扩展查找、`.index`、匿名 section 键、`match` 的切词与 list 语义、ACL 复用 session 引擎），
     其余 13 个方法一律 `NOT_SUPPORTED(8)`——**接管到设备上也不会动 /etc/config**。
  3. 平台侧：darwin 加 `uci_list_configs`（FAKE_UCI）+ 把 `/ubus/call/uci` 路由到真实现；
     linux 加 `uci_list_configs`（新绑定 `uci_list_configs` + 自写的 `uci_free_configs`，
     上游只 free 数组、元素是漏的）+ `register_uci_object`（15 方法一个 handler）。
  4. 顺手修掉一个真 bug：`session.odin:511` 的 `defer delete(raw)` 用了默认分配器，
     而 `raw` 是按传入的 allocator 分配的——测试里立刻报 `bad free`（真机上被 malloc 掩盖）。
     修成 `delete(raw, alloc)`。这是 P3-2 留下的第一个「只在换分配器时才炸」的问题。
  5. 测试：`uci_object_test.odin` 4 组用例（校验/match/dump/find + `configs`/`get` 整链，
     含 2/4/8/3 四个错误码与「13 个写方法都回 8」的穷举）；`http_smoke.sh` 新增
     「P3-3 uci 对象（S1）」15 项——含 ACL 的三条关键顺序：哨兵会话读 → 6、
     只授权 network 时读 system → 6、授权后不存在的 config → 4（ACL 先于 load）。
     连带改动：smoke 的「透传探针」从 uci 换成 file/list（uci 已是真实现），
     P3-4 接管 file 时要再换落点（代码里已留注释）。
  6. 踩坑记录：在 `$( … "{\"a\":1}" …)` 这种双层引号里写转义引号，bash 会把反斜杠带进
     正文 → 服务端 -32700；改成 `printf` 拼正文后解决（smoke 里留了注释）。
  7. 门禁：unit 通过 4 失败 0（37 用例）→ host 1,017,240B → http_smoke 通过 176 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 367,344B（NEEDED 五项）。文档：`docs/interfaces.md` §8、
     `docs/testing.md`、`README.md`、本计划同步。
  下一步：**S2**——savedir 模型（`/var/run/rpcd/uci-<sid>`）+ `state`/`changes`/`revert`/`commit`
  （要补 libuci 的 `uci_set_savedir`/`uci_save`/`uci_commit`/`uci_revert` 绑定）；再做 S3 写操作
  （`add`/`set`/`delete`/`rename`/`order` + `write_access` 检查），S4 的 `apply` 系最后。
- 2026-09-26 — **P3-0 取证完成 + P3-1 收口 + P3-2 `session` 对象落地**。
  1. 契约源钉死：`feeds.conf.default` → `rpcd@e37ed9d8`（base feed）与 `luci@d6167ea`
     （`rpcd-mod-luci`）。六个对象的源码与**行号**写进 `docs/interfaces.md` §7 与各处实现注释；
     `session` 的十方法语义、ACL 匹配、login 模型按源码逐条复刻，不凭印象。
  2. `src/backend/session.odin`：十方法 + 会话存储 + `/dev/urandom` 生 sid + 默认 300s 超时
     （惰性过期）+ ACL 前缀/`fnmatch` 匹配 + `grant`/`revoke` + `login`（`/etc/config/rpcd`
     的 login section → `$p$<user>` 引用 `/etc/shadow`）。
  3. 平台侧：`linux.odin` 注册 `session` 对象（一个 handler 覆盖十方法，走 blobmsg ⇄ JSON 桥）
     + `crypt()` 绑定（`bindings/libc.odin`，走 `system:c`——musl 把 crypt 编在 libc 内，
     产物里是 `U crypt`，运行时由设备 libc.so.1 提供）；`darwin.odin` 加假 `rpcd` 配置、
     替身密码校验、`/ubus/call/session` 真实现路由与 sid 注入。
  4. 抓到并修掉两个**真 bug**（编译期看不见）：会话数据最初落在每请求 arena（第二个请求即丢，
     `get` 直接 `Not found`）；`set` 的 map **键**指向请求 arena（键变乱码 `"\x00"`）。
     修法：store/sid/data/acls 一律用默认堆分配器 + 跨请求存活的字符串 `strings.clone`。
  5. 测试：`session_test.odin`（10 用例）；`http_smoke.sh` 新增「P3-2 session 对象」13 项。
     连带修 8 条 P2 老断言——它们拿 `session` 当「透传探针」，而它现在是真实现，改用仍是假数据的
     `uci`/`configs`；另修 2 条我自己写错的期望（`timeout` 传 60 却期望 300；「缺 sid」在 HTTP 上
     不可能出现——上游总会注入哨兵 sid，该分支由单测覆盖）。
  6. 门禁：unit 通过 4 失败 0（31 用例）→ host 998,984B → http_smoke 通过 146 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 356,480B。文档：`docs/interfaces.md` §7（新契约节，含 5 条
     已知偏离）、`docs/testing.md`（用例数、覆盖点、边界）同步。
  下一步：**P3-3 `uci` 对象（15 方法）**——契约在 `/tmp/rpcd-src/…/uci.c`；先定写操作（`set`/`add`/
  `delete`/`commit`）的验证边界（只碰副本或可回滚容器），再按 `uci` CLI 逐条对照。
- 2026-09-26 — **P3-8″-T1 落地（`/cgi-bin/luci` 子进程桥接）**。
  1. 新增 `src/handlers/cgi_exec.odin`：`build_cgi_env`（CGI 环境构造，纯函数）、`parse_cgi_response`
     （CGI 响应解析，纯函数：`Status:`、`Content-Type` 必需、LF LF 容错、`Content-Length`/`Connection`
     丢弃）、`run_cgi`（`fork`/`execve` 桥接）。**fork 与 execve 之间只做 async-signal-safe 调用**，
     argv/envp 全部在 fork 前构造；请求体由一个短命线程写进 stdin（否则「子进程先回响应、父进程写
     64KB body」会在管道缓冲上死锁——用 64KB 用例钉住了）。
  2. `src/http/response.odin` 新增 `respond_full` + `Extra_Header`：状态码/原因短语由调用方给
     （CGI 会回 3xx/401 这类 `Status` 枚举里没有的码），额外头原样透传（`Location`/`Set-Cookie`/
     `Cache-Control`），`Content-Length`/`Connection` 恒由 molly 决定。
  3. `--luci-cgi CMD` 开关（空 = 内置 Odin dispatcher，两种模式见 `docs/interfaces.md` §5.5）；
     `Server.luci_cgi` 由 `main` 传入；启动日志打印 `/cgi-bin/luci → …`。
  4. 测试：`src/handlers/cgi_test.odin`（4 个用例，环境构造与响应解析的边界全覆盖）；
     `tests/fixtures/cgi/{echo,status,sizeprobe,broken,noctype}.sh` 桩程序 + `tests/cgi_smoke.sh`
     （30 项：环境、头映射、body 透传、64KB 无死锁、302/Location/Set-Cookie/Cache-Control 透传、
     Content-Length 重算、缺 Content-Type → 500、脚本崩溃 → 500、HEAD、keep-alive）。
  5. 门禁：unit 通过 4 失败 0（23 用例）→ host 914,680B → http_smoke 通过 129 失败 0 →
     cgi_smoke 通过 30 失败 0 → target 330,192B。`AGENTS.md` §4.1/§10/Do-Don't 与
     `docs/{testing,interfaces,architecture}.md`、`README.md` 同步。
  下一步：设备上把 `--luci-cgi` 指向真实的 ucode dispatcher 并与原厂 uhttpd 做 golden 对比
  （P3-0 的设备取证项一并做）；然后 P3-2 `session` 对象（先把设备 rpcd 的签名抓回来当契约）。
- 2026-09-26 — **路线重定（ADR 0003）**：用户先定「API-first + 自研 Mithril 前端」（ADR 0002），
  随即改为「**保留 ucode**、参考 LuCI2 复刻、先保真后重构」。已核对上游接线并落档：
  ① uhttpd 的默认形态是 `uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'`
  （进程内调 `global.handle_request(env)`，经 `uhttpd.recv/send` 收发，`luci-base/Makefile:47-48`）；
  ② CGI 兜底形态是 `/www/cgi-bin/luci`（`#!/usr/bin/env ucode` + `dispatch(request(getenv(), read, write))`）。
  因此 P3-8′（自研前端）取消，改为 **P3-8″：molly 复刻 uhttpd 的 ucode 接线**，分 T1（子进程，先做，零新增
  C 绑定）/ T2（绑定 libucode 内嵌，后续按 fork 开销与 RSS 实测再定）。连带结论：`session`/`uci`/`file`/
  `luci` 四个对象与入站 ACL 仍必须由 molly 提供（ucode dispatcher 经 ubus 调它们），所以 P3-2…P3-7 不变；
  `src/luci`（Odin dispatcher）离开请求路径但保留为「将来去 ucode」的对照实现。ADR 0002 已标 Superseded。
- 2026-09-26 — **设备实测驱动的第一个发现（P3-1a）**：用户在 192.168.1.1 上访问 `GET /cgi-bin/luci/` 得到
  `not implemented`。本机用真实 menu.d 样本（`/tmp/r8/menu.d`）复现：`GET /cgi-bin/luci/` 是 200（Dashboard，
  `view`），但 `/admin/status/overview` 也是 501 —— 因为它在真实 LuCI 里是 `action.type = "template"`。
  结论：**「非 view ⇒ 501」是 P2 的既定边界**（P3-8 之前必然如此），不是 P3-1 的 bug；但原来那句
  `not implemented` 不带任何命中信息，设备上无法定位。已改：501 正文变成
  `not implemented: action.type=<t> view=<path> menu=<请求路径>`（`src/luci/render.odin` +
  `cgi_luci.odin` 用 `page.body`），smoke 加一条断言（129 项）。同时把 P3-8 的取证做完了（见该节表格）：
  真实样本里 349/413 条路径的渲染都走 ucode/Lua，纯 Odin 复刻等于重写 ucode → 需要用户在 B/C 之间拍板。
  门禁：`./tests/unit.sh` 通过 3 失败 0 → `./build.sh --host` → `./tests/http_smoke.sh` 通过 129 失败 0。
  下一步：用户在设备上重新部署后 curl 一次拿到实际的 `action.type`，并拍板 P3-8 路线。
- 2026-09-26 — P3 计划立档；R4 以 ADR 0001 定案（保留一连接一线程 + 专用 uloop 线程 + 两个 ctx + SSE 走 pipe），
  依据是 sysroot 头文件实测：`ubus_add_uloop`/`ubus_handle_event` 是 static inline 且只碰 `ctx->sock`、
  `struct ubus_context`（`libubus.h:160-165`）与 `struct uloop_fd`（`uloop.h:62-70`）都公开、
  uloop 与 libubus 服务端 API 的导出符号均已用 `llvm-nm -D` 核对。
