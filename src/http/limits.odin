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

// 并发上限。一连接一线程，32 个线程 × musl 默认 128KB 栈 ≈ 4MB，空载 RSS 不受影响。
MAX_CONNECTIONS :: 32

// 单连接的读缓冲。keep-alive 下一个 TCP 段可能含着两个请求的边界，
// 所以这个缓冲在请求之间不清空，靠 used 水位推进。
READ_BUF_SIZE :: 4096

// 超时：慢客户端不能长时间占住一个线程槽位。
READ_TIMEOUT  :: 10 * time.Second
WRITE_TIMEOUT :: 10 * time.Second