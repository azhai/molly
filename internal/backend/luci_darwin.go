//go:build darwin

package backend

import (
	"os"
	"path/filepath"
)

// luci-rpc 的 darwin 平台钩子（luci_object.go 调用；luci_linux.go 有同名同签名的另一份）。

// luciRPCBoardPath：getBoardJSON 读的板级描述文件。真机是 /etc/board.json（luci.c 的
// blobmsg_add_json_from_file 路径）；darwin 用仓库里的 fixture。fixture 不在 molly/ 下，
// 相对 molly 进程的 cwd（通常是 molly/）用 ../tests；GOMOLLY_BOARD_JSON 可覆盖
// （tests/smoke.sh 会设成绝对路径，双保险）。
func luciRPCBoardPath() string {
	if p := os.Getenv("GOMOLLY_BOARD_JSON"); p != "" {
		return p
	}
	// 相对**进程 cwd**（不是包目录）：约定是从仓库根启动，与 darwin.go 里 acl.d 的
	// 兜底路径同一套写法（命令在根目录跑，测试用 GOMOLLY_BOARD_JSON 显式覆盖）。
	return filepath.Join("tests", "fixtures", "board.json")
}

// getNetworkDevices / getWirelessDevices / getHostHints 绑 sysfs / netifd / netlink /
// ifaddrs，darwin 上没有——与 uci 写路径同一决策：linux-only，darwin 回 8。
func luciRPCNetworkDevices() (string, int)  { return "", StatusNotSupported }
func luciRPCWirelessDevices() (string, int) { return "", StatusNotSupported }
func luciRPCHostHints() (string, int)       { return "", StatusNotSupported }
