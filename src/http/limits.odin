package http

import "core:time"

// HTTP 层的各项上限。分两类，改之前先看清楚是哪一类：
//
//	契约类 —— 与被复刻的 uhttpd 行为对齐，改了就不兼容：
//	  MAX_BODY_BYTES 对齐 uhttpd 的 UH_UBUS_MAX_POST_SIZE。
//
//	自定类 —— molly 自己的保守取值，等真机抓到原厂响应样本后校准（见风险 R7）。
MAX_BODY_BYTES  :: 65536
MAX_HEAD_BYTES  :: 8 * 1024
MAX_HEAD_COUNT  :: 64

// 并发上限。一连接一线程。
//
// **契约对齐**（原来标成「自定类」，其实是可对齐的）：原厂 uhttpd 在本设备上是
// `-N 100`（`/etc/config/uhttpd` 的 `option max_connections '100'` → init 转 `-N 100`），
// molly 接管后必须给到同一量级。写死 32 从来没有按真实浏览器校准过，后果是两条
// 连锁故障：
//   1. 一个 LuCI 页面会并发拉几十个资源（luci.js / 主题 CSS / 首屏 XHR），浏览器又对
//      同一 host 开 ~6 条 keep-alive 连接（连接在 keep-alive 期间一直占着槽位，直到
//      客户端关闭或 READ_TIMEOUT 到期），32 很容易打满 → 超出的请求回
//      503「server is busy」（src/http/server.odin:68）。
//   2. LuCI 前端 luci.js 把首屏那条 `session access` 的**任何失败**都当作会话过期
//      （`.catch(LuCI.prototype.notifySessionExpiry)`），于是 503 进一步表现为
//      「进页面就被踢回登录页」——用户看到的「自动退出」和「503」是同一个根因。
// 提到 100 后两者一起消失（实测 40 并发：32 → 7×503；100 → 0×503）。
// 内存：100 线程 × musl 默认 128KB 栈 ≈ 12.8MB，空载 RSS 不受影响。
MAX_CONNECTIONS :: 100

// 单连接的读缓冲。keep-alive 下一个 TCP 段可能含着两个请求的边界，
// 所以这个缓冲在请求之间不清空，靠 used 水位推进。
READ_BUF_SIZE :: 4096

// 超时：慢客户端不能长时间占住一个线程槽位。
READ_TIMEOUT  :: 10 * time.Second
WRITE_TIMEOUT :: 10 * time.Second