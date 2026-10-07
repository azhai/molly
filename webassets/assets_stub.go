//go:build !embed_assets

package webassets

// 默认构建：不带内置资源，静态文件只从 --docroot 读。
//
// 想让二进制自带前端，用 `./tools/embed-assets.sh <host>` 抄一份资源，再
// `go build -tags embed_assets`。

const available = false

func readEmbedded(string) ([]byte, bool) { return nil, false }
