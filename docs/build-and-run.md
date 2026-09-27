# 构建、运行与验收

## 1. 两种构建模式

| 模式 | 产物 | uci/ubus | 用途 |
|---|---|---|---|
| `./build.sh --host` | `build/molly-host`（Mach-O arm64） | `src/backend/darwin.odin` 的假数据 | 本地开发与端到端自测 |
| `./build.sh --target` | `build/molly`（aarch64 ELF） | `src/backend/linux.odin` + 真 libuci/libubus | 真机 |

host 模式里 **HTTP、路由、dispatcher 全是真代码**，只有 uci/ubus 是假的。所以本地跑的解析器与真机上是同一份，只有后端数据来源不同——这是"无设备也能验证"的全部秘密。

## 2. 为什么目标平台必须两段式

```
odin build src -build-mode:obj -target:linux_arm64 -o:size -out:build/molly.o
zig cc -target aarch64-linux-musl --sysroot=$OPENWRT_SYSROOT -o build/molly build/molly*.o \
       -L/usr/lib -luci -lubus -lblobmsg_json -lubox -Wl,-s
```

两条实测硬约束决定了不能一步到位，**别改成一步**：

1. Odin 不支持交叉链接到 linux_arm64 —— `Linking for cross compilation for this platform is not yet supported`。
2. `-linker:` 只接受 `default|lld|radlink|mold`，没法指定 SDK 的 gcc。

`-o:size` / `-o:speed` 一般只产出一个合并的 `.o`，`-debug` 会按 package 拆成多个，每新增一个 package 就多一个 `.o`——所以 `build.sh` 用 `molly*.o` 的 glob 覆盖两种情况。

## 3. 链接细节（踩过的坑，别改回去）

| # | 规则 | 原因 |
|---|---|---|
| a | **不能传 `-Wl,-dynamic-linker`** | zig 构建 musl 共享 libc 时报 `LldCannotSpecifyDynamicLinkerForSharedLibraries`。zig 默认解释器就是 `/lib/ld-musl-aarch64.so.1`，与设备一致 |
| b | **`-L` 只能写以 sysroot 为根的路径** | zig 的 lld 忽略 `-Wl,-rpath-link`；且 zig 的 `--sysroot` 会把绝对 `-L` 再拼一遍（`-L/Users/ryan/...` 会被拼成 `$sysroot/Users/ryan/...`） |
| c | **绝不能让 libc 走静态** | 否则进程里出现两份 libc |
| d | **`-lblobmsg_json` 必须显式加** | `blobmsg_add_json_from_string` / `blobmsg_format_json_with_cb` 不在 `libubox.so` 里，而在独立的 `libblobmsg_json.so`（SONAME `.20260213`） |
| e | **库顺序按依赖排** | `uci`/`ubus` 依赖 `ubox`，`blobmsg_json` 依赖 `ubox` 与 `json-c` |
| f | **知道 lld 默认 `--as-needed`** | 没被引用符号的库不会进 `DT_NEEDED`。所以第 1–5b 步的 `NEEDED` 里**没有 `libuci.so`**（当时没有任何代码引用 uci 符号），那一度是正常结果；**第 6 步 `depends.uci` 首次引用 uci 符号后它已自然出现**，现在是五个 `NEEDED` |

## 4. `build.sh` 用法

```bash
./build.sh --host                     # 本地开发与自测
./build.sh --target                   # aarch64 产物 build/molly
OPT=speed ./build.sh --target         # 换优化等级（默认 size）
GOSYMS=1 ./build.sh --target          # 不 strip，保留符号：真机第一次跑想抓崩溃栈时用
OPENWRT_SYSROOT=/path ./build.sh --target   # 换 sysroot
```

相关环境变量：`OPENWRT_SYSROOT`（默认 `$HOME/openwrt-sdks/sysroot-aarch64_cortex-a53`）、`ARCH`、`OPT`、`READELF`。

`--target` 会先检查 `$OPENWRT_SYSROOT/usr/lib/libuci.so` 是否存在，不在就提示先跑 `./toolchain/setup.sh`。

写脚本时注意：`$VAR` 后面紧跟**全角标点**必须写成 `${VAR}`，否则 bash 会把全角字符的字节当成变量名的一部分，报 `unbound variable`。

## 5. 产物核验

`build.sh` 自己会打印 `file` 与 `llvm-readelf` 的关键行。2026-09-26 实测：

```
# --host
build/molly-host: Mach-O 64-bit executable arm64
体积: 824328 bytes

# --target
build/molly: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked,
             interpreter /lib/ld-musl-aarch64.so.1, stripped
体积: 288688 bytes
    Class:   ELF64
    Type:    EXEC (Executable file)
    Machine: AArch64
      [Requesting program interpreter: /lib/ld-musl-aarch64.so.1]
      0x0000000000000001 (NEEDED)  Shared library: [libubus.so.20251202]
      0x0000000000000001 (NEEDED)  Shared library: [libblobmsg_json.so.20260213]
      0x0000000000000001 (NEEDED)  Shared library: [libubox.so.20260213]
      0x0000000000000001 (NEEDED)  Shared library: [libc.so]
```

判读要点：
- `Type: EXEC`（不是 `DYN`）符合原厂 uhttpd 的形态。
- `interpreter /lib/ld-musl-aarch64.so.1` 必须与设备一致。
- 五个 `NEEDED` 的 SONAME 必须与设备上的库逐字相同（版本后缀就是 ABI 版本，见 [development-environment.md](development-environment.md#3-setupsh-做了什么)）：`libuci.so.20250120` / `libubus.so.20251202` / `libblobmsg_json.so.20260213` / `libubox.so.20260213` / `libc.so`。
- `libuci.so` 直到第 6 步才进 `NEEDED`（`depends.uci` 首次引用 uci 符号），理由见 §3 规则 f；在此之前缺它是预期内的。

## 6. 本地验收

```bash
./build.sh --host
./build/molly-host --listen 127.0.0.1:8080 --docroot tests/fixtures/www --menu-dir tests/fixtures/menu.d
```

`--menu-dir` 默认 `/usr/share/luci/menu.d`（真机路径），macOS 上要显式指向 `tests/fixtures/menu.d`。

启动时会打印监听地址、docroot，以及一行过渡期警告：

```
[molly] ubus 对象已注册: molly.probe
[molly] ubus 服务线程：注册 session 失败（rpcd 还在跑？先 /etc/init.d/rpcd stop），错误码 2
（rpcd 停掉后这四行消失；P3-9 起不再打印 transitional WARN）
```

### 6.1 冒烟脚本（首选）

```bash
./tests/http_smoke.sh          # 默认端口 18080（8080 常被占用）
./tests/http_smoke.sh 18081    # 换端口
```

脚本**自己起 `build/molly-host`、跑完杀掉**，服务端日志落在 `/tmp/molly-smoke.log`；必须先 `./build.sh --host`。它打印的行与 `AGENTS.md` 要求的记录格式一致：`通过 N，失败 M`。

2026-09-26 实测：**通过 128，失败 0**。覆盖范围（按加入顺序）：

| 批次 | 覆盖点 |
|---|---|
| 第 2 步（18 项） | 基本响应、keep-alive 复用、HTTP/1.0 默认关连接、HEAD 无 body、头超 8KB→413、chunked→411、POST 无 Content-Length→411、CL 超 64KB→413、CL 非数字→400、路径非 `/` 开头→400、64KB body 可收、40 并发超额→503、压测后仍存活 |
| 第 3 步（17 项） | 静态文件与 `index.html` 回落、MIME、路径逃逸（`..` / `%2e%2e` / NUL）、管道请求（一条连接上 POST 后紧跟 GET，数回包里有几个 `HTTP/1.1`） |
| 第 4 步（17 项） | `/ubus` 前缀边界（如 `/ubus.html` 不能被 ubus 路由抢走）、方法限制、`/ubus/list` 形状 |
| 第 5b 步（33 项） | 旧式 `POST /ubus` 与批请求、新式 `POST /ubus/call/<path>`、`Authorization: Bearer <sid>`、全部 JSON-RPC 错误码、`ubus_rpc_session` 拒绝、错误优先级 |
| 第 6 步（28 项） | `/cgi-bin/luci` 前缀与尾斜杠、`Content-Type: text/html`、root `firstchild` 跳过 unsatisfied、指定路径、查询串剥离、`depends.acl` 裁树（无 cookie → 404 / 只读会话 → 200 + `readonly=yes` / firstchild 跳过与恢复）、中间层 `firstchild`、非 view → 501、通配段进 `request_args`、`depends.fs`/`depends.uci`、未知路径 404、POST → 405、HEAD 无 body |
| 第 6b 步（改写 4 条 + 新增 20 条） | **逐键 spec**：白名单外的键只忽略该键 → 200、`order` 写成 string 只忽略该键（节点用默认权重，root `firstchild` 不变）；**逐键合并**：同路径多文件时未出现的键保留（title 不被清空）；**通配**：无剩余段用 base action、有剩余段用 `wildcardaction`；**`depends.fs`**：file / executable / directory / absent 四类型判定、object-AND 与 array-OR、非 object 取值一律忽略；**`depends.uci`**：`true`（config 有 section）/ 具名 section / `@type` 命中匿名 section / option 值精确匹配 / config 存在但无 section / config 不存在 / object-AND / 非 object 取值忽略 |

### 6.2 手工抽查

```bash
curl -sD- -o/dev/null http://127.0.0.1:8080/index.html     # 200 + Content-Length
curl -sv http://127.0.0.1:8080/ http://127.0.0.1:8080/index.html 2>&1 | grep -i re-using  # keep-alive
curl -s http://127.0.0.1:8080/ubus/list                     # {"<对象>":{"<方法>":{"<参数>":"<类型>"}}}
curl -s -X POST http://127.0.0.1:8080/ubus \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","list",{}]}'
                                                            # result 恒为 [ret, {...}]
curl -s -X POST http://127.0.0.1:8080/ubus/call/session \
  -H 'Authorization: Bearer 00000000000000000000000000000000' -d '{"jsonrpc":"2.0","id":1,"method":"list","params":{}}'
                                                            # result 是回复表本身，空则 null
curl -sD- -o/dev/null http://127.0.0.1:8080/nope            # 404
curl -s http://127.0.0.1:8080/cgi-bin/luci/admin/status/logs       # dispatcher 占位页（含 readonly 行）
curl -s -b "sysauth_http=$SID" \
  http://127.0.0.1:8080/cgi-bin/luci/admin/status/overview        # 带会话 cookie：ACL 门控路径（无 cookie 是 404）
curl -sD- -o/dev/null http://127.0.0.1:8080/cgi-bin/luci/nope      # 未知菜单路径 404
curl -sD- -o/dev/null http://127.0.0.1:8080/cgi-bin/luci/admin/status/routes  # 非 view → 501
```

会话来源是 `Authorization: Bearer <sid>` 头（上游 `uh_ubus_get_auth`），**不是** `Ubus-Session`；缺该头时回退到 32 个 `0` 的哨兵 sid。

## 7. 真机部署（第 7 步，待设备）

```bash
GOSYMS=1 ./build.sh --target          # 第一次上机保留符号，便于抓崩溃栈
scp build/molly root@<设备>:/tmp/
ssh root@<设备> '/tmp/molly --listen 0.0.0.0:8081 --docroot /www --menu-dir /usr/share/luci/menu.d'
```

`--menu-dir` 在设备上就是默认值，写出来只是为了明确 dispatcher 读的是哪一份菜单。

规则：

- **不要动原厂 uhttpd**：换 8081 端口并行跑，方便随时回退。
- **替换前先在原厂固件上抓全量样本存档**，之后用 `curl -si` 与原厂响应做 golden 对比。边界状态码（413/411/403 目录无 index/405）与 `/ubus/list` 的请求头细节都靠这一步校准，不要凭推断定死。
- **RSS 要实测**：连续请求后用 `ps -o rss` 看是否收敛，目标是空载 < 2 MB。"一连接一线程"模型下这条必须用曲线验证，不能只看代码。
- 真机 `ubus list -v` 应与 `/ubus/list` 的输出一致。

未在真机验证过的行为都只是"本地推断"，本阶段（P2）尚无任何真机结论。