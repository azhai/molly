//go:build linux && cgo

package cbind

/*
#include <stdlib.h>
*/
import "C"

// mollyGoHandle 是 shim.c 里 molly_ubus_handler 的回调目标（C 侧声明见 _cgo_export.h）。
//
// 入站 ubus 调用 → 本函数 → backend 的 handler。返回值语义与 C 约定一致：
// status != 0 时 shim **不** send_reply，把状态码交回 libubus。
//
// 注意：本文件带 //export，preamble 只能有声明（不能有 C 定义），否则 cgo 报错。
//
//export mollyGoHandle
func mollyGoHandle(objName, method, paramsJSON *C.char, replyOut **C.char) C.int {
	h := currentHandler()
	if h == nil {
		return 8 // StatusNotSupported
	}
	status, reply := h(C.GoString(objName), C.GoString(method), C.GoString(paramsJSON))
	if status == 0 && reply != "" {
		*replyOut = C.CString(reply)
	}
	return C.int(status)
}
