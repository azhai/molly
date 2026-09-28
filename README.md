# molly

用 [Odin](https://odin-lang.org/) 复刻 ImmortalWrt LuCI 的服务端三层：**uhttpd**（HTTP + `/ubus` JSON-RPC + CGI）、**rpcd**（ubus 上的 `session`/`uci`/`file`/`luci` 对象）、**ucode dispatcher**（菜单树 → 路径解析 → 渲染）。

**不动**的是：`/etc/config`（uci）、ubusd 消息总线、`/www` 静态文件。

| 项 | 取值 |
|---|---|
| 实现语言 | Odin（zig 只做链接器与交叉编译器，不写 Zig/C 业务代码） |
| 目标平台 | ImmortalWrt 25.12.2 · `aarch64_cortex-a53` · musl 1.2.5 · 动态链接 |
| 目标设备 | NetCore N60 Pro（MT7986A，4×Cortex-A53，512MB RAM） |
| 内存目标 | 空载 RSS < 2 MB |

## 阶段状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0/P1 | 工具链跑通、Odin 绑定 uci/ubus、两段式链接产出合规 aarch64 ELF | 已完成 |
| P2 第 1–6 步 | 构建骨架、HTTP/1.1、静态文件、backend 分层、Linux 绑定、JSON-RPC 协议层、dispatcher 骨架（`menu.d` 建树 / 路径解析 / 占位页） | 已完成 |
| P2 第 6b 步 | dispatcher 语义对齐：spec 逐键处理、`depends.fs` 四类型 / `depends.uci` 全形态、通配 `wildcardaction`（对齐上游 `dispatcher.uc`） | 已完成 |
| P2 第 7 步 | 真机联调与 RSS 压测 | 待设备 |
| P3-1 | ubus 服务线程（专用 uloop 线程）+ 探针对象 `molly.probe` | 已完成（设备验收待做） |
| P3-2 | `session` 对象（十方法，契约按 `rpcd@e37ed9d8` 的 `session.c`）：molly 自持会话、ACL 匹配、login | 已完成（真实 `/etc/shadow`+`crypt` 路径待真机；`acl.d` 加载已由 P3-6 补上） |
| P3-4 | `file` 对象：8 方法全实现（路径规范化 + ACL + 符号链接复查；`exec` 同步版，PATH 查找 + 两层 ACL + 120s 超时） | 已完成（真机 golden 待对比） |
| P3-3 | `uci` 对象：**15 个方法在 linux 上全部实现**（S1 只读、S2 delta、S3 五个写操作、S4 apply 系含 60s 回滚窗口）。写路径与 apply 系按决策只在 linux 上实现，**尚未真机验证**；darwin 上平台相关路径回 4/5/8 | 已完成（待真机验证） |
| P3-5 | `luci-rpc` 对象：6 方法全实现 + iwinfo（dlopen libiwinfo，带版本失效保护） | 已完成（真机 golden 待对比） |
| P3-6 | 入站 ACL：自持 `/usr/share/rpcd/acl.d/*.json`（权限组 + `!` 取反 + 表/数组两形态）+ `/ubus` 前置校验（对象查找 `-32000` → ACL `-32002` → 参数 `-32602`，fail-closed）+ dispatcher 的 `depends.acl` 裁树（缺组 → 404；只有 read → 只读） | 已完成（真机 golden 待对比） |
| P3-8″-T1 | `/cgi-bin/luci` 子进程桥接（复刻 uhttpd 的 ucode CGI 兜底形态，`--luci-cgi`） | 已完成（设备 golden 对比待做） |
| P3-7 | `/ubus/subscribe`（SSE：ACL 点 `:subscribe` + 事件总线 + 分帧推送；linux 侧真 ubus 订阅已实现，darwin 侧端到端可验） | 已完成（linux 的真订阅待真机验证） |
| P3-9 | 收尾：移除 transitional 模式（启动 WARN）、真机验收脚本（`tests/device_smoke.sh` + `tests/golden.sh`）、P4 清单 | 代码侧已完成（真机项待跑） |
| P3 | 继续：真机 golden 轮（`./tests/golden.sh device <host>` → 接管 → `compare`）与 `./tests/device_smoke.sh` | 进行中 |

> **接管步骤（务必先读）**
> molly 现在自己提供 `session`/`uci`/`file`/`luci-rpc`（P3-2…P3-5）、`/ubus` 的**入站 ACL**
> （P3-6，按 `/usr/share/rpcd/acl.d/*.json`，含 dispatcher 的 `depends.acl` 裁树）与
> `/ubus/subscribe` 的 SSE（P3-7）。设备上 rpcd 还占着同名对象时，molly 的注册会失败
> （非致命，**逐对象**打一行诊断）——要接管就先 `/etc/init.d/rpcd stop`，再重启 molly。
> 接管后跑 `./tests/device_smoke.sh` 一把验收（含真实 crypt 登录、uci 写路径、SSE）。
> 启动时不再有「transitional mode」这回事（P3-9 删掉了那条 WARN）。
> 生产渲染走 ADR 0003 的 `--luci-cgi`（设备 ucode，**登录表单也由它渲染**）；
> 内置 dispatcher 是对照实现：没有模板，但无会话访问带 `depends.acl` 的路径按上游回
> **403 + `X-LuCI-Login-Required: yes` + 登录提示页**（P3-6 收尾起，不再是整站裸 404）。

## 快速开始

```bash
brew install odin zig cmake llvm

./toolchain/setup.sh    # 交叉编译 libuci/libubus/libubox/libblobmsg_json 到 sysroot（幂等）
./build.sh --host       # macOS 原生构建；uci/ubus 走假数据，其余全是真代码
./build/molly-host --listen 127.0.0.1:8080 --docroot tests/fixtures/www --menu-dir tests/fixtures/menu.d
```

另一个终端：

```bash
curl -sD- -o/dev/null http://127.0.0.1:8080/index.html   # 200 + Content-Length
curl -s               http://127.0.0.1:8080/ubus/list    # ubus 对象/方法签名
curl -s               http://127.0.0.1:8080/cgi-bin/luci/admin/status/overview   # dispatcher 占位页
```

门禁（按顺序，见 `AGENTS.md` §4.1）：

```bash
./tests/unit.sh                                          # 单元测试：odin test（65 个用例 / 4 个包）
./tests/http_smoke.sh                                    # 集成 + 接口验收 259 项（内置 dispatcher 模式）
./tests/cgi_smoke.sh                                     # /cgi-bin/luci 子进程桥接验收 30 项（桩 CGI，无需 ucode）
```

配置要点：

- `--menu-dir` 默认 `/usr/share/luci/menu.d`；macOS 上要显式指向 `tests/fixtures/menu.d`。
- `--luci-cgi` 非空时，`/cgi-bin/luci` **整个前缀**交给该子进程执行；设备上填
  `"/www/cgi-bin/luci"`（LuCI 装的 CGI 兜底脚本，`#!/usr/bin/env ucode`，复刻 uhttpd 的 CGI 形态，
  ADR 0003）。**别填** `"/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc"`：那是 uhttpd **进程内**
  加载的 ucode 模板（首行 `{%`），当脚本跑必然语法错、每个请求都回
  `500 invalid CGI response (exit 1)`（细节见 `docs/interfaces.md` §5.5）。
  留空则用内置的 Odin dispatcher：只出占位页（会按会话 ACL 裁树、标只读、无会话给登录提示）。

目标机产物（`build/molly` 是 aarch64 ELF）：

```bash
./build.sh --target
scp build/molly root@<设备>:/tmp/
ssh root@<设备> '/tmp/molly --listen 0.0.0.0:8081 --docroot /www'
```

与原厂 uhttpd 并行观察时**换端口**（8081），不要直接顶掉 80 端口。

## 目录结构

```
build.sh                       构建入口：--host / --target
toolchain/setup.sh             用 brew + zig 交叉编译出 uci/ubus/libubox/libblobmsg_json 的 sysroot
src/main.odin                  参数解析、装配、URL 规范化、路由分发
src/http/{uri,server,request,response,limits,mime}.odin   HTTP/1.1 层（手写，Odin 无 HTTP 库）
src/handlers/{static,ubus_http,cgi_luci}.odin              静态文件、/ubus 两个形态的 JSON-RPC、/cgi-bin/luci dispatcher
src/luci/{menu,render}.odin                                读 menu.d/*.json 建菜单树、路径解析、占位页渲染
src/backend/{backend,darwin,linux}.odin                    跨平台契约 + darwin 假数据 + linux 真实现
src/backend/bindings/{libc,blob,blobmsg,ubus,uci}.odin      仅 linux 编译的 foreign import 与 static inline 复刻
tests/http_smoke.sh            macOS 本地端到端验收
tests/fixtures/                macOS 测试用的 docroot 与 menu.d fixture
spike/01-toolchain/            工具链 spike，已冻结（回归基准，不参与产品构建）
```

P2 的本地可验证范围到第 6 步收口（三件套全绿）；第 7 步（真机 RSS 压测与 golden 对比）待设备。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/development-environment.md](docs/development-environment.md) | brew 搭建交叉环境、25.12 SDK 的三条实测结论、四个库怎么编、sysroot 布局与 musl 一致性核对 |
| [docs/build-and-run.md](docs/build-and-run.md) | 为什么必须两段式链接、`build.sh` 用法、产物核验、本地验收清单、真机部署与 golden 对比 |
| [docs/testing.md](docs/testing.md) | 单元 / 集成 / 接口三层测试的覆盖范围与判据、执行流程、覆盖边界与**不能**证明什么 |
| [docs/architecture.md](docs/architecture.md) | 三层职责边界、模块划分、一次请求的调用链、单向依赖规则与跨平台分层机制 |
| [docs/interfaces.md](docs/interfaces.md) | 进程 CLI、HTTP 通用契约与上限、路由表、`/ubus` 与 `/cgi-bin/luci` 契约、backend 窄接口 |
| [AGENTS.md](AGENTS.md) | 协作规则、架构约束、验证纪律（人和 Agent 都读） |

本仓库文档为**中文单语**，不采用双语对照文档集。当前任务的计划与进展写在 `.ai-memory/`（工作记忆，不纳入版本控制）。