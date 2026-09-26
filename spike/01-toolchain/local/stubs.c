/* 仅用于本地链路验证（本机没有 OpenWrt SDK 时的替身）。
 * 真机构建不要带这个文件——libuci / libubus 由 OpenWrt 提供。
 * 目的：让 Odin 产出的 .o 里的 uci_* / ubus_* 未解析符号能被解析，
 *      从而验证 "Odin obj -> 外部链接器 -> aarch64 ELF" 这条链路是否成立。
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

/* ---------------- libuci ---------------- */

struct uci_context { int stub; };
struct uci_package { int stub; };
struct uci_section { int stub; };
struct uci_option { int stub; };
struct uci_element { int stub; };

struct uci_ptr {
	const char *target;
	const char *package;
	const char *section;
	const char *option;
	const char *value;
	struct uci_package *p;
	struct uci_section *s;
	struct uci_option *o;
	struct uci_element *last;
};

struct uci_context *uci_alloc_context(void) {
	static struct uci_context ctx;
	return &ctx;
}

void uci_free_context(struct uci_context *ctx) { (void)ctx; }

int uci_load(struct uci_context *ctx, const char *name, struct uci_package **pkg) {
	static struct uci_package p;
	(void)ctx; (void)name;
	*pkg = &p;
	return 0;
}

int uci_lookup_ptr(struct uci_context *ctx, struct uci_ptr *out, const char *str, bool extended) {
	(void)ctx; (void)str; (void)extended;
	out->value = "static(stub)";
	return 0;
}

void uci_perror(struct uci_context *ctx, const char *str) {
	(void)ctx;
	fprintf(stderr, "%s\n", str);
}

/* ---------------- libubus ---------------- */

struct ubus_context { int stub; };
struct blob_attr { int stub; };
struct ubus_request { int stub; };

typedef void (*ubus_data_handler_t)(struct ubus_request *, int, struct blob_attr *);

struct ubus_context *ubus_connect(const char *path) {
	static struct ubus_context ctx;
	(void)path;
	return &ctx;
}

void ubus_free(struct ubus_context *ctx) { (void)ctx; }

int ubus_lookup_id(struct ubus_context *ctx, const char *path, unsigned int *id) {
	(void)ctx; (void)path;
	*id = 42u;
	return 0;
}

int ubus_invoke(struct ubus_context *ctx, unsigned int obj, const char *method,
                struct blob_attr *msg, ubus_data_handler_t cb, void *priv, int timeout) {
	(void)ctx; (void)obj; (void)method; (void)msg; (void)priv; (void)timeout;
	if (cb) cb(NULL, 7, NULL);
	return 0;
}
