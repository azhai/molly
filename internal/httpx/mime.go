package httpx

import "strings"

// ContentTypeFor 按扩展名给 Content-Type。**逐条对齐原厂 uhttpd**（2026-10-07 真机实测，
// 36 个扩展名），与 Odin 版 src/http/mime.odin 的表逐条一致。三条容易记错的规则：
//  1. uhttpd **从不带 charset**（`text/html`、不是 `text/html; charset=utf-8`）；
//  2. `.js` 是 `text/javascript`，不是 `application/javascript`；
//  3. 表外扩展名一律 `application/octet-stream`——实测 ico / woff / woff2 / ttf / eot /
//     otf / mjs / map / webmanifest / md / csv / webm / webp / avif 全是它。
//
// 匹配规则：取最后一个 '.' 之后的部分，不区分大小写，且不跨 '/'
// （"/a.b/c" 没有扩展名）。
func ContentTypeFor(path string) string {
	ext := pathExt(path)
	if ext == "" {
		return "application/octet-stream"
	}
	switch strings.ToLower(ext) {
	case "html", "htm":
		return "text/html"
	case "css":
		return "text/css"
	case "js":
		return "text/javascript"
	case "json":
		return "application/json"
	case "xml":
		return "application/xml"
	case "txt", "conf", "log":
		return "text/plain"
	case "svg":
		return "image/svg+xml"
	case "png":
		return "image/png"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "gif":
		return "image/gif"
	case "bmp":
		return "image/bmp"
	case "pdf":
		return "application/pdf"
	case "zip":
		return "application/zip"
	case "gz":
		return "application/x-gzip"
	case "tar":
		return "application/x-tar"
	case "mp4":
		return "video/mp4"
	case "mp3":
		return "audio/mpeg"
	case "wav":
		return "audio/x-wav"
	case "sh":
		return "application/x-shellscript"
	}
	return "application/octet-stream"
}

// pathExt 返回 path 最后一个 '.' 之后的部分（不含 '.'）。没有扩展名时返回空串。
func pathExt(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		switch path[i] {
		case '/':
			return ""
		case '.':
			if i+1 >= len(path) {
				return ""
			}
			return path[i+1:]
		}
	}
	return ""
}
