# 修复 molly 自己的 `session login`（两个独立 bug 叠加）

状态：**已修复并在设备上验证通过**。

## 两个 root cause（缺一不可，只修第一个会退化成超时）

### bug 1：handler 里 `defer` 的块作用域 → params 悬垂指针

`session/uci/file/luci` 四个 handler 原写法：

```odin
js := bindings.blobmsg_format_json(msg, true)
if js != nil {
	defer bindings.c_free(rawptr(js))   // ← 块作用域！if 块结束就释放
	params = string(js)                 // ← 之后 params 是悬垂指针
}
params → session_call(...)
```

Odin 的 `defer` 是**块**作用域，写在 `if` 里就在该 `if` 结束时立刻执行，
于是 `params` 指向已 free 的内存。表现：调试打印出 `{}`（读到释放后的内存），
`session_call` 拿到空参数 → 校验失败返回状态码 2 → `ubus_invoke_fd` 返回 2 →
`call_object` 判成 `.Internal` → HTTP 侧 `-32603`。

修法（四个 handler 一致）：先克隆进请求 arena 再 free。

```odin
params = strings.clone(string(js), alloc)
bindings.c_free(rawptr(js))
```

排查中确认过其它 5 处 `defer c_free` 都是**函数体**作用域（194/300/2274/2892），
克隆时内存仍有效；SSE 那处（715）由 `sse_event_enqueue` 内部 `copy_cstr` 拷进定长槽，
不存指针——均无需改。

### bug 2：`g_lock` 自死锁（loopback）

molly 的 HTTP 线程 `call_object` 持 `g_lock` 做**同步** `ubus_invoke_fd`（最长 30s），
而 molly 自己注册的对象（session/uci/luci-rpc/file）的 handler 跑在**服务线程**。
`session login` 要读 `/etc/config/rpcd` 校验 login section
（`session_login_check` → `uci_config_sections`），后者也要 `g_lock` → 互等到超时。
判据：`session access`（不读 uci）正常返回，`session login` 返回 code 7 超时。

修法：拆成两把锁 —— `g_lock`（ubus：`list_objects` / `call_object`）与
`g_uci_lock`（8 个 `uci_*`）。反向安全：`uci_commit` 触发事件直接用 `g_ubus_ctx`
调 `ubus_invoke_fd`，**不**获取 ubus 锁，不存在 AB-BA 反转。

### bug 3（拆锁后暴露）：`uci_config_sections` 从不 unload

`uci_ctx()` 是全局单例上下文，libuci 会把加载过的包挂在 ctx 上；不 unload 时
同一个 config 第二次 `uci_load` 直接失败 → `session_login_check` 读不到 login section
→ 表现是**启动后第一次登录成功、之后全部 Permission denied**（code 6）。

修法：`defer bindings.uci_unload(ctx, pkg)`；同时 `uci_package_sections` 里所有字符串
改为 `strings.clone(..., alloc)`（`uci_cstr` 只是视图转换不拷贝，unload 否则悬垂）。
`uci_state_sections` / `uci_delta_changes` 原本就有 `defer unload`，克隆后一并变安全。

### bug 4：登录不下发 `token` → LuCI 判为未认证（整站 403）

`dispatcher.uc` 的 `session_retrieve()` 判定会话有效的**硬条件**是
`type(sdat.values.token) == 'string'`（`session.get` 回来的 values 里必须有 token）。
molly 登录只写了 `data.username`，没有 token → 拿到 sid 后整站仍
`403 + x-luci-login-required: yes`。上游 rpcd 建会话时会写这个字段（CSRF token）。
修法：`session_do_login` 里用现成的 `session_random_sid` 再生成一个写进 `data.token`。

### bug 5：ACL 网关把 `session` 对象一起审 → 会话读不到自己

molly 的 HTTP ACL 网关（`ubus_http.odin`）对所有对象都过 `ubus` scope 的 ACL，
而 acl.d 里没有任何组授予 `session` 的 get/list/destroy（只有 unauthenticated 给了
access/login）。上游 rpcd 里 session 对象是**自服务**的（get/set/unset/destroy 按 sid
自己鉴权）。修法：新增 `backend.session_self_service(sid, method)`，持真实（非默认匿名）
会话时放行 get/set/unset/destroy；list/grant/revoke/create 仍走 ACL。

### bug 6：回复多包一层无名表 → 输出 `{{…}}` 非法 JSON（前端 "No related RPC reply"）

`call_object` 把回复子项搬进 `g_out` 时多套了一层 `blobmsg_open_table(&g_out, nil)`。
那层表**名字为空**，而 `blobmsg_format_element` 对空名不输出 `"": ` 前缀
（blobmsg_json.c：`if (!without_name && blobmsg_name(attr)[0])`），于是外层
`blobmsg_format_json_list` 的 `{}` 叠上无名表的 `{}` → `{{…}}`。

后果：luci.js:35-37 的 `reply.json()` 解析失败（被 try/catch 吞掉、json 为 null），
`Array.isArray(json)` 为 false，批量请求里**每一条**都抛 `No related RPC reply`。

修法：去掉 open/close table，直接 add 到 `g_out`（与同文件 `list_objects` 一致）。
**排查线索**：`/ubus/list` 一直是合法 JSON，只有 `call` 系列是 `{{` —— 两处写法差异
就是破案点。

### bug 7（部分修）：SSE 订阅的权限与投递

**(a) 权限已修**：`:subscribe` 是订阅用的伪方法名，设备上 `acl.d` 里没有任何组显式授予
（grep 无 subscribe），按字面匹配必然 false → SSE 恒 `-13 Permission denied`。
已在 `session_access_ubus` 里加规则：有效登录会话可订阅（订阅是单向接收、不改状态），
**默认匿名会话仍拒绝**。rpcd 源码不在本地 SDK，无法逐行核对上游，已在注释里记明取舍。

**(b) 投递已修**：放行后 SSE 流能建立（不再 -13），但事件仍推不下来，日志坐实
`[molly] ubus_subscribe 失败，错误码 2`。

根因在 **ubusd 侧**，不是 libubus：
`ubusd_handle_add_watch`（ubusd_proto.c:442-476）里

```c
if (cl == target->client)
	return UBUS_STATUS_INVALID_ARGUMENT;   // :460-461
```

**ubusd 禁止客户端订阅自己的对象**。接管模式下 molly 既是 session/uci/file/
luci-rpc/molly.probe 的持有者，又拿注册这些对象的**同一个** ctx 去订阅 →
cl == target->client → 恒返回 2。上游不出这个问题，是因为 uhttpd 订阅的是
**rpcd** 的对象（不同 client）。

修法：订阅者注册在一条**独立**的 ubus 连接上（`g_sse_ctx`，惰性建 + `ubus_add_uloop`），
`sse_watch_apply_start/stop` 都改用它；`sse_drain_watch_cmds` 不再需要 ctx 参数。
（顺带：订阅者对象 name/type 均为 NULL 是 libubus 的既定用法，不是问题——
`ubus_add_object` 的 `obj->name && obj->type` 判断只影响是否发 OBJPATH。）

## 验证

- 门禁：unit 通过 4/失败 0；`build --host` OK；http_smoke 通过 265/失败 0；cgi_smoke 通过 31/失败 0；`build --target` 产出 aarch64 ELF。
- 设备（接管模式：rpcd inactive，molly 占 `session`）：
  - 连续 5 次 `session login` 全部返回 sid（每次不同）。
  - 用 sid 调 `file list /etc` 成功（会话闭环）。
  - 原厂 uhttpd `:80` 也能登录（借 molly 的 session 对象）。
  - `uci configs` / `session get` 返回 `-32002` 属 ACL 按设计拦截
    （acl.d 里 `uci` 只授予 `changes`/`get`，`session` 只授予 `access`/`login`）。

## 追加：私有总线（让 :80 彻底不依赖 molly）

新增 `--ubus-socket PATH`：molly 把 session/uci/file/luci-rpc 注册在**独立 ubusd** 上，
系统总线的同名对象归 rpcd，于是原厂 :80 与 :8080 各自拥有同名对象、互不影响。
`call_object` / `list_objects` / SSE 订阅都会在自己总线上找不到时**回退系统总线**
（netifd / network.* 等只在系统总线上）。

三个必踩的坑（都已处理）：

1. **ubusd 禁止订阅自己的对象**（ubusd_proto.c:460 `cl == target->client` → 错误码 2），
   所以订阅者必须另开一条连接（`g_sse_ctx`）。
2. **CGI 子进程连的是编译期默认 socket**（libubus 无环境变量），所以设备上
   `dispatcher.uc` 打了补丁读 `MOLLY_UBUS_SOCKET`（由 CGI 桥接注入）。
3. 该补丁还必须是**双总线代理**：只连私有总线 → 页面 500（看不到系统对象）；
   单连接 → 403（看不到 molly 的 session）。代理用 `list(obj)` 判断对象在哪条总线
   （ucode 的 `ubus.call` 对不存在的对象**返回 null 而不抛异常**，所以 try/catch 式回退无效）。

验证：`system.board`/`network.interface.lan` 与 molly 自己的 `session.get` 在同一会话下
都可用；:8080 概览/状态/网络页均 200；**停掉 molly 与其私有 ubusd 后 :80 登录照常**。

### bug 8：`ifaddrs` 被提前 free → `getNetworkDevices` 段错误（前端 "No related RPC reply"）

前端再次报 `No related RPC reply`，这次不是 JSON 形态问题，而是 **molly 被一条调用打崩**：
`luci-rpc getNetworkDevices` → `SIGSEGV`（EXIT=139），procd 日志
`Instance molly::molly s in a crash loop`。每开一次页面就崩一次，批量请求拿不到响应。

根因还是 **Odin 的 defer 是块作用域**（与登录那个悬垂 params 同一类）：

```odin
if bindings.getifaddrs(&ifa_start) != 0 {
    ifa_start = nil
} else if ifa_start != nil {
    defer bindings.freeifaddrs(ifa_start)   // ← 写在块里：块一结束就执行
}
entries := … luci_netdev_json(e.name, ifa_start, …)  // 遍历的是已释放的链表
```

第一次「修」把 defer 挪进 `if ifa_start != nil { }` —— **它仍在块里**，所以照样提前释放
（这一版白改，崩溃点只是从更早挪到了地址遍历循环）。定位手段：在函数里埋
`fmt.eprintfln` 检查点，看最后打印到哪里（最后停在 `before_addr_loop`）。

最终修法：新增 nil 安全包装 `free_ifaddrs_if_any`，写**无条件**的
`defer free_ifaddrs_if_any(ifa_start)`，留在函数体作用域。
（另一处 `luci_get_host_hints_ifaddrs` 的 `defer bindings.freeifaddrs` 本来就在函数体
作用域、早退 if 之后，是**正确**的。）

验证：12 条批量返回合法 JSON 12/12；`getNetworkDevices` 返回 9 个设备
（`lo/br-lan/lan1/eth0/…`）；molly 不再进 crash loop；:8080 概览/网络/状态页均 200。

### bug 9：并发上限 32 太低 → 503 与「自动退出」是同一个根因

用户症状：「登录可以，但进去之后每个页面不是自动退出，就是 503」。

**实测**：顺序扫 9 个页面全 200；**40 并发 → 33×200 + 7×503**（body 是 `server is busy`，
来自 `src/http/server.odin:68`）。根因是 `src/http/limits.odin` 的
`MAX_CONNECTIONS :: 32`（标注为「自定类」，从未按真实浏览器校准）：

1. 一个 LuCI 页面会并发拉几十个资源（luci.js / 主题 CSS / 首屏 XHR），浏览器又对同一
   host 开 ~6 条 keep-alive 连接，而连接在 keep-alive 期间一直占槽位（直到客户端关闭或
   `READ_TIMEOUT` 到期）→ 32 很容易打满 → 多余请求 503。
2. **503 会变成「自动退出」**：luci.js 把首屏那条 `session access` 的**任何失败**都当作
   会话过期（`.catch(LuCI.prototype.notifySessionExpiry)`），于是一次 503 就把用户踢回登录页。
   两个症状同根。

**校准依据（原厂 uhttpd）**：设备上 `uci show uhttpd` → `max_connections='100'`，
运行参数 `-N 100`（另有 `-n 3` 每连接并发请求、`-k 20` keepalive、`-t 60`/`-T 30` 超时）。
molly 接管后应当对齐，改 `MAX_CONNECTIONS :: 100`。

**验证**：40/80/120 并发全部 200（原 40 并发有 7 个 503）；混合「页面+静态资源」40 并发全 200；
首屏 `session access {uci,luci,read}` → `{"access":true}`（这条就是决定登出的那条）；
有效 cookie → 200 无 `X-LuCI-Login-Required`，错误 cookie → 403 带该头（符合预期）。

**排查要点**：会话链路本身是好的——登录后拿到的 sid **只存在于 molly 私有总线**
（系统总线 rpcd 查不到），`values.token` 齐全（`session_retrieve` 要求它）。所以看到
「自动退出」不要先怀疑 session handler，先压一下并发看有没有 503。

## 遗留

- 未加单元测试：这三个 bug 都依赖真实 libuci/libubus 行为，darwin 后端是假数据，
  本机测不出来；回归得靠设备上登录验证。
