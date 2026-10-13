package handlers

// router_test —— route_of 决策的 host 单测（无套接字、无未就绪 handler）。
// 钉住契约 §3 的顺序与边界：ubus/auth 前缀的「带边界」匹配、/lite 任意子路径 + 入口 /、
// 以及最关键的「专家版前缀排在静态之前」——默认 /cgi-bin/luci 归 Luci（不被静态 403 吃掉），
// 换成 /admin 后 /cgi-bin/* 落回 Static；cgi-io 只在 cgi_base+名字的全等时命中。

import "core:testing"
import "core:mem"

// 两套配置：上游形态（luci=/cgi-bin/luci, cgi_base=/cgi-bin）与本仓部署（luci=/admin, cgi_base=""）。
cfg_upstream :: Router_Config{luci_prefix = "/cgi-bin/luci", cgi_base = "/cgi-bin"}
cfg_deploy   :: Router_Config{luci_prefix = "/admin", cgi_base = ""}

@(test)
test_matches_prefix :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	testing.expect_value(t, Matches_Prefix("/ubus", "/ubus"), true)
	testing.expect_value(t, Matches_Prefix("/ubus/list", "/ubus"), true)
	testing.expect_value(t, Matches_Prefix("/ubus.html", "/ubus"), false) // 边界：不认裸前缀后的非 '/'
	testing.expect_value(t, Matches_Prefix("/lites", "/lite"), false)
	testing.expect_value(t, Matches_Prefix("/", "/lite"), false)
}

@(test)
test_route_of_boundaries :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	r := route_of("/ubus", cfg_deploy)
	testing.expect_value(t, r, .Ubus)
	r = route_of("/ubus/list", cfg_deploy)
	testing.expect_value(t, r, .Ubus)
	// /ubus.html 不该归 ubus，落到静态兜底。
	r = route_of("/ubus.html", cfg_deploy)
	testing.expect_value(t, r, .Static)

	r = route_of("/auth", cfg_deploy)
	testing.expect_value(t, r, .Auth)
	r = route_of("/auth/login", cfg_deploy)
	testing.expect_value(t, r, .Auth)
	r = route_of("/author", cfg_deploy) // 边界：/auth 之后不是 '/'
	testing.expect_value(t, r, .Static)

	r = route_of("/", cfg_deploy) // 入口 → 简洁版（ServeSimple 会 302 到 /lite/）
	testing.expect_value(t, r, .Simple)
	r = route_of("/lite", cfg_deploy)
	testing.expect_value(t, r, .Simple)
	r = route_of("/lite/net", cfg_deploy) // 深链任意子路径都归简洁版
	testing.expect_value(t, r, .Simple)
	r = route_of("/lites", cfg_deploy)
	testing.expect_value(t, r, .Static)
}

@(test)
test_route_of_luci_vs_static :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 默认前缀 /cgi-bin/luci：必须排到 Luci，否则会被静态层的 /cgi-bin/* → 403 抢先。
	r := route_of("/cgi-bin/luci", cfg_upstream)
	testing.expect_value(t, r, .Luci)
	r = route_of("/cgi-bin/luci/admin/status", cfg_upstream)
	testing.expect_value(t, r, .Luci)

	// 换成 /admin 后：/admin… 归 Luci，而 /cgi-bin/* 落回 Static（由静态层 403）。
	r = route_of("/admin", cfg_deploy)
	testing.expect_value(t, r, .Luci)
	r = route_of("/admin/status/overview", cfg_deploy)
	testing.expect_value(t, r, .Luci)
	r = route_of("/cgi-bin/luci", cfg_deploy) // 前缀已不是它 → 静态兜底（进而 403）
	testing.expect_value(t, r, .Static)
	r = route_of("/cgi-bin/foo.sh", cfg_deploy)
	testing.expect_value(t, r, .Static)
}

@(test)
test_route_of_cgi_io :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 本部署 cgi_base=""：裸 /cgi-exec 命中；带子路径不命中（精确匹配，不吃 /cgi-exec/anything）。
	r := route_of("/cgi-exec", cfg_deploy)
	testing.expect_value(t, r, .CGI_IO)
	r = route_of("/cgi-download", cfg_deploy)
	testing.expect_value(t, r, .CGI_IO)
	r = route_of("/cgi-backup", cfg_deploy)
	testing.expect_value(t, r, .CGI_IO)
	r = route_of("/cgi-exec/anything", cfg_deploy)
	testing.expect_value(t, r, .Static)

	// 上游 cgi_base="/cgi-bin"：/cgi-bin/cgi-exec 命中；裸 /cgi-exec 不命中（落静态）。
	r = route_of("/cgi-bin/cgi-exec", cfg_upstream)
	testing.expect_value(t, r, .CGI_IO)
	r = route_of("/cgi-exec", cfg_upstream)
	testing.expect_value(t, r, .Static)
}
