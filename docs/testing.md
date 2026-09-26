# 测试：分层、覆盖范围与执行流程

molly 的测试按三层组织，每层解决不同问题、判据也不同。**只看一层绿就宣布完成是错的**
（`AGENTS.md` §6.2）：单元测试不碰 socket，集成测试不覆盖真机库，语义回归只覆盖抽样到的差异。

## 1. 三层测试与各自的判据

| 层 | 文件 / 命令 | 回答什么问题 | 通过判据 | **不能**证明什么 |
|---|---|---|---|---|
| 单元 | `src/*/*_test.odin` → `./tests/unit.sh` | 单个纯函数的语义：路径规范化、MIME、`depends` 判定、菜单树解析、错误文案、CGI 环境/响应翻译、**`session` 对象的十方法语义**、**`uci` 的只读语义（S1）、delta/changes 语义（S2）与写路径的计划层 + 五个写操作与 apply 系的方法层（S3/S4）** | 4 个包全 `ok`（当前 47 个用例）；`All tests were successful`，且无 `leak` 警告 | 不碰 socket、不组成真实 HTTP 帧 |
| 集成 | `tests/http_smoke.sh` | 整条链路：监听 → 请求解析 → 路由 → handler → 响应字节（真起 server、真 curl） | `通过 N，失败 0`（当前 191 项） | 不覆盖真机 `libuci`/`libubus` 行为 |
| 接口 | `tests/http_smoke.sh` + `tests/cgi_smoke.sh` 里按接口分节的断言（`/ubus` 两种 JSON-RPC 形态、`session` 对象十方法、`uci` 的 `configs`/`get`/`changes`/`state`/`commit`/`revert` 、`set`/`add`/`delete`/`rename`/`order` 与 apply 系（`confirm`/`rollback` 的 5、`apply` 的 4）、`/cgi-bin/luci` 的 action 分派、CGI 环境与响应头透传） | 对外契约：状态码、正文形状、错误码、`Content-Type`、CGI 变量、会话生命周期 | 同上（cgi_smoke 当前 30 项）；契约条款钉在断言里——改契约必须先改断言 | 不覆盖 ACL 的 `acl.d` 加载与登录后的权限组（P3-6）；uci 写路径未实现（S3）；`state`/`commit`/`revert` 的真行为只在 linux 上 |
| 语义回归（离线取证） | `.ai-memory/r8_probe.py` | dispatcher 与上游 luci 提交 `d6167ea` 的语义是否一致 | `不一致条目: 0 / 11` | 只覆盖探针列出的 11 条 + 真实样本统计；不是门禁 |

## 2. 单元测试

运行：

```bash
./tests/unit.sh                                   # 三个包一次跑完（输出「通过 N，失败 M（包数）」）
odin test -collection:molly=src src/luci          # 只跑一个包
odin test -collection:molly=src src/luci -define:ODIN_TEST_NAMES=luci.test_first_child_order_tiebreak_and_skips
```

| 包 | 覆盖点 |
|---|---|
| `src/http` | `normalize_path`（Ok / Bad / Escaping 三类，含 `%2e%2e`、`%00`、截断编码、控制字符、查询串剥离、空段与 `.` 折算）、`content_type_for`（大小写、不跨 `/`、未收录扩展名不猜 `text/plain`） |
| `src/luci` | `apply_spec` 逐键处理与逐键合并、`@type` 形态、通配 action 与 `effective_action`、落到根的规格被忽略、无 `depends` 时 `satisfied` 重算、`check_depends` 的 fs 四类型与 object-AND / array-OR、uci 的 `true` / 具名 section / `@type` / option 值与 list 成员、`first_child` 的权重与并列定序与 `firstchild_ineligible`、`at_section_type` |
| `src/backend` | `ubus_error_message`（表内 + 表外 `Unknown error: N`）、`uci_config_sections` 契约（具名 / 匿名 section、option 值、缺失 config `ok=false`、空 config）、`session` 对象（login 成功/错密码/未知用户/缺参、`create` 的 timeout 与 expires、`set`/`get`/`unset` 的键过滤与清空、`grant`/`revoke`/`access` 的精确命中与 `fnmatch` 通配与 scope 清空、哨兵会话不可销毁、`NOT_FOUND`/`INVALID_ARGUMENT`/`METHOD_NOT_FOUND` 三个状态码、`fnmatch` 与 `acl_id_len`）、`uci` 只读（`uci_verify_*` 的三种入口与边界、`uci_match_option` 的切词与 list、`uci_match_section` 的 `empty\|\|match`、`uci_dump_*` 的 `.index`/匿名键、`uci_find_section` 的 `@type[idx]`、`configs`/`get` 的整链与 2/4/8/3 四个错误码）、`uci` 的 delta（`uci_dump_change_json` 的七种 type 与 `order` 的数字 value、`section` 为空被丢掉、`changes` 的两种形态与 4、写方法「ACL 先于平台能力」的 6/8、`uci_purge_dir` 的「删文件但不递归」）、**`uci` 写路径的计划层**（`uci_plan_merge_set` 的 5 种分支：不存在/同值不动/异值 set/list→标量先删再 set/数组先删再 add_list、数组里坏元素跳过且整体成功、空数组与全坏元素 → 2、浮点与对象 → 2；`uci_plan_merge_delete` 的三种形态与聚合码、`uci_plan_add_value` 的「不删旧值/任一坏元素即 2」、五个写操作方法层的参数校验顺序（必需参数 2 先于 ACL 6、语法校验在 6 之后、平台能力最后 8）与「最后一个 rv 覆盖 vs 首个错误优先」） |
| `src/handlers` | CGI 桥接的翻译层：环境构造（`SCRIPT_NAME`/`PATH_INFO`/`QUERY_STRING`/`HTTP_*`/`CONTENT_*`、头名规范化、方法映射）与响应解析（`Status:`、`Content-Type` 必需、LF LF 容错、`Content-Length`/`Connection` 丢弃） |

约定（踩过的坑都写在下面）：

1. 测试与产品代码**同包**、文件名 `<file>_test.odin`，用 `@(test)` + `core:testing`。
   同包是必须的：`apply_spec` / `check_depends` / `first_child` 都是 `@(private)`，
   跨包测不到。
2. **`odin build` 也会类型检查测试代码**（实测：在 `@(test)` 过程体里写一个不存在的符号，
   `./build.sh --host` 立刻报 `Undeclared name`）。好处是测试不会悄悄腐烂；代价是
   `--target` 也会把它们编进对象文件。
3. **每个用例自己建一份 arena**：`alloc, ar := mk_arena(); defer drop_arena(ar)`。
   `odin test` 默认 4 线程并行跑用例，共享一个全局 arena 会互相踩——实测表现为
   `Segmentation_Fault` 和 `Backing array allocator must be initialized`。
4. 断言消息用 `expectf(t, cond, "…%v", x)`；`expect_value` 的第 4 个参数是
   `#caller_location`（不是消息），传字符串会编译失败。
5. 用例里注明对应的上游行号（`dispatcher.uc:171-196` 这种），让回归网可审计。

当前规模：`src/http` 4 + `src/luci` 13 + `src/backend` 2 = **19 个用例**。

## 3. 集成测试

```bash
./build.sh --host        # smoke 需要 build/molly-host 先存在
./tests/http_smoke.sh    # 默认端口 18080，也可 ./tests/http_smoke.sh 18081
```

脚本自己起 `build/molly-host --docroot tests/fixtures/www --menu-dir tests/fixtures/menu.d`、
跑完杀掉，服务端日志落在 `/tmp/molly-smoke.log`。它验证的是**真实字节**：状态行、
`Content-Length`、`Content-Type`、keep-alive 复用、HEAD 无 body，以及
`/cgi-bin/luci` 占位页里的 `<dl>` 字段（`view`、`request_args`）。

批次覆盖表在 `docs/build-and-run.md` §6.1（第 2 / 3 / 4 / 5b / 6 / 6b 步各覆盖了什么）。

## 4. 接口测试

接口测试与集成测试共用同一个脚本，区别在**断言对象是契约而不是页面**：

- `/ubus`（上游 `uhttpd` 的 `ubus.c`）：旧式 `POST /ubus` 与批请求、新式
  `POST /ubus/call/<path>`、`Authorization: Bearer <sid>`、`result` 恒为 `[ret, {...}]`、
  `-32000/-32600/-32601/-32602/-32700` 各自的触发条件、错误优先级（对象不存在 > 参数错误）、
  `GET /ubus/list` 的类型映射表只允许六个取值。
- `/cgi-bin/luci`（上游 `modules/luci-base/ucode/dispatcher.uc`）：PATH_INFO 语义
  （`/cgi-bin/luci` 与带尾斜杠都是空路径 → root `firstchild`）、`action.type` 分流
  （`view` → 200、其它 → 501）、通配层的 `request_args`、`depends.fs`/`depends.uci`
  的显示与否、`GET/HEAD` 之外的方法 → 405。

这两套契约的权威来源与「已验证的事实」都记在 `.ai-memory/p2-runtime-skeleton.md`
（计划 + 进展的唯一权威副本）。

## 5. 语义回归（改 dispatcher 时必跑）

```bash
python3 .ai-memory/r8_probe.py
```

- A 段：用真实 `menu.d` 样本（25.12.2 钉住的 luci `d6167ea`，138 文件 / 413 路径）
  按当前语义核对，列出剩余偏差（当前只剩 7 条非严格 JSON，待真机验）。
- B 段：合成探针菜单起 `molly-host` 实测 11 条语义，**必须输出 `不一致条目: 0 / 11`**。
- 它不是门禁（依赖 `/tmp/r8/` 的离线样本），但改了 `apply_spec` / `check_depends` /
  通配 action 就必须跑。

## 6. 执行流程（本地，按 `AGENTS.md` §4.1 的顺序）

```bash
./tests/unit.sh                  # 1. 单元：纯函数语义
./build.sh --host                # 2. 编译（顺带类型检查测试代码）
./tests/http_smoke.sh            # 3. 集成 + 接口：内置 dispatcher 模式
./tests/cgi_smoke.sh             # 4. 集成 + 接口：/cgi-bin/luci 子进程桥接（桩 CGI）
./build.sh --target              # 5. 改过 linux-only 代码 / 绑定 / 链接参数时必跑
python3 .ai-memory/r8_probe.py   # 6. 改过 dispatcher 语义时必跑
```

每条命令的结果按 `AGENTS.md` §4.2 记进 `.ai-memory/<当前计划>.md` 的进度段，
格式：命令 + 退出状态 + `通过 N，失败 M`。

## 7. 覆盖边界（必须知道）

- **平台**：单元测试与 smoke 都在 macOS 上跑，走的是 darwin provider（假 uci/ubus）。
  linux 侧（真 `libuci`/`libubus`）目前**只有编译 + 链接校验**（`./build.sh --target`）：
  `src/backend/bindings/uci.odin` 的 `#assert` 只保证结构体尺寸与偏移，
  **不保证** libuci 的运行期行为。运行期正确性属第 7 步真机联调。
- **依赖宿主文件系统**：fs 相关用例读 `/etc/hosts`、`/etc`、`/bin/sh`（macOS 上稳定存在）；
  断言里没有写 `/tmp` 之类可能被清空的路径。
- **未覆盖**：ACL 的 `acl.d/*.json` 加载与登录后的 `read`/`write` 权限组（P3-6）、模板渲染
  （P3-8″）、`/ubus/subscribe` SSE（P3-7）、会话落盘与重启恢复、并发上限的精确计数
  （需要在真机用 `sysctl` 调低 fd 上限来压）。
- **uci 的验证边界**：darwin 的 `uci_list_configs`/`uci_config_sections`/`uci_delta_changes`
  都是假数据（`FAKE_UCI`/`FAKE_DELTA`），所以 macOS 上验的是「对象逻辑正确」，**不是** libuci 行为；
  `state`/`commit`/`revert` 与五个写操作在 darwin 上恒回 8（`apply` 系回 4/5 或 8，见 `interfaces.md` §8.2），
  **apply 的状态机（pending → confirm/rollback → 定时器回滚）在 macOS 上没有覆盖**：
  它依赖包级全局状态，而 `odin test` 并行跑用例，改全局会把别的用例带跑偏 ——
  这条链的验证只能靠设备（窗口内 confirm / 超时回滚两条路径）。
  **写路径目前只有 `./build.sh --target` 的编译保证**——`uci_set`/`uci_add_list`/
  `uci_delete`/`uci_rename`/`uci_reorder_section`/`uci_add_section`/`uci_save` 的真实行为
  必须在设备上、用 `/etc/config` 的**副本**对着 `uci` CLI 逐条比对（动手前先备份）。
- **认证的验证边界**：`session.login` 的密码校验在 macOS 上走 darwin 的**替身**
  （`$p$root` → `test1234`）；`/etc/shadow` + `crypt()` 那条真实路径只有编译期保证，
  运行期正确性属第 7 步真机联调。
- **已知偏差**：`luci-app-sms-tool-js.json` 是对象尾逗号（非严格 JSON），molly 用
  `core:encoding/json` 严格解析 → 整文件丢（7 条路径）。上游 ucode 是否容忍待第 7 步实测。

## 8. 加一个用例

1. **单元**：在 `<file>_test.odin` 里加 `@(test)`，用例名写清规则，注释里带上上游行号；
   需要分配器就用 `mk_arena()` / `defer drop_arena(ar)`；跑 `./tests/unit.sh`。
2. **接口 / 集成**：在 `tests/http_smoke.sh` 对应的分节加一行 `check`，并在
   `docs/build-and-run.md` §6.1 的覆盖表里登记批次与项数。
3. **语义**：若新规则来自上游，先在 `.ai-memory/r8_probe.py` 的 `EXPECT` 里加一条
   （期望状态 + 期望 view），再改代码——先让探针红，再让它绿。
