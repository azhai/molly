// cbind 的 C 实现。所有 blob/blobmsg 结构体操作、C 回调、malloc/free 都在这里，
// Go 侧只看 JSON 文本与整数状态码。逐字对齐 Odin 版 src/backend/linux.odin 的语义。

#include "shim.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <ctype.h>
#include <pthread.h>
#include <unistd.h>
#include <dirent.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <poll.h>
#include <errno.h>
#include <fcntl.h>
#include <libubox/uloop.h>

// mollyGoHandle 由宿主语言（Odin）实现并导出：入站 ubus 调用经本函数桥到 Odin handler。
// status != 0 时 shim 不 send_reply，把状态码交回 libubus；成功且有回复时 *reply_out 收 malloc 串。
// （Odin 版替代原 cgo 生成的 _cgo_export.h。）
extern int mollyGoHandle(const char *obj, const char *method,
                        const char *params_json, char **reply_out);

// musl 的 <sys/socket.h> 已定义 AF_PACKET，但显式给一遍常量，避免依赖内核头。
#ifndef AF_PACKET
#define AF_PACKET 17
#endif

// musl 把 crypt() 编在 libc 内部但**不提供** <crypt.h>（OpenWrt 的 -lcrypt 只是空壳），
// 所以这里自己声明，与 libc.odin 的 `@(link_name="crypt")` 等价。
extern char *crypt(const char *key, const char *salt);

// ---------------------------------------------------------------------------
// 内存
// ---------------------------------------------------------------------------
void molly_free(void *p) { free(p); }

// ---------------------------------------------------------------------------
// blobmsg ⇄ JSON
// ---------------------------------------------------------------------------
char *molly_blobmsg_to_json(struct blob_attr *msg) {
	if (msg == NULL)
		return NULL;
	// list=true：handler 收到的 msg 是 UBUS_ATTR_DATA 裸 attr，它的**子项**才是参数。
	return blobmsg_format_json(msg, true);
}

// 把 src 的全部子项原样搬进 dst（对应 Odin 里 blobmsg_add_blob 的那两段循环）。
static void molly_copy_children(struct blob_buf *dst, struct blob_attr *src) {
	int rem;
	struct blob_attr *pos;
	if (src == NULL)
		return;
	rem = (int)blob_len(src);
	pos = (struct blob_attr *)blob_data(src);
	for (; rem >= (int)sizeof(struct blob_attr) &&
	       (int)blob_pad_len(pos) <= rem &&
	       (int)blob_pad_len(pos) >= (int)sizeof(struct blob_attr);
	     rem -= (int)blob_pad_len(pos), pos = blob_next(pos)) {
		blobmsg_add_blob(dst, pos);
	}
}

// 顶层 buf 只装了「一个无名子项」时，格式化**该子项本身**，而不是外层包装表。
//
// blobmsg_format_json(buf->head, …) 渲染的是 head 这个顶层表，而无名子项不会输出
// `"": ` 前缀（blobmsg_json.c：`if (blobmsg_name(attr)[0])`），于是：
//   - 数组回复（open_array(NULL)）被渲染成 `{[…]}`；
//   - 表回复（open_table(NULL)）被渲染成 `{{…}}`。
// 两者都不是 Go 侧期望的形状（数组类回复反序列化成 `[]T` 会直接失败）。Odin 版
// 对同一陷阱的记录见 src/backend/linux.odin:413-420（`{{…}}` 是非法 JSON）。
//
// 调用点必须保证 head 恰好只有一个子项（数组 / 表都行：blobmsg 按该子项自己的类型
// 决定是 `[…]` 还是 `{…}`）。
static char *molly_format_json_sole_child(struct blob_buf *buf) {
	if (buf == NULL || buf->head == NULL || blob_len(buf->head) == 0)
		return NULL;
	return blobmsg_format_json((struct blob_attr *)blob_data(buf->head), true);
}

// ---------------------------------------------------------------------------
// ubus 客户端
// ---------------------------------------------------------------------------

// HTTP 线程独享（Go 侧一把锁串行化）：请求 / 累积 / 输出三个复用 buf。
static struct blob_buf g_tmp;
static struct blob_buf g_acc;
static struct blob_buf g_out;

struct molly_lookup_ctx {
	int add_object;
};

static void molly_lookup_cb(struct ubus_context *ctx, struct ubus_object_data *obj, void *priv) {
	struct blob_buf *buf = &g_tmp;
	struct molly_lookup_ctx *lc = (struct molly_lookup_ctx *)priv;
	(void)ctx;

	if (obj == NULL || obj->signature == NULL)
		return;

	void *outer = NULL;
	if (lc->add_object) {
		outer = blobmsg_open_table(buf, obj->path);
		if (outer == NULL)
			return;
	}

	int rem = (int)blob_len(obj->signature);
	struct blob_attr *pos = (struct blob_attr *)blob_data(obj->signature);
	for (; rem >= (int)sizeof(struct blob_attr) &&
	       (int)blob_pad_len(pos) <= rem &&
	       (int)blob_pad_len(pos) >= (int)sizeof(struct blob_attr);
	     rem -= (int)blob_pad_len(pos), pos = blob_next(pos)) {
		void *t = blobmsg_open_table(buf, blobmsg_name(pos));
		if (t == NULL)
			return;

		int rem2 = (int)blobmsg_data_len(pos);
		struct blob_attr *p2 = (struct blob_attr *)blobmsg_data(pos);
		for (; rem2 >= (int)sizeof(struct blob_attr) &&
		       (int)blob_pad_len(p2) <= rem2 &&
		       (int)blob_pad_len(p2) >= (int)sizeof(struct blob_attr);
		     rem2 -= (int)blob_pad_len(p2), p2 = blob_next(p2)) {
			if (blob_id(p2) != BLOBMSG_TYPE_INT32)
				continue;
			const char *name = blobmsg_name(p2);
			// 上游 uhttpd 的类型映射表（ubus.c:630-649）：只有这六个取值。
			switch (blobmsg_get_u32(p2)) {
			case BLOBMSG_TYPE_INT8:
				blobmsg_add_string(buf, name, "boolean");
				break;
			case BLOBMSG_TYPE_INT32:
				blobmsg_add_string(buf, name, "number");
				break;
			case BLOBMSG_TYPE_STRING:
				blobmsg_add_string(buf, name, "string");
				break;
			case BLOBMSG_TYPE_ARRAY:
				blobmsg_add_string(buf, name, "array");
				break;
			case BLOBMSG_TYPE_TABLE:
				blobmsg_add_string(buf, name, "object");
				break;
			default:
				blobmsg_add_string(buf, name, "unknown");
				break;
			}
		}
		blobmsg_close_table(buf, t);
	}

	if (lc->add_object)
		blobmsg_close_table(buf, outer);
}

struct ubus_context *molly_ubus_connect(const char *path) {
	return ubus_connect(path);
}

void molly_ubus_free(struct ubus_context *ctx) {
	if (ctx)
		ubus_free(ctx);
}

int molly_ubus_lookup(struct ubus_context *ctx, const char *path, char **out) {
	*out = NULL;
	if (ctx == NULL)
		return UBUS_STATUS_CONNECTION_FAILED;

	blob_buf_init(&g_tmp, 0);
	struct molly_lookup_ctx lc;
	lc.add_object = (path == NULL || path[0] == '\0');

	int e = ubus_lookup(ctx, (path && path[0]) ? path : NULL, molly_lookup_cb, &lc);
	if (e != 0)
		return e;

	// 累积 buf 开着嵌套 table，格式化要的是一层平的结构：把顶层子项原样拷进 g_out。
	blob_buf_init(&g_out, 0);
	molly_copy_children(&g_out, g_tmp.head);

	char *js = blobmsg_format_json(g_out.head, true);
	if (js == NULL)
		return UBUS_STATUS_NO_MEMORY;
	*out = js;
	return 0;
}

int molly_ubus_lookup_id(struct ubus_context *ctx, const char *path, unsigned int *out_id) {
	if (ctx == NULL)
		return UBUS_STATUS_CONNECTION_FAILED;
	uint32_t id = 0;
	int e = ubus_lookup_id(ctx, path, &id);
	if (e == 0)
		*out_id = id;
	return e;
}

static void molly_data_cb(struct ubus_request *req, int type, struct blob_attr *msg) {
	(void)req;
	(void)type;
	if (msg == NULL)
		return;
	molly_copy_children(&g_acc, msg);
}

int molly_ubus_invoke(struct ubus_context *ctx, unsigned int id, const char *method,
                      const char *params_json, const char *sid, int timeout_ms,
                      char **out) {
	*out = NULL;
	if (ctx == NULL)
		return UBUS_STATUS_CONNECTION_FAILED;

	blob_buf_init(&g_tmp, 0);
	if (params_json != NULL && params_json[0] != '\0') {
		if (!blobmsg_add_json_from_string(&g_tmp, params_json)) {
			// params 是 handler 自己序列化的，到这里还解析失败只能是本机故障；
			// 用 INVALID_ARGUMENT 回给 Go，由它翻成 Internal（与 Odin 一致）。
			return UBUS_STATUS_INVALID_ARGUMENT;
		}
	}
	if (sid != NULL)
		blobmsg_add_string(&g_tmp, "ubus_rpc_session", sid);

	blob_buf_init(&g_acc, 0);
	int ret = ubus_invoke_fd(ctx, id, method, g_tmp.head, molly_data_cb, NULL,
	                         timeout_ms, -1);
	if (ret != 0)
		return ret;

	// 没有数据 → *out 保持 NULL（上层渲染成 result:null），不去格式化空表。
	if ((int)blob_len(g_acc.head) == 0)
		return 0;

	blob_buf_init(&g_out, 0);
	molly_copy_children(&g_out, g_acc.head);
	char *js = blobmsg_format_json(g_out.head, true);
	if (js == NULL)
		return UBUS_STATUS_NO_MEMORY;
	*out = js;
	return 0;
}

// ---------------------------------------------------------------------------
// ubus 服务端
// ---------------------------------------------------------------------------

static struct ubus_context *g_server_ctx;
static volatile int g_server_stop;
static pthread_t g_server_tid;
static int g_server_started;

// 入站调用统一桥到 Go：status != 0 时**不** send_reply，把状态码交回 libubus。
static int molly_ubus_handler(struct ubus_context *ctx, struct ubus_object *obj,
                              struct ubus_request_data *req, const char *method,
                              struct blob_attr *msg) {
	char *params = molly_blobmsg_to_json(msg);
	if (params == NULL)
		params = strdup("{}");

	char *reply = NULL;
	int status = mollyGoHandle((char *)obj->name, (char *)method, params, &reply);
	free(params);

	if (status != 0) {
		if (reply)
			free(reply);
		return status;
	}

	struct blob_buf b;
	memset(&b, 0, sizeof(b));
	blobmsg_buf_init(&b);
	if (reply != NULL) {
		blobmsg_add_json_from_string(&b, reply);
		free(reply);
	} else {
		blobmsg_add_json_from_string(&b, "{}");
	}
	int rc = ubus_send_reply(ctx, req, b.head);
	blob_buf_free(&b);
	return rc;
}

static struct ubus_method session_methods[] = {
	{ .name = "create", .handler = molly_ubus_handler },
	{ .name = "list", .handler = molly_ubus_handler },
	{ .name = "grant", .handler = molly_ubus_handler },
	{ .name = "revoke", .handler = molly_ubus_handler },
	{ .name = "access", .handler = molly_ubus_handler },
	{ .name = "set", .handler = molly_ubus_handler },
	{ .name = "get", .handler = molly_ubus_handler },
	{ .name = "unset", .handler = molly_ubus_handler },
	{ .name = "destroy", .handler = molly_ubus_handler },
	{ .name = "login", .handler = molly_ubus_handler },
};

static struct ubus_method uci_methods[] = {
	{ .name = "configs", .handler = molly_ubus_handler },
	{ .name = "get", .handler = molly_ubus_handler },
	{ .name = "state", .handler = molly_ubus_handler },
	{ .name = "add", .handler = molly_ubus_handler },
	{ .name = "set", .handler = molly_ubus_handler },
	{ .name = "delete", .handler = molly_ubus_handler },
	{ .name = "rename", .handler = molly_ubus_handler },
	{ .name = "order", .handler = molly_ubus_handler },
	{ .name = "changes", .handler = molly_ubus_handler },
	{ .name = "revert", .handler = molly_ubus_handler },
	{ .name = "commit", .handler = molly_ubus_handler },
	{ .name = "apply", .handler = molly_ubus_handler },
	{ .name = "confirm", .handler = molly_ubus_handler },
	{ .name = "rollback", .handler = molly_ubus_handler },
	{ .name = "reload_config", .handler = molly_ubus_handler },
};

static struct ubus_method file_methods[] = {
	{ .name = "read", .handler = molly_ubus_handler },
	{ .name = "write", .handler = molly_ubus_handler },
	{ .name = "list", .handler = molly_ubus_handler },
	{ .name = "lstat", .handler = molly_ubus_handler },
	{ .name = "stat", .handler = molly_ubus_handler },
	{ .name = "md5", .handler = molly_ubus_handler },
	{ .name = "remove", .handler = molly_ubus_handler },
	{ .name = "exec", .handler = molly_ubus_handler },
};

static struct ubus_method luci_methods[] = {
	{ .name = "getNetworkDevices", .handler = molly_ubus_handler },
	{ .name = "getWirelessDevices", .handler = molly_ubus_handler },
	{ .name = "getHostHints", .handler = molly_ubus_handler },
	{ .name = "getDUIDHints", .handler = molly_ubus_handler },
	{ .name = "getBoardJSON", .handler = molly_ubus_handler },
	{ .name = "getDHCPLeases", .handler = molly_ubus_handler },
};

static struct ubus_method probe_methods[] = {
	{ .name = "ping", .handler = molly_ubus_handler },
	{ .name = "notify", .handler = molly_ubus_handler },
};

#define MOLLY_OBJECT_TYPE(_name, _methods) \
	static struct ubus_object_type _name##_type = { \
		.name = #_name, \
		.methods = _methods, \
		.n_methods = (int)(sizeof(_methods) / sizeof(_methods[0])), \
	}

MOLLY_OBJECT_TYPE(session, session_methods);
MOLLY_OBJECT_TYPE(uci, uci_methods);
MOLLY_OBJECT_TYPE(file, file_methods);
MOLLY_OBJECT_TYPE(luci, luci_methods);

// 注意 `luci-rpc` / `molly.probe` 带点号，不能进宏名 → 单独写。
static struct ubus_object_type luci_rpc_type = { .name = "luci-rpc",
	.methods = luci_methods,
	.n_methods = (int)(sizeof(luci_methods) / sizeof(luci_methods[0])) };
static struct ubus_object_type probe_type = { .name = "molly.probe",
	.methods = probe_methods,
	.n_methods = (int)(sizeof(probe_methods) / sizeof(probe_methods[0])) };

static struct ubus_object g_objects[] = {
	{ .name = "session", .type = &session_type, .methods = session_methods,
	  .n_methods = (int)(sizeof(session_methods) / sizeof(session_methods[0])) },
	{ .name = "uci", .type = &uci_type, .methods = uci_methods,
	  .n_methods = (int)(sizeof(uci_methods) / sizeof(uci_methods[0])) },
	{ .name = "file", .type = &file_type, .methods = file_methods,
	  .n_methods = (int)(sizeof(file_methods) / sizeof(file_methods[0])) },
	{ .name = "luci-rpc", .type = &luci_rpc_type, .methods = luci_methods,
	  .n_methods = (int)(sizeof(luci_methods) / sizeof(luci_methods[0])) },
	{ .name = "molly.probe", .type = &probe_type, .methods = probe_methods,
	  .n_methods = (int)(sizeof(probe_methods) / sizeof(probe_methods[0])) },
};

static void *molly_server_thread(void *arg) {
	const char *socket_path = (const char *)arg;

	g_server_ctx = ubus_connect(socket_path);
	if (g_server_ctx == NULL) {
		fprintf(stderr, "[molly] ubus 服务线程：连接 ubusd 失败\n");
		return NULL;
	}

	// libubox uloop 默认装 SIGCHLD 处理并在 uloop_handle_processes() 里用
	// waitpid(-1, WNOHANG) 抢收「任意」子进程。molly 从不 uloop_add_process，却在
	// HTTP worker 线程里用 Odin os.process_exec（file.exec / --luci-cgi）fork 子进程：
	// 子进程被 uloop 抢先收尸后，Odin _reap_terminated 的 waitid(pid) 得 ECHILD、
	// info.code 保持 0，命中其 `case .NONE: unreachable()` → SIGTRAP 崩整个进程。
	// 关掉 uloop 的 SIGCHLD 接管即可（不影响 ubus/uloop 的 fd/timer 事件）。
	uloop_handle_sigchld = false;
	uloop_init();
	ubus_add_uloop(g_server_ctx);

	for (size_t i = 0; i < sizeof(g_objects) / sizeof(g_objects[0]); i++) {
		int rc = ubus_add_object(g_server_ctx, &g_objects[i]);
		if (rc != 0) {
			// 逐对象注册失败只打诊断、非致命（rpcd 还在跑时就是这种情况）。
			fprintf(stderr, "[molly] ubus 服务线程：注册 %s 失败（rpcd 还在跑？"
			                "先 /etc/init.d/rpcd stop），错误码 %d\n",
			        g_objects[i].name, rc);
		}
	}

	g_server_started = 1;
	while (!g_server_stop)
		uloop_run_timeout(100);

	uloop_done();
	ubus_free(g_server_ctx);
	g_server_ctx = NULL;
	return NULL;
}

int molly_ubus_start_server(const char *socket_path) {
	if (g_server_tid != 0)
		return 0;
	// socket_path 进程生命周期内有效（Go 侧用 C.CString 长期持有）。
	if (pthread_create(&g_server_tid, NULL, molly_server_thread, (void *)socket_path) != 0) {
		fprintf(stderr, "[molly] 创建 ubus 服务线程失败\n");
		return -1;
	}
	return 0;
}

void molly_ubus_stop_server(void) {
	if (g_server_tid == 0)
		return;
	g_server_stop = 1;
	pthread_join(g_server_tid, NULL);
	g_server_tid = 0;
}

// ---------------------------------------------------------------------------
// uci 读
// ---------------------------------------------------------------------------

static struct blob_buf g_uci_buf;

// 建一个带指定 delta 目录的短命 context（对应 Odin 的 uci_ctx_with_savedir）。
static struct uci_context *molly_uci_ctx_savedir(const char *savedir) {
	struct uci_context *ctx = uci_alloc_context();
	if (ctx == NULL)
		return NULL;
	if (savedir != NULL && uci_set_savedir(ctx, savedir) != 0) {
		uci_free_context(ctx);
		return NULL;
	}
	return ctx;
}

// 把一个 package 的 section 全部写成 JSON 数组的 children。
static void molly_uci_append_sections(struct blob_buf *buf, struct uci_package *pkg) {
	struct uci_element *el;
	uci_foreach_element(&pkg->sections, el) {
		struct uci_section *s = uci_to_section(el);
		void *st = blobmsg_open_table(buf, NULL);
		blobmsg_add_string(buf, "name", s->e.name ? s->e.name : "");
		blobmsg_add_string(buf, "type", s->type ? s->type : "");
		blobmsg_add_u32(buf, "anonymous", s->anonymous ? 1 : 0);

		void *opts = blobmsg_open_array(buf, "options");
		struct uci_element *oel;
		uci_foreach_element(&s->options, oel) {
			struct uci_option *o = uci_to_option(oel);
			if (o == NULL)
				continue;
			void *ot = blobmsg_open_table(buf, NULL);
			blobmsg_add_string(buf, "name", o->e.name ? o->e.name : "");
			int is_list = (o->type == UCI_TYPE_LIST);
			blobmsg_add_u32(buf, "list", is_list ? 1 : 0);
			void *vals = blobmsg_open_array(buf, "values");
			if (is_list) {
				struct uci_element *vel;
				uci_foreach_element(&o->v.list, vel) {
					blobmsg_add_string(buf, NULL, vel->name ? vel->name : "");
				}
			} else if (o->v.string != NULL) {
				blobmsg_add_string(buf, NULL, o->v.string);
			}
			blobmsg_close_array(buf, vals);
			blobmsg_close_table(buf, ot);
		}
		blobmsg_close_array(buf, opts);
		blobmsg_close_table(buf, st);
	}
}

int molly_uci_sections(const char *config, const char *savedir, char **out) {
	*out = NULL;
	struct uci_context *ctx = molly_uci_ctx_savedir(savedir);
	if (ctx == NULL)
		return UBUS_STATUS_UNKNOWN_ERROR;

	struct uci_package *pkg = NULL;
	int e = uci_load(ctx, config, &pkg);
	if (e != UCI_OK || pkg == NULL) {
		uci_free_context(ctx);
		return UBUS_STATUS_NOT_FOUND;
	}

	blobmsg_buf_init(&g_uci_buf);
	void *arr = blobmsg_open_array(&g_uci_buf, NULL);
	molly_uci_append_sections(&g_uci_buf, pkg);
	blobmsg_close_array(&g_uci_buf, arr);

	char *js = molly_format_json_sole_child(&g_uci_buf);
	uci_unload(ctx, pkg);
	uci_free_context(ctx);
	if (js == NULL)
		return UBUS_STATUS_NO_MEMORY;
	*out = js;
	return 0;
}

int molly_uci_list_configs(char **out) {
	*out = NULL;
	struct uci_context *ctx = molly_uci_ctx_savedir(NULL);
	if (ctx == NULL)
		return UBUS_STATUS_UNKNOWN_ERROR;

	char **list = NULL;
	int e = uci_list_configs(ctx, &list);
	if (e != UCI_OK || list == NULL) {
		uci_free_context(ctx);
		return UBUS_STATUS_NOT_FOUND;
	}

	blobmsg_buf_init(&g_uci_buf);
	void *arr = blobmsg_open_array(&g_uci_buf, NULL);
	for (char **it = list; *it != NULL; it++)
		blobmsg_add_string(&g_uci_buf, NULL, *it);
	blobmsg_close_array(&g_uci_buf, arr);

	char *js = molly_format_json_sole_child(&g_uci_buf);

	// 只释放数组本身：file backend 的 uci_list_config_files（file.c:887-905）用**一次**
	// calloc 分配「指针数组 + 紧随其后的拼接字符串」，每个元素都指向块内部
	// （configs[j] = buf; buf += strlen(buf)+1）。对内部指针调 free 是非法释放，
	// 会破坏 musl 堆并在后续调用中 SIGSEGV。上游 uci CLI 的用法就是只 free 数组
	// （cli.c:426-437 `free(configs)`），uci.h:249 也只说「释放 list 背后的内存」。
	free(list);
	uci_free_context(ctx);

	if (js == NULL)
		return UBUS_STATUS_NO_MEMORY;
	*out = js;
	return 0;
}

// ---------------------------------------------------------------------------
// libc：密码校验（session.c:819-853 + getspnam）
// ---------------------------------------------------------------------------

// /etc/shadow 的第二字段（Odin linux.odin:1116-1142）。
static int molly_shadow_hash(const char *name, char *out, size_t out_len) {
	FILE *f = fopen("/etc/shadow", "r");
	if (f == NULL)
		return 0;

	char line[512];
	int found = 0;
	while (fgets(line, sizeof(line), f) != NULL) {
		char *colon = strchr(line, ':');
		if (colon == NULL || colon == line)
			continue;
		if ((size_t)(colon - line) != strlen(name) || strncmp(line, name, colon - line) != 0)
			continue;
		char *fields = colon + 1;
		char *c2 = strchr(fields, ':');
		size_t n = c2 ? (size_t)(c2 - fields) : strlen(fields);
		if (n >= out_len)
			n = out_len - 1;
		memcpy(out, fields, n);
		out[n] = '\0';
		found = 1;
		break;
	}
	fclose(f);
	return found;
}

int molly_verify_password(const char *hash, const char *password) {
	if (hash == NULL || hash[0] == '\0')
		return 1; // 没设密码 → 任何密码都通过

	if (strncmp(hash, "$p$", 3) == 0) {
		const char *name = hash + 3;
		if (name[0] == '\0')
			return 0;
		char shadow[256];
		if (!molly_shadow_hash(name, shadow, sizeof(shadow)))
			return 0;
		return molly_verify_password(shadow, password);
	}

	// crypt 返回内部静态缓冲：本函数只在单一调用点串行调用。
	char *got = crypt(password, hash);
	if (got == NULL)
		return 0;
	return strcmp(got, hash) == 0;
}

// ---------------------------------------------------------------------------
// uci 写路径（P3-3 S3）+ delta / commit / revert / apply
//
// 逐字对齐 Odin 版 src/backend/linux.odin:1391-1987 的语义。状态码一律 ubus 风格
// （0 / 2 INVALID_ARGUMENT / 4 NOT_FOUND / 8 NOT_SUPPORTED / 9 UNKNOWN_ERROR）。
// 所有指针都在 Go 侧用一把 uci 锁串行化（C 库非线程安全），这里不再加锁。
// ---------------------------------------------------------------------------

// 会话的 savedir：/var/run/rpcd/uci-<sid>；无 sid（内部调用）用 /tmp/.uci
// （linux.odin:1394-1399 uci_savedir_of）。
static void molly_savedir_of(const char *sid, char *buf, size_t n) {
	if (sid == NULL || sid[0] == '\0')
		snprintf(buf, n, "%s", "/tmp/.uci");
	else
		snprintf(buf, n, "/var/run/rpcd/uci-%s", sid);
}

int molly_uci_delta(const char *sid, const char *config, char **out) {
	*out = NULL;

	char savedir[256];
	molly_savedir_of(sid, savedir, sizeof(savedir));

	struct uci_context *ctx = molly_uci_ctx_savedir(savedir);
	if (ctx == NULL)
		return UBUS_STATUS_UNKNOWN_ERROR;

	struct uci_package *pkg = NULL;
	if (uci_load(ctx, config, &pkg) != UCI_OK || pkg == NULL) {
		uci_free_context(ctx);
		return UBUS_STATUS_NOT_FOUND;
	}

	blobmsg_buf_init(&g_uci_buf);
	void *arr = blobmsg_open_array(&g_uci_buf, NULL);

	struct uci_element *el;
	uci_foreach_element(&pkg->saved_delta, el) {
		struct uci_delta *d = uci_to_delta(el);
		void *t = blobmsg_open_table(&g_uci_buf, NULL);
		blobmsg_add_u32(&g_uci_buf, "cmd", (uint32_t)d->cmd);
		blobmsg_add_string(&g_uci_buf, "section", d->section ? d->section : "");
		blobmsg_add_string(&g_uci_buf, "name", el->name ? el->name : "");
		blobmsg_add_string(&g_uci_buf, "value", d->value ? d->value : "");
		blobmsg_close_table(&g_uci_buf, t);
	}
	blobmsg_close_array(&g_uci_buf, arr);

	char *js = molly_format_json_sole_child(&g_uci_buf);
	uci_unload(ctx, pkg);
	uci_free_context(ctx);
	if (js == NULL)
		return UBUS_STATUS_NO_MEMORY;
	*out = js;
	return UBUS_STATUS_OK;
}

// --- 写事务 ---------------------------------------------------------------

struct molly_uci_txn {
	struct uci_context *ctx;
	struct uci_package *pkg;
	char *config;
};

struct molly_uci_txn *molly_uci_txn_begin(const char *config, const char *savedir, int *status) {
	*status = UBUS_STATUS_OK;

	struct uci_context *ctx = molly_uci_ctx_savedir(savedir);
	if (ctx == NULL) {
		*status = UBUS_STATUS_UNKNOWN_ERROR;
		return NULL;
	}

	struct uci_package *pkg = NULL;
	if (uci_load(ctx, config, &pkg) != UCI_OK || pkg == NULL) {
		uci_free_context(ctx);
		*status = UBUS_STATUS_NOT_FOUND;
		return NULL;
	}

	struct molly_uci_txn *t = calloc(1, sizeof(*t));
	if (t == NULL) {
		uci_unload(ctx, pkg);
		uci_free_context(ctx);
		*status = UBUS_STATUS_UNKNOWN_ERROR;
		return NULL;
	}
	t->ctx = ctx;
	t->pkg = pkg;
	t->config = strdup(config);
	return t;
}

void molly_uci_txn_end(struct molly_uci_txn *t) {
	if (t == NULL)
		return;
	if (t->ctx != NULL && t->pkg != NULL)
		uci_unload(t->ctx, t->pkg);
	if (t->ctx != NULL)
		uci_free_context(t->ctx);
	free(t->config);
	free(t);
}

char *molly_uci_txn_sections(struct molly_uci_txn *t) {
	if (t == NULL)
		return NULL;
	blobmsg_buf_init(&g_uci_buf);
	void *arr = blobmsg_open_array(&g_uci_buf, NULL);
	molly_uci_append_sections(&g_uci_buf, t->pkg);
	blobmsg_close_array(&g_uci_buf, arr);
	return molly_format_json_sole_child(&g_uci_buf);
}

int molly_uci_txn_section_exists(struct molly_uci_txn *t, const char *section) {
	if (t == NULL)
		return 0;
	struct uci_ptr ptr = { .package = t->config, .section = section };
	if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK)
		return 0;
	return ptr.s != NULL ? 1 : 0;
}

int molly_uci_txn_add_section(struct molly_uci_txn *t, const char *type, const char *name,
                              char **out_name) {
	*out_name = NULL;
	if (t == NULL)
		return UBUS_STATUS_NOT_SUPPORTED;

	// 具名 section 走 uci_set（ptr.value = type，uci.c:713-722）
	if (name != NULL && name[0] != '\0') {
		struct uci_ptr ptr = {
			.package = t->config,
			.section = name,
			.value = type,
		};
		if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK)
			return UBUS_STATUS_NOT_FOUND;
		if (uci_set(t->ctx, &ptr) != UCI_OK)
			return UBUS_STATUS_UNKNOWN_ERROR;
		*out_name = strdup(name);
		return UBUS_STATUS_OK;
	}

	// 匿名 section：名字由 libuci 生成（uci.c:724-731）
	struct uci_section *sec = NULL;
	if (uci_add_section(t->ctx, t->pkg, type, &sec) != UCI_OK || sec == NULL)
		return UBUS_STATUS_UNKNOWN_ERROR;
	*out_name = strdup(sec->e.name ? sec->e.name : "");
	return UBUS_STATUS_OK;
}

int molly_uci_txn_option_state(struct molly_uci_txn *t, const char *section, const char *option,
                               int *exists, int *is_list, char **value) {
	*exists = 0;
	*is_list = 0;
	*value = NULL;
	if (t == NULL)
		return UBUS_STATUS_NOT_SUPPORTED;

	struct uci_ptr ptr = {
		.package = t->config,
		.section = section,
		.option = option,
	};
	if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK || ptr.s == NULL || ptr.o == NULL)
		return UBUS_STATUS_OK; // 不存在也算成功：exists = 0

	*exists = 1;
	*is_list = (ptr.o->type == UCI_TYPE_LIST) ? 1 : 0;
	if (!*is_list && ptr.o->v.string != NULL)
		*value = strdup(ptr.o->v.string);
	return UBUS_STATUS_OK;
}

// option 为空 → 删整个 section；否则删该 option。找不到回 4。
int molly_uci_txn_delete(struct molly_uci_txn *t, const char *section, const char *option) {
	if (t == NULL)
		return UBUS_STATUS_NOT_SUPPORTED;

	int named = (option != NULL && option[0] != '\0');
	struct uci_ptr ptr = { .package = t->config, .section = section };
	if (named)
		ptr.option = option;

	if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK || ptr.s == NULL)
		return UBUS_STATUS_NOT_FOUND;
	if (named && ptr.o == NULL)
		return UBUS_STATUS_NOT_FOUND;
	if (uci_delete(t->ctx, &ptr) != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;
	return UBUS_STATUS_OK;
}

int molly_uci_txn_set(struct molly_uci_txn *t, const char *section, const char *option,
                      const char *value) {
	if (t == NULL)
		return UBUS_STATUS_NOT_SUPPORTED;
	struct uci_ptr ptr = {
		.package = t->config,
		.section = section,
		.option = option,
		.value = value,
	};
	if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK || ptr.s == NULL)
		return UBUS_STATUS_NOT_FOUND;
	if (uci_set(t->ctx, &ptr) != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;
	return UBUS_STATUS_OK;
}

int molly_uci_txn_add_list(struct molly_uci_txn *t, const char *section, const char *option,
                           const char *value) {
	if (t == NULL)
		return UBUS_STATUS_NOT_SUPPORTED;
	struct uci_ptr ptr = {
		.package = t->config,
		.section = section,
		.option = option,
		.value = value,
	};
	if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK || ptr.s == NULL)
		return UBUS_STATUS_NOT_FOUND;
	if (uci_add_list(t->ctx, &ptr) != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;
	return UBUS_STATUS_OK;
}

// option 为空 → 重命名 section；否则重命名 option（linux.odin:1882-1911）。
int molly_uci_txn_rename(struct molly_uci_txn *t, const char *section, const char *option,
                         const char *new_name) {
	if (t == NULL)
		return UBUS_STATUS_NOT_SUPPORTED;

	int named = (option != NULL && option[0] != '\0');
	struct uci_ptr ptr = {
		.package = t->config,
		.section = section,
		.value = new_name,
	};
	if (named)
		ptr.option = option;

	if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK)
		return UBUS_STATUS_NOT_FOUND;
	if ((named && ptr.o == NULL) || ptr.s == NULL)
		return UBUS_STATUS_NOT_FOUND;
	if (uci_rename(t->ctx, &ptr) != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;
	return UBUS_STATUS_OK;
}

// 返回「找到了吗」（0/1）；rpcd 忽略 uci_reorder_section 的返回值（linux.odin:1915-1930）。
int molly_uci_txn_reorder(struct molly_uci_txn *t, const char *section, int pos) {
	if (t == NULL)
		return 0;
	struct uci_ptr ptr = { .package = t->config, .section = section };
	if (uci_lookup_ptr(t->ctx, &ptr, NULL, true) != UCI_OK || ptr.s == NULL)
		return 0;
	uci_reorder_section(t->ctx, ptr.s, pos);
	return 1;
}

int molly_uci_txn_save(struct molly_uci_txn *t) {
	if (t == NULL)
		return UBUS_STATUS_NOT_SUPPORTED;
	if (uci_save(t->ctx, t->pkg) != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;
	return UBUS_STATUS_OK;
}

// --- commit / revert / apply / reload -------------------------------------

// uci.c:1304-1321 rpc_uci_trigger_event：找 `service` 对象、调 event 方法，1s 超时。
// 与上游一致，用**服务线程**的连接、同步调用（服务线程没起来就什么都不做）。
static void molly_uci_trigger_event(const char *config) {
	if (g_server_ctx == NULL)
		return;

	uint32_t id;
	if (ubus_lookup_id(g_server_ctx, "service", &id) != 0)
		return;

	struct blob_buf b;
	memset(&b, 0, sizeof(b));
	blobmsg_buf_init(&b);

	blobmsg_add_string(&b, "type", "config.change");
	void *data = blobmsg_open_table(&b, "data");
	blobmsg_add_string(&b, "package", config);
	blobmsg_close_table(&b, data);

	ubus_invoke_fd(g_server_ctx, id, "event", b.head, NULL, NULL, 1000, -1);
	blob_buf_free(&b);
}

// uci.c:1344-1351：load → uci_commit(false) → unload → 触发事件。
int molly_uci_commit(const char *sid, const char *config) {
	char savedir[256];
	molly_savedir_of(sid, savedir, sizeof(savedir));

	struct uci_context *ctx = molly_uci_ctx_savedir(savedir);
	if (ctx == NULL)
		return UBUS_STATUS_UNKNOWN_ERROR;

	struct uci_package *pkg = NULL;
	if (uci_load(ctx, config, &pkg) != UCI_OK || pkg == NULL) {
		uci_free_context(ctx);
		return UBUS_STATUS_NOT_FOUND;
	}

	int rc = uci_commit(ctx, &pkg, false);
	uci_unload(ctx, pkg);
	uci_free_context(ctx);
	if (rc != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;

	molly_uci_trigger_event(config);
	return UBUS_STATUS_OK;
}

// uci.c:1353-1360：uci_lookup_ptr(package) → uci_revert → unload。
int molly_uci_revert(const char *sid, const char *config) {
	char savedir[256];
	molly_savedir_of(sid, savedir, sizeof(savedir));

	struct uci_context *ctx = molly_uci_ctx_savedir(savedir);
	if (ctx == NULL)
		return UBUS_STATUS_UNKNOWN_ERROR;

	struct uci_ptr ptr = { .package = config };
	if (uci_lookup_ptr(ctx, &ptr, NULL, true) != UCI_OK || ptr.p == NULL) {
		uci_free_context(ctx);
		return UBUS_STATUS_NOT_FOUND;
	}

	int rc = uci_revert(ctx, &ptr);
	uci_unload(ctx, ptr.p);
	uci_free_context(ctx);
	if (rc != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;
	return UBUS_STATUS_OK;
}

// uci.c:1443-1455：load → commit → unload → 事件。load 失败也照样触发事件
// （上游忽略），只是不提交（linux.odin:1953-1959）。
int molly_uci_apply_config(const char *config, int no_delta) {
	// no_delta 时 savedir 指向 /dev/null：libuci 在那里找不到 delta 文件，
	// 于是 uci_load 不会把当前未提交的改动合进来（回滚路径用）。
	struct uci_context *ctx = molly_uci_ctx_savedir(no_delta ? "/dev/null" : "/tmp/.uci");
	if (ctx == NULL)
		return UBUS_STATUS_UNKNOWN_ERROR;

	struct uci_package *pkg = NULL;
	if (uci_load(ctx, config, &pkg) != UCI_OK || pkg == NULL) {
		uci_free_context(ctx);
		molly_uci_trigger_event(config);
		return UBUS_STATUS_OK;
	}

	int rc = uci_commit(ctx, &pkg, false);
	uci_unload(ctx, pkg);
	uci_free_context(ctx);
	molly_uci_trigger_event(config);
	if (rc != UCI_OK)
		return UBUS_STATUS_UNKNOWN_ERROR;
	return UBUS_STATUS_OK;
}

// uci.c:1720-1734：fork 后 sleep(2)（等这次 RPC 的响应发出去）再 exec /sbin/reload_config；
// 父进程立刻返回 0。
int molly_reload_config(void) {
	pid_t pid = fork();
	if (pid < 0)
		return UBUS_STATUS_UNKNOWN_ERROR;
	if (pid == 0) {
		sleep(2);
		char *argv[] = { "/sbin/reload_config", NULL };
		execv(argv[0], argv);
		_exit(127);
	}
	return UBUS_STATUS_OK;
}

// ---------------------------------------------------------------------------
// 子进程 spawn（file.exec / --luci-cgi / cgi-io / 改密码共用）
//
// 不用 Odin core:os 的 process_exec：它在 _reap_terminated 里对 waitid 返回的
// info.code 做 switch，一旦子进程被别的收尸者抢先回收（服务线程里 libubox uloop
// 的 waitpid(-1) 就是这种角色），waitid 返 ECHILD、info 未填充、code=0，命中
// `case .NONE: unreachable()` → 裸 SIGTRAP 崩掉整个进程。这里自带
// fork/dup2/execv/poll/waitpid，waitpid 只等自己的 pid 且容忍 ECHILD、绝不 trap。
// 语义对齐 Go 的 os/exec。
// ---------------------------------------------------------------------------

typedef struct {
	char *data;
	size_t len;
	size_t cap;
} molly_sbuf;

// 追加一段输出；按翻倍扩容直到命令的实际输出大小——**不截断**。原因：cgi-exec / cgi-backup
// （fs.exec_direct 的软件包列表、sysupgrade -b - 的归档）走同一条 spawn_run，需要回全量；
// 早先这里有个 1MiB 固定上限，把 >1MiB 的 `apk query` JSON 从中间切断，前端 JSON.parse 报
// "Unterminated string"。file.exec 的 64KiB 上限在其调用层单独把关（file_object.odin），与本
// 缓冲无关，所以这里放开不影响 file.exec 的观测契约。realloc 失败则尽力保留已有、丢弃本段。
static void molly_sbuf_append(molly_sbuf *s, const char *p, size_t n) {
	if (n == 0)
		return;
	if (s->len + n + 1 > s->cap) {
		size_t nw = s->cap ? s->cap : 4096;
		while (nw < s->len + n + 1)
			nw *= 2;
		char *nd = (char *)realloc(s->data, nw);
		if (nd == NULL)
			return; // OOM：这段丢弃，尽力而为
		s->data = nd;
		s->cap = nw;
	}
	memcpy(s->data + s->len, p, n);
	s->len += n;
	s->data[s->len] = '\0';
}

// 在 PATH 里找 name（无 '/' 时调用）；envp 非空则用它的 PATH，否则 getenv。命中写进 out 回 1。
static int molly_spawn_find_path(const char *name, char *out, size_t outsz, char *const envp[]) {
	const char *path = NULL;
	if (envp) {
		for (char *const *e = envp; *e; e++) {
			if (strncmp(*e, "PATH=", 5) == 0) {
				path = *e + 5;
				break;
			}
		}
	}
	if (path == NULL)
		path = getenv("PATH");
	if (path == NULL || *path == '\0')
		path = "/bin:/usr/bin:/sbin:/usr/sbin";
	size_t namelen = strlen(name);
	const char *s = path;
	while (s) {
		const char *colon = strchr(s, ':');
		size_t dirlen = colon ? (size_t)(colon - s) : strlen(s);
		if (dirlen > 0 && dirlen + 1 + namelen + 1 <= outsz) {
			char cand[1024];
			if (dirlen + 1 + namelen + 1 <= sizeof(cand)) {
				memcpy(cand, s, dirlen);
				cand[dirlen] = '/';
				memcpy(cand + dirlen + 1, name, namelen + 1);
				if (access(cand, X_OK) == 0) {
					snprintf(out, outsz, "%s", cand);
					return 1;
				}
			}
		}
		s = colon ? colon + 1 : NULL;
	}
	return 0;
}

int molly_spawn(char *const argv[], char *const envp[],
                const char *stdin_data, int stdin_len,
                int capture_stderr,
                char **out_stdout, int *out_stdout_len,
                char **out_stderr, int *out_stderr_len,
                int *out_exited, int *out_code) {
	if (out_stdout)
		*out_stdout = NULL;
	if (out_stdout_len)
		*out_stdout_len = 0;
	if (out_stderr)
		*out_stderr = NULL;
	if (out_stderr_len)
		*out_stderr_len = 0;
	if (out_exited)
		*out_exited = 0;
	if (out_code)
		*out_code = 0;
	if (argv == NULL || argv[0] == NULL) {
		errno = EINVAL;
		return -1;
	}

	// 解析可执行路径（对齐 os._process_start 在父进程做 PATH 查找）。
	char exe[1024];
	if (strchr(argv[0], '/') != NULL)
		snprintf(exe, sizeof(exe), "%s", argv[0]);
	else if (!molly_spawn_find_path(argv[0], exe, sizeof(exe), envp))
		return -1; // 找不到可执行 → 未启动

	int outp[2] = { -1, -1 }, errp[2] = { -1, -1 }, inp[2] = { -1, -1 }, syncp[2] = { -1, -1 };
	int have_stdin = (stdin_data != NULL && stdin_len >= 0);
	molly_sbuf ob = { 0 }, eb = { 0 };
	int rc = -1;
	pid_t pid;

	if (pipe(outp) != 0)
		goto done;
	if (capture_stderr && pipe(errp) != 0)
		goto done;
	if (have_stdin && pipe(inp) != 0)
		goto done;
	if (pipe(syncp) != 0)
		goto done;
	// syncp 写端 CLOEXEC：exec 成功即自动关闭 → 父读到 EOF；exec 失败则子写 errno 字节。
	fcntl(syncp[1], F_SETFD, FD_CLOEXEC);

	pid = fork();
	if (pid < 0)
		goto done;

	if (pid == 0) {
		// ---- 子进程 ----
		if (dup2(outp[1], STDOUT_FILENO) < 0)
			_exit(127);
		if (capture_stderr && dup2(errp[1], STDERR_FILENO) < 0)
			_exit(127);
		// capture_stderr==0 时不动 fd 2：子进程 stderr 继承 molly 的 fd 2（转发）。
		if (have_stdin) {
			if (dup2(inp[0], STDIN_FILENO) < 0)
				_exit(127);
		} else {
			int dn = open("/dev/null", O_RDONLY);
			if (dn >= 0) {
				if (dn != STDIN_FILENO) {
					dup2(dn, STDIN_FILENO);
					close(dn);
				}
			}
		}
		// 关掉本进程不需要的管道口（尤其读端，否则父读不到 EOF）。
		close(outp[0]);
		close(outp[1]);
		if (errp[0] >= 0) {
			close(errp[0]);
			close(errp[1]);
		}
		if (inp[0] >= 0) {
			close(inp[0]);
			close(inp[1]);
		}
		close(syncp[0]);
		// syncp[1] 留着（CLOEXEC）：exec 成功自动关，失败则下面写 errno。
		if (envp != NULL)
			execve(exe, argv, envp);
		else
			execv(exe, argv);
		int e = errno;
		unsigned char b = (unsigned char)(e > 0 && e < 256 ? e : 1);
		ssize_t w = write(syncp[1], &b, 1);
		(void)w;
		_exit(127);
	}

	// ---- 父进程 ----
	close(outp[1]);
	outp[1] = -1;
	if (errp[1] >= 0) {
		close(errp[1]);
		errp[1] = -1;
	}
	if (inp[0] >= 0) {
		close(inp[0]);
		inp[0] = -1;
	}
	close(syncp[1]);
	syncp[1] = -1;

	// 先判 exec 成败：读到 1 字节 → 子进程 exec 失败；EOF(0) → 成功。
	{
		unsigned char b = 0;
		ssize_t r;
		do {
			r = read(syncp[0], &b, 1);
		} while (r < 0 && errno == EINTR);
		close(syncp[0]);
		syncp[0] = -1;
		if (r == 1) {
			// exec 失败：子进程已 _exit(127)。收掉它，报「未启动」(rc 保持 -1)。
			int st = 0;
			while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
			errno = (int)b;
			goto done;
		}
	}

	// 边读 stdout/stderr 边写 stdin（poll 多路复用，避免大 body/大输出死锁）。
	{
		int out_done = 0;
		int err_done = (!capture_stderr);
		int in_done = (!have_stdin);
		size_t in_off = 0;
		char rbuf[8192];
		while (!out_done || !err_done || !in_done) {
			struct pollfd pfds[3];
			nfds_t np = 0;
			int io_out = -1, io_err = -1, io_in = -1;
			if (!out_done) {
				io_out = (int)np;
				pfds[np].fd = outp[0];
				pfds[np].events = POLLIN;
				pfds[np].revents = 0;
				np++;
			}
			if (!err_done && capture_stderr) {
				io_err = (int)np;
				pfds[np].fd = errp[0];
				pfds[np].events = POLLIN;
				pfds[np].revents = 0;
				np++;
			}
			if (!in_done) {
				io_in = (int)np;
				pfds[np].fd = inp[1];
				pfds[np].events = POLLOUT;
				pfds[np].revents = 0;
				np++;
			}
			if (np == 0)
				break;
			if (poll(pfds, np, -1) < 0) {
				if (errno == EINTR)
					continue;
				break;
			}
			if (io_out >= 0 && (pfds[io_out].revents & (POLLIN | POLLHUP | POLLERR))) {
				ssize_t r = read(outp[0], rbuf, sizeof(rbuf));
				if (r > 0)
					molly_sbuf_append(&ob, rbuf, (size_t)r);
				else if (r == 0)
					out_done = 1;
				else if (errno != EINTR && errno != EAGAIN)
					out_done = 1;
			}
			if (io_err >= 0 && (pfds[io_err].revents & (POLLIN | POLLHUP | POLLERR))) {
				ssize_t r = read(errp[0], rbuf, sizeof(rbuf));
				if (r > 0)
					molly_sbuf_append(&eb, rbuf, (size_t)r);
				else if (r == 0)
					err_done = 1;
				else if (errno != EINTR && errno != EAGAIN)
					err_done = 1;
			}
			if (io_in >= 0 && (pfds[io_in].revents & (POLLOUT | POLLERR | POLLHUP))) {
				if (in_off >= (size_t)stdin_len) {
					close(inp[1]);
					inp[1] = -1;
					in_done = 1;
				} else {
					ssize_t w = write(inp[1], stdin_data + in_off, (size_t)stdin_len - in_off);
					if (w > 0)
						in_off += (size_t)w;
					else if (w < 0 && errno != EINTR) {
						close(inp[1]);
						inp[1] = -1;
						in_done = 1; // EPIPE：子进程不收，剩下丢弃
					}
				}
			}
		}
		if (inp[1] >= 0) {
			close(inp[1]);
			inp[1] = -1;
		}
	}

	// 收尾：只等自己的 pid；ECHILD（被别人抢先收）当作正常退出码 0，绝不 trap。
	{
		int st = 0;
		pid_t w;
		do {
			w = waitpid(pid, &st, 0);
		} while (w < 0 && errno == EINTR);
		if (w > 0) {
			if (WIFEXITED(st)) {
				if (out_exited)
					*out_exited = 1;
				if (out_code)
					*out_code = WEXITSTATUS(st);
			} else if (WIFSIGNALED(st)) {
				if (out_exited)
					*out_exited = 0;
				if (out_code)
					*out_code = WTERMSIG(st);
			}
		} else {
			if (out_exited)
				*out_exited = 1;
			if (out_code)
				*out_code = 0;
		}
	}

	if (out_stdout) {
		*out_stdout = ob.data;
		ob.data = NULL; // 所有权移交 out_stdout
	}
	if (out_stdout_len)
		*out_stdout_len = (int)ob.len;
	if (out_stderr) {
		*out_stderr = eb.data;
		eb.data = NULL;
	}
	if (out_stderr_len)
		*out_stderr_len = (int)eb.len;
	rc = 0;

done:
	if (outp[0] >= 0)
		close(outp[0]);
	if (outp[1] >= 0)
		close(outp[1]);
	if (errp[0] >= 0)
		close(errp[0]);
	if (errp[1] >= 0)
		close(errp[1]);
	if (inp[0] >= 0)
		close(inp[0]);
	if (inp[1] >= 0)
		close(inp[1]);
	if (syncp[0] >= 0)
		close(syncp[0]);
	if (syncp[1] >= 0)
		close(syncp[1]);
	if (ob.data)
		free(ob.data);
	if (eb.data)
		free(eb.data);
	return rc;
}

// ---------------------------------------------------------------------------
// luci-rpc：getifaddrs / netlink 邻居 / iwinfo
//
// 对应 Odin src/backend/linux.odin:2179-3200（getifaddrs + netlink）与
// src/backend/iwinfo.odin（dlopen libiwinfo）。C 结构体布局与协议字节解析留在这边，
// Go 侧只拿 JSON。全部用**局部** blob_buf，不碰共享全局（这些函数不经 ubusMu）。
// ---------------------------------------------------------------------------

static void molly_mac_text(const unsigned char *b, char out[18]) {
	static const char digits[] = "0123456789abcdef";
	for (int i = 0; i < 6; i++) {
		out[i * 3] = digits[b[i] >> 4];
		out[i * 3 + 1] = digits[b[i] & 15];
		out[i * 3 + 2] = (i < 5) ? ':' : '\0';
	}
}

static void molly_ntop(const void *src, int family, char *out, size_t n) {
	if (inet_ntop(family, src, out, n) == NULL)
		out[0] = '\0';
}

int molly_getifaddrs_json(char **out) {
	*out = NULL;
	struct ifaddrs *ifa0 = NULL;
	if (getifaddrs(&ifa0) != 0)
		return -1;

	struct blob_buf b;
	memset(&b, 0, sizeof(b));
	blobmsg_buf_init(&b);
	void *arr = blobmsg_open_array(&b, NULL);

	for (struct ifaddrs *ifa = ifa0; ifa != NULL; ifa = ifa->ifa_next) {
		if (ifa->ifa_addr == NULL)
			continue;

		int family = ifa->ifa_addr->sa_family;
		char addr[64] = "", netmask[64] = "", dst[64] = "", mac[18] = "";
		int ifindex = 0, hatype = 0, halen = 0;

		if (family == AF_INET) {
			molly_ntop(&((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, AF_INET, addr, sizeof(addr));
			if (ifa->ifa_netmask)
				molly_ntop(&((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr, AF_INET, netmask, sizeof(netmask));
			if (ifa->ifa_dstaddr)
				molly_ntop(&((struct sockaddr_in *)ifa->ifa_dstaddr)->sin_addr, AF_INET, dst, sizeof(dst));
		} else if (family == AF_INET6) {
			molly_ntop(&((struct sockaddr_in6 *)ifa->ifa_addr)->sin6_addr, AF_INET6, addr, sizeof(addr));
			if (ifa->ifa_netmask)
				molly_ntop(&((struct sockaddr_in6 *)ifa->ifa_netmask)->sin6_addr, AF_INET6, netmask, sizeof(netmask));
			if (ifa->ifa_dstaddr)
				molly_ntop(&((struct sockaddr_in6 *)ifa->ifa_dstaddr)->sin6_addr, AF_INET6, dst, sizeof(dst));
		} else if (family == AF_PACKET) {
			// struct sockaddr_ll 的字节布局（不引内核头）：
			// family 0-1, protocol 2-3, ifindex 4-7, hatype 8-9, pkttype 10, halen 11, addr 12-19
			const unsigned char *p = (const unsigned char *)ifa->ifa_addr;
			ifindex = (int)((uint32_t)p[4] | ((uint32_t)p[5] << 8) |
			                ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 24));
			hatype = (int)(uint16_t)(p[8] | (p[9] << 8));
			halen = p[11];
			molly_mac_text(p + 12, mac);
			snprintf(addr, sizeof(addr), "%s", mac);
		} else {
			continue;
		}

		void *t = blobmsg_open_table(&b, NULL);
		blobmsg_add_string(&b, "name", ifa->ifa_name ? ifa->ifa_name : "");
		blobmsg_add_u32(&b, "family", (uint32_t)family);
		blobmsg_add_string(&b, "addr", addr);
		blobmsg_add_string(&b, "netmask", netmask);
		blobmsg_add_string(&b, "dstaddr", dst);
		blobmsg_add_u32(&b, "flags", (uint32_t)ifa->ifa_flags);
		blobmsg_add_u32(&b, "ifindex", (uint32_t)ifindex);
		blobmsg_add_u32(&b, "hatype", (uint32_t)hatype);
		blobmsg_add_u32(&b, "halen", (uint32_t)halen);
		blobmsg_add_string(&b, "mac", mac);
		blobmsg_close_table(&b, t);
	}

	blobmsg_close_array(&b, arr);
	freeifaddrs(ifa0);

	char *js = molly_format_json_sole_child(&b);
	blob_buf_free(&b);
	if (js == NULL)
		return -1;
	*out = js;
	return 0;
}

// --- 裸 netlink RTM_GETNEIGH dump（对齐 linux.odin:2738-2890）-------------

#define MOLLY_AF_NETLINK 16
#define MOLLY_NETLINK_ROUTE 0
#define MOLLY_RTM_NEWNEIGH 28
#define MOLLY_RTM_GETNEIGH 30
#define MOLLY_NLM_F_REQUEST 0x1
#define MOLLY_NLM_F_DUMP 0x300
#define MOLLY_NLMSG_ERROR 2
#define MOLLY_NLMSG_DONE 3
#define MOLLY_NDA_DST 1
#define MOLLY_NDA_LLADDR 3
#define MOLLY_NUD_NOARP 0x40

int molly_get_neighbors_json(char **out) {
	*out = NULL;
	struct blob_buf b;
	memset(&b, 0, sizeof(b));
	blobmsg_buf_init(&b);
	void *arr = blobmsg_open_array(&b, NULL);

	int fd = socket(AF_NETLINK, SOCK_RAW, MOLLY_NETLINK_ROUTE);
	if (fd < 0)
		goto done;

	{
		unsigned char sa[12];
		memset(sa, 0, sizeof(sa));
		sa[0] = MOLLY_AF_NETLINK;
		if (bind(fd, (struct sockaddr *)sa, sizeof(sa)) != 0) {
			close(fd);
			goto done;
		}
	}

	{
		unsigned char req[28];
		memset(req, 0, sizeof(req));
		uint32_t rlen = 28;
		req[0] = (unsigned char)(rlen & 0xff);
		req[1] = (unsigned char)((rlen >> 8) & 0xff);
		req[2] = (unsigned char)((rlen >> 16) & 0xff);
		req[3] = (unsigned char)((rlen >> 24) & 0xff);
		req[4] = (unsigned char)(MOLLY_RTM_GETNEIGH & 0xff);
		req[5] = (unsigned char)((MOLLY_RTM_GETNEIGH >> 8) & 0xff);
		uint16_t rflags = (uint16_t)(MOLLY_NLM_F_REQUEST | MOLLY_NLM_F_DUMP);
		req[6] = (unsigned char)(rflags & 0xff);
		req[7] = (unsigned char)((rflags >> 8) & 0xff);
		if (send(fd, req, 28, 0) < 0) {
			close(fd);
			goto done;
		}
	}

	{
		unsigned char buf[16384];
		int finished = 0;
		while (!finished) {
			ssize_t n = recv(fd, buf, sizeof(buf), 0);
			if (n <= 0)
				break;
			int off = 0;
			while (off + 16 <= (int)n) {
				int msg_len = (int)((uint32_t)buf[off] | ((uint32_t)buf[off + 1] << 8) |
				                    ((uint32_t)buf[off + 2] << 16) | ((uint32_t)buf[off + 3] << 24));
				uint16_t msg_type = (uint16_t)(buf[off + 4] | (buf[off + 5] << 8));
				if (msg_len < 16 || off + msg_len > (int)n)
					break;
				if (msg_type == MOLLY_NLMSG_DONE || msg_type == MOLLY_NLMSG_ERROR) {
					finished = 1;
					break;
				}
				if (msg_type == MOLLY_RTM_NEWNEIGH && msg_len >= 28) {
					int nd = off + 16;
					int family = buf[nd];
					uint16_t state = (uint16_t)(buf[nd + 8] | (buf[nd + 9] << 8));
					int ok_family = (family == AF_INET || family == AF_INET6);
					int ok_state = (state & (0xff & ~MOLLY_NUD_NOARP)) != 0;
					if (ok_family && ok_state) {
						const unsigned char *dst = NULL;
						int dstlen = 0;
						const unsigned char *ma = NULL;
						int malen = 0;
						int ao = nd + 12;
						while (ao + 4 <= off + msg_len) {
							int alen = (int)(uint16_t)(buf[ao] | (buf[ao + 1] << 8));
							uint16_t atype = (uint16_t)(buf[ao + 2] | (buf[ao + 3] << 8));
							if (alen < 4 || ao + alen > off + msg_len)
								break;
							if (atype == MOLLY_NDA_DST) {
								dst = buf + ao + 4;
								dstlen = alen - 4;
							} else if (atype == MOLLY_NDA_LLADDR) {
								ma = buf + ao + 4;
								malen = alen - 4;
							}
							ao += (alen + 3) & ~3;
						}
						if (ma && malen >= 6 && dst && dstlen > 0) {
							char mac[18];
							char ip[64];
							molly_mac_text(ma, mac);
							molly_ntop(dst, family, ip, sizeof(ip));
							if (ip[0] && mac[0]) {
								void *t = blobmsg_open_table(&b, NULL);
								blobmsg_add_string(&b, "ip", ip);
								blobmsg_add_string(&b, "mac", mac);
								blobmsg_close_table(&b, t);
							}
						}
					}
				}
				off += (msg_len + 3) & ~3;
			}
		}
		close(fd);
	}

done:
	blobmsg_close_array(&b, arr);
	char *js = molly_format_json_sole_child(&b);
	blob_buf_free(&b);
	if (js == NULL)
		return -1;
	*out = js;
	return 0;
}

// --- iwinfo（dlopen，布局版本敏感；对齐 iwinfo.odin）----------------------

#define MOLLY_IWINFO_BUFSIZE (24 * 1024)
#define MOLLY_IW80211_COUNT 8
#define MOLLY_IWHTMODE_COUNT 19
#define MOLLY_IWHTMODE_NOHT (1u << 7)
#define MOLLY_IWAUTH_COUNT 2
#define MOLLY_IWKMGMT_COUNT 5
#define MOLLY_IWKMGMT_NONE (1u << 0)
#define MOLLY_IWCIPHER_COUNT 11
#define MOLLY_IWCIPHER_NONE (1u << 0)
#define MOLLY_IWOPMODE_COUNT 10

// struct iwinfo_ops（iwinfo.h master）：字段顺序/数量必须与该版本一致。
struct molly_iwinfo_ops {
	const char *name;
	void *probe, *mode, *channel, *center_chan1, *center_chan2;
	void *frequency, *frequency_offset, *txpower, *txpower_offset;
	void *bitrate, *signal, *noise, *quality, *quality_max, *mbssid_support;
	void *hwmodelist, *htmodelist, *htmode;
	void *ssid, *bssid, *country, *hardware_id, *hardware_name;
	void *encryption, *phyname, *assoclist, *txpwrlist, *scanlist;
	void *freqlist, *countrylist, *survey, *lookup_phy, *phy_path, *close;
};

struct molly_iwinfo_crypto {
	uint8_t enabled, wpa_version;
	uint16_t group_ciphers, pair_ciphers;
	uint8_t auth_suites, auth_algs;
};

struct molly_iwinfo_hardware_id {
	uint16_t vendor_id, device_id, subsystem_vendor_id, subsystem_device_id;
	uint8_t compatible[128];
};

static int g_iw_loaded, g_iw_ok;
static void *g_iw_handle;
static struct molly_iwinfo_ops *(*g_iw_backend)(const char *);
static int (*g_iw_format_hwmodes)(int, char *, int);
static void (*g_iw_close_fn)(void);
static const char **g_iw_80211, **g_iw_htmode, **g_iw_auth;
static const char **g_iw_kmgmt, **g_iw_cipher, **g_iw_opmode;

static int molly_iwinfo_load(void) {
	if (g_iw_loaded)
		return g_iw_ok;
	g_iw_loaded = 1;

	DIR *d = opendir("/usr/lib");
	if (d == NULL)
		return 0;
	struct dirent *de;
	while ((de = readdir(d)) != NULL) {
		if (strncmp(de->d_name, "libiwinfo.so", 12) != 0)
			continue;
		char path[512];
		snprintf(path, sizeof(path), "/usr/lib/%s", de->d_name);
		void *h = dlopen(path, RTLD_LAZY);
		if (h != NULL) {
			g_iw_handle = h;
			break;
		}
	}
	closedir(d);
	if (g_iw_handle == NULL)
		return 0;

	g_iw_backend = (struct molly_iwinfo_ops *(*)(const char *))dlsym(g_iw_handle, "iwinfo_backend");
	g_iw_format_hwmodes = (int (*)(int, char *, int))dlsym(g_iw_handle, "iwinfo_format_hwmodes");
	void *cl = dlsym(g_iw_handle, "iwinfo_close");
	if (cl == NULL)
		cl = dlsym(g_iw_handle, "iwinfo_finish");
	g_iw_close_fn = (void (*)(void))cl;
	g_iw_80211 = (const char **)dlsym(g_iw_handle, "IWINFO_80211_NAMES");
	g_iw_htmode = (const char **)dlsym(g_iw_handle, "IWINFO_HTMODE_NAMES");
	g_iw_auth = (const char **)dlsym(g_iw_handle, "IWINFO_AUTH_NAMES");
	g_iw_kmgmt = (const char **)dlsym(g_iw_handle, "IWINFO_KMGMT_NAMES");
	g_iw_cipher = (const char **)dlsym(g_iw_handle, "IWINFO_CIPHER_NAMES");
	g_iw_opmode = (const char **)dlsym(g_iw_handle, "IWINFO_OPMODE_NAMES");

	if (g_iw_backend == NULL || g_iw_format_hwmodes == NULL || g_iw_80211 == NULL ||
	    g_iw_htmode == NULL || g_iw_auth == NULL || g_iw_kmgmt == NULL ||
	    g_iw_cipher == NULL || g_iw_opmode == NULL)
		return 0;

	g_iw_ok = 1;
	return 1;
}

// ops->name 必须是已知后端名（防布局错位时把任意指针当字符串读）。
static int molly_iw_ops_ok(struct molly_iwinfo_ops *ops) {
	if (ops == NULL || ops->name == NULL)
		return 0;
	return !strcmp(ops->name, "wext") || !strcmp(ops->name, "nl80211") ||
	       !strcmp(ops->name, "madwifi") || !strcmp(ops->name, "wl") ||
	       !strcmp(ops->name, "unknown");
}

static int molly_iw_num(void *fn, const char *dev, int *v) {
	if (fn == NULL)
		return 0;
	return ((int (*)(const char *, int *))fn)(dev, v) == 0;
}

static int molly_iw_str(void *fn, const char *dev, char *buf) {
	if (fn == NULL)
		return 0;
	return ((int (*)(const char *, char *))fn)(dev, buf) == 0;
}

// iw_add_bit_array（iwinfo.odin:220-248）：bits==0 用 zero 兜底，逐位查名字表。
static void molly_iw_bit_array(struct blob_buf *b, const char *key, unsigned int bits,
                               const char **names, int count, int lower, unsigned int zero) {
	unsigned int v = bits ? bits : zero;
	void *arr = blobmsg_open_array(b, key);
	for (int i = 0; i < count; i++) {
		if (!(v & (1u << i)))
			continue;
		const char *n = names[i] ? names[i] : "";
		char low[128];
		if (lower) {
			int j;
			for (j = 0; n[j] && j < (int)sizeof(low) - 1; j++)
				low[j] = (char)tolower((unsigned char)n[j]);
			low[j] = '\0';
			n = low;
		}
		blobmsg_add_string(b, NULL, n);
	}
	blobmsg_close_array(b, arr);
}

int molly_iwinfo_json(const char *devname, int phy_only, char **out) {
	*out = NULL;
	if (devname == NULL || !molly_iwinfo_load())
		return -1;

	struct molly_iwinfo_ops *ops = g_iw_backend(devname);
	if (!molly_iw_ops_ok(ops))
		return -1;

	struct blob_buf b;
	memset(&b, 0, sizeof(b));
	blobmsg_buf_init(&b);
	void *root = blobmsg_open_table(&b, NULL);

	char buf[MOLLY_IWINFO_BUFSIZE];
	int num = 0;
	int rc = -1;

	if (molly_iw_num(ops->signal, devname, &num))
		blobmsg_add_u32(&b, "signal", (uint32_t)num);
	if (molly_iw_num(ops->noise, devname, &num))
		blobmsg_add_u32(&b, "noise", (uint32_t)num);
	if (molly_iw_num(ops->channel, devname, &num))
		blobmsg_add_u32(&b, "channel", (uint32_t)num);
	if (molly_iw_str(ops->country, devname, buf))
		blobmsg_add_string(&b, "country", buf);
	if (molly_iw_str(ops->phyname, devname, buf))
		blobmsg_add_string(&b, "phy", buf);
	if (molly_iw_num(ops->txpower, devname, &num))
		blobmsg_add_u32(&b, "txpower", (uint32_t)num);
	if (molly_iw_num(ops->txpower_offset, devname, &num))
		blobmsg_add_u32(&b, "txpower_offset", (uint32_t)num);
	if (molly_iw_num(ops->frequency, devname, &num))
		blobmsg_add_u32(&b, "frequency", (uint32_t)num);
	if (molly_iw_num(ops->frequency_offset, devname, &num))
		blobmsg_add_u32(&b, "frequency_offset", (uint32_t)num);

	if (molly_iw_num(ops->hwmodelist, devname, &num)) {
		unsigned int bits = (unsigned int)num;
		if (bits & ~((1u << MOLLY_IW80211_COUNT) - 1))
			goto done; // 位越过名字表说明布局/版本不符
		molly_iw_bit_array(&b, "hwmodes", bits, g_iw_80211, MOLLY_IW80211_COUNT, 1, 0);
		char text[32];
		if (g_iw_format_hwmodes != NULL && g_iw_format_hwmodes(num, text, (int)sizeof(text)) > 0)
			blobmsg_add_string(&b, "hwmodes_text", text);
	}
	if (molly_iw_num(ops->htmodelist, devname, &num)) {
		unsigned int bits = (unsigned int)num;
		if (bits & ~((1u << MOLLY_IWHTMODE_COUNT) - 1))
			goto done;
		molly_iw_bit_array(&b, "htmodes", bits & ~MOLLY_IWHTMODE_NOHT, g_iw_htmode,
		                   MOLLY_IWHTMODE_COUNT, 0, 0);
	}

	if (molly_iw_str(ops->hardware_id, devname, buf)) {
		struct molly_iwinfo_hardware_id *ids = (struct molly_iwinfo_hardware_id *)buf;
		void *hw = blobmsg_open_table(&b, "hardware");
		void *idarr = blobmsg_open_array(&b, "id");
		blobmsg_add_u32(&b, NULL, ids->vendor_id);
		blobmsg_add_u32(&b, NULL, ids->device_id);
		blobmsg_add_u32(&b, NULL, ids->subsystem_vendor_id);
		blobmsg_add_u32(&b, NULL, ids->subsystem_device_id);
		blobmsg_close_array(&b, idarr);
		if (molly_iw_str(ops->hardware_name, devname, buf))
			blobmsg_add_string(&b, "name", buf);
		blobmsg_close_table(&b, hw);
	}

	if (!phy_only) {
		if (molly_iw_num(ops->quality, devname, &num))
			blobmsg_add_u32(&b, "quality", (uint32_t)num);
		if (molly_iw_num(ops->quality_max, devname, &num))
			blobmsg_add_u32(&b, "quality_max", (uint32_t)num);
		if (molly_iw_num(ops->bitrate, devname, &num))
			blobmsg_add_u32(&b, "bitrate", (uint32_t)num);
		if (molly_iw_num(ops->mode, devname, &num)) {
			if (num < 0 || num >= MOLLY_IWOPMODE_COUNT)
				goto done;
			blobmsg_add_string(&b, "mode", g_iw_opmode[num]);
		}
		if (molly_iw_str(ops->ssid, devname, buf))
			blobmsg_add_string(&b, "ssid", buf);
		if (molly_iw_str(ops->bssid, devname, buf))
			blobmsg_add_string(&b, "bssid", buf);
		if (molly_iw_str(ops->encryption, devname, buf)) {
			struct molly_iwinfo_crypto *c = (struct molly_iwinfo_crypto *)buf;
			void *enc = blobmsg_open_table(&b, "encryption");
			blobmsg_add_u32(&b, "enabled", c->enabled ? 1 : 0);
			if (c->enabled) {
				if (c->wpa_version == 0) {
					molly_iw_bit_array(&b, "wep", c->auth_algs, g_iw_auth,
					                   MOLLY_IWAUTH_COUNT, 1, 0);
				} else {
					void *wpa = blobmsg_open_array(&b, "wpa");
					for (int v = 1; v <= 3; v++)
						if (c->wpa_version & (1u << (v - 1)))
							blobmsg_add_u32(&b, NULL, (uint32_t)v);
					blobmsg_close_array(&b, wpa);
					molly_iw_bit_array(&b, "authentication", c->auth_suites, g_iw_kmgmt,
					                   MOLLY_IWKMGMT_COUNT, 1, MOLLY_IWKMGMT_NONE);
				}
				molly_iw_bit_array(&b, "ciphers",
				                   (unsigned)c->pair_ciphers | (unsigned)c->group_ciphers,
				                   g_iw_cipher, MOLLY_IWCIPHER_COUNT, 1, MOLLY_IWCIPHER_NONE);
			}
			blobmsg_close_table(&b, enc);
		}
	}

	blobmsg_close_table(&b, root);
	{
		char *js = molly_format_json_sole_child(&b);
		if (js != NULL) {
			*out = js;
			rc = 0;
		}
	}

done:
	if (g_iw_close_fn != NULL)
		g_iw_close_fn();
	blob_buf_free(&b);
	return rc;
}