//go:build embed_assets

package webassets

import (
	"embed"
	"io/fs"
	"strings"
)

// 资源目录由 tools/embed-assets.sh 从设备抄入（已 gitignore）。
// 该 tag 下这个目录必须存在，否则编译期就会报
// "pattern all:luci-static: no matching files found"——那正是「忘抄资源」的提示。
//
//go:embed all:luci-static
var assets embed.FS

const available = true

func readEmbedded(name string) ([]byte, bool) {
	p := strings.TrimPrefix(name, "/")
	if p == "" {
		return nil, false
	}
	data, err := fs.ReadFile(assets, p)
	if err != nil {
		return nil, false
	}
	return data, true
}
