// cbind 的 C 侧接口。
//
// 目的：把所有 blob/blobmsg 的结构体操作、C 回调、malloc/free 都留在 C 里，
// Go 侧只看 JSON 文本与整数状态码（对齐 Odin 版 src/backend/bindings/*.odin +
// linux.odin 的分工，但边界收得更紧——Go 不碰 blob_attr）。
//
// 全部函数返回 malloc 内存的字符串时，调用方用 molly_free 释放；-1 表示失败。

#ifndef MOLLY_SHIM_H
#define MOLLY_SHIM_H

#include <libubus.h>
#include <libubox/blobmsg.h>
#include <libubox/blobmsg_json.h>
#include <uci.h>

// ---------------------------------------------------------------------------
// 内存
// ---------------------------------------------------------------------------
void molly_free(void *p);

// ---------------------------------------------------------------------------
// blobmsg ⇄ JSON
// ---------------------------------------------------------------------------

// 把一条 ubus 消息（handler 收到的 blob_attr，其**子项**才是参数）格式化成 JSON
// 对象文本。msg == NULL 时返回 NULL。返回 malloc 串。
char *molly_blobmsg_to_json(struct blob_attr *msg);

// ---------------------------------------------------------------------------
// ubus 客户端（list / call）
// ---------------------------------------------------------------------------

// path == NULL 用库内默认 socket。失败返回 NULL。
struct ubus_context *molly_ubus_connect(const char *path);
void molly_ubus_free(struct ubus_context *ctx);

// GET /ubus/list[/<path>] 的正文。*out 收 malloc 串。
// 返回 ubus 状态码（0 成功）。
int molly_ubus_lookup(struct ubus_context *ctx, const char *path, char **out);

int molly_ubus_lookup_id(struct ubus_context *ctx, const char *path, unsigned int *out_id);

// 同步 invoke。params_json 可为 NULL/空；sid 追加成 ubus_rpc_session（可为 NULL）。
// 成功且**有回复数据**时 *out 收 malloc 串；无回复数据时 *out 置 NULL。
// 返回 ubus 状态码（0 成功）。
int molly_ubus_invoke(struct ubus_context *ctx, unsigned int id, const char *method,
                      const char *params_json, const char *sid, int timeout_ms,
                      char **out);

// ---------------------------------------------------------------------------
// ubus 服务端（注册 molly 自有对象）
//
// 起一条专用线程（uloop_run_timeout 循环），注册 session/uci/file/luci-rpc/
// molly.probe 五个对象；入站调用统一桥到 Go 的 mollyGoHandle。
// ---------------------------------------------------------------------------

// 成功返回 0；连不上 ubusd / 建线程失败返回非 0。
int molly_ubus_start_server(const char *socket_path);

// 请求停止服务线程并回收（进程退出用，可省略）。
void molly_ubus_stop_server(void);

// ---------------------------------------------------------------------------
// uci（读）
// ---------------------------------------------------------------------------

// 一个 config 的全部 section，JSON 形状：
//   [{"name":"lan","type":"interface","anonymous":false,
//     "options":[{"name":"proto","list":false,"values":["static"]}]}]
// savedir 为空用默认 delta 目录。成功返回 0 且 *out 收 malloc 串；
// config 不存在/加载失败返回 uci 错误码。
int molly_uci_sections(const char *config, const char *savedir, char **out);

// /etc/config/* 的字母序列表，JSON 字符串数组；成功返回 0。
int molly_uci_list_configs(char **out);

// 一个 config 的 delta（该会话 savedir 下的未提交改动），JSON 数组：
//   [{"cmd":<int>,"section":"..","name":"..","value":".."}]
// cmd 是 enum uci_command（ADD=0 … LIST_DEL=6），与 Go 侧 uciChangeKind 的顺序一致。
// 全部返回 ubus 风格状态码（0 / 2 INVALID_ARGUMENT / 4 NOT_FOUND / 8 NOT_SUPPORTED /
// 9 UNKNOWN_ERROR）；返回 0 且 *out 非空时是 malloc 串。
int molly_uci_delta(const char *sid, const char *config, char **out);

// ---------------------------------------------------------------------------
// uci 写事务（一次方法调用 = 一次 load → 改 → save）
//
// 事务期间 libuci 的 ctx/pkg 被独占；Go 侧用一把锁保证同时只有一件事务。
// 所有函数返回 ubus 风格状态码（见上）。
// ---------------------------------------------------------------------------

struct molly_uci_txn;

// savedir 为空用默认；一般传 /var/run/rpcd/uci-<sid>。失败返回 NULL 且 *status
// 给出 ubus 状态码（4 载入失败 / 9 其它）。成功时 *status = 0。
struct molly_uci_txn *molly_uci_txn_begin(const char *config, const char *savedir, int *status);
void molly_uci_txn_end(struct molly_uci_txn *txn);

// 当前包的 section，JSON 形状同 molly_uci_sections。malloc 串。
char *molly_uci_txn_sections(struct molly_uci_txn *txn);

// 建 section：name 非空用 uci_set(ptr.value=type)，为空用 uci_add_section（名字由 libuci
// 生成）。*out_name 收 malloc 的 section 名。
int molly_uci_txn_add_section(struct molly_uci_txn *txn, const char *type, const char *name,
                              char **out_name);

// section 是否存在。
int molly_uci_txn_section_exists(struct molly_uci_txn *txn, const char *section);

// 现有 option 的状态：*exists 0/1；*is_list 0/1；标量型时 *value 收 malloc 串（否则 NULL）。
int molly_uci_txn_option_state(struct molly_uci_txn *txn, const char *section, const char *option,
                               int *exists, int *is_list, char **value);

// option 为空 → 删整个 section；否则删该 option。找不到回 4。
int molly_uci_txn_delete(struct molly_uci_txn *txn, const char *section, const char *option);

int molly_uci_txn_set(struct molly_uci_txn *txn, const char *section, const char *option,
                      const char *value);
int molly_uci_txn_add_list(struct molly_uci_txn *txn, const char *section, const char *option,
                           const char *value);
// option 为空 → 重命名 section；否则重命名 option。
int molly_uci_txn_rename(struct molly_uci_txn *txn, const char *section, const char *option,
                         const char *new_name);
// 返回「找到了吗」（0/1）；pos 是新的位置。
int molly_uci_txn_reorder(struct molly_uci_txn *txn, const char *section, int pos);

// 把改动写进 savedir 的 delta 文件（不碰 /etc/config）。
int molly_uci_txn_save(struct molly_uci_txn *txn);

// ---------------------------------------------------------------------------
// uci commit / revert / apply（短命 context，各自按 sid 定 savedir）
// ---------------------------------------------------------------------------

// load → uci_commit(overwrite=false) → unload → 触发 config.change 事件（best-effort，
// 走服务线程的连接；服务线程没起来就跳过）。
int molly_uci_commit(const char *sid, const char *config);
// load → uci_lookup_ptr(package) → uci_revert → unload。
int molly_uci_revert(const char *sid, const char *config);
// apply 系：提交一个 config。no_delta!=0 时把 savedir 切到 /dev/null（提交看不见任何 delta）。
int molly_uci_apply_config(const char *config, int no_delta);
// fork/exec /sbin/reload_config（不等它结束，与上游一致）。
int molly_reload_config(void);

// ---------------------------------------------------------------------------
// 子进程 spawn（file.exec / --luci-cgi / cgi-io / 改密码共用）
//
// 自带 fork/dup2/execv/poll/waitpid，绕开 Odin core:os 的 process_exec——后者在
// _reap_terminated 里对 waitid 的 info.code 做 switch，子进程一旦被别的收尸者
// （服务线程里 libubox uloop 的 waitpid(-1)）抢先回收，waitid 返 ECHILD、info 未
// 填充、code=0 → `case .NONE: unreachable()` → 裸 SIGTRAP 崩整个进程。这里 waitpid
// 只等自己的 pid 且容忍 ECHILD、绝不 trap。语义对齐 Go 的 os/exec。
//
//   argv      : 以 NULL 结尾的参数数组（argv[0] 可含 '/' 直接当路径，否则在 PATH 找）。
//   envp      : 以 NULL 结尾的环境数组；NULL → 继承当前 environ。
//   stdin_data/stdin_len: 灌进子进程 stdin 的字节；NULL/负长度 → /dev/null。
//   capture_stderr: 1 → 收进 *out_stderr；0 → 子进程 stderr 直通 molly 的 fd 2。
//   *out_stdout/*out_stderr: malloc 缓冲（NUL 结尾，二进制安全以 *len 为准）；无输出置 NULL。
//   *out_exited/*out_code: 正常退出 exited=1、code=退出码；被信号杀 exited=0、code=信号号。
// 返回 0 = 子进程已起且被回收（成败看 exited/code）；-1 = 没起（fork/pipe/找不到可执行），
// 调用方按 127 / "spawn failed" 处理。
// ---------------------------------------------------------------------------
int molly_spawn(char *const argv[], char *const envp[],
                const char *stdin_data, int stdin_len,
                int capture_stderr,
                char **out_stdout, int *out_stdout_len,
                char **out_stderr, int *out_stderr_len,
                int *out_exited, int *out_code);

// ---------------------------------------------------------------------------
// libc
// ---------------------------------------------------------------------------

// crypt(3) 比对：hash 为空串 → true；hash 以 "$p$" 开头时按 /etc/shadow 里该用户的
// hash 递归比对。返回 1 通过 / 0 不通过。
int molly_verify_password(const char *hash, const char *password);

// ---------------------------------------------------------------------------
// luci-rpc 设备绑定（linux only；对齐 Odin src/backend/linux.odin:2179-3200 与 iwinfo.odin）
//
// 与前面一样：C 结构体布局与协议字节解析全留在 C，Go 侧只拿 JSON 文本。
// 这三个都不碰 ubus，只读 sysfs / /proc / netlink / dlopen。
// ---------------------------------------------------------------------------

// getifaddrs(3) 全量条目。JSON 数组，每项：
//   {"name":..,"family":2|10|17,"addr":..,"netmask":..,"dstaddr":..,
//    "flags":<u32>,"ifindex":<i32>,"hatype":<u16>,"halen":<u32>,"mac":..}
// 顺序与 getifaddrs 链表一致。addr/netmask/dstaddr 是文本；family==17 时 addr/mac
// 都是 6 字节 MAC 文本，ifindex/hatype/halen 取自 struct sockaddr_ll。
// getifaddrs 失败返回非 0（调用方当「没有地址信息」继续）。
int molly_getifaddrs_json(char **out);

// netlink RTM_GETNEIGH dump，过滤后（family 2/10 且 state 非 NOARP）的邻居。
// JSON 数组 [{ip,mac}]。无结果返回 0 且 *out 为 "[]"。
int molly_get_neighbors_json(char **out);

// iwinfo（dlopen /usr/lib/libiwinfo.so*）。成功 0 且 *out 为 malloc 的 JSON 对象文本；
// 没装 iwinfo / 布局不符 / 设备不支持 / 取值越界 → 非 0（调用方一个键都不加）。
// phy_only!=0 时只出 radio（phy）级字段。
int molly_iwinfo_json(const char *devname, int phy_only, char **out);

#endif