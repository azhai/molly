package http

// Content-Type 判定 —— 逐条对齐原厂 uhttpd 与 internal/httpx/mime.go（后者对齐 Odin 版）。
// 三条易错规则：
//  1. 从不带 charset（`text/html`，不是 `text/html; charset=utf-8`）；
//  2. `.js` 是 `text/javascript`，不是 `application/javascript`；
//  3. 表外扩展名一律 `application/octet-stream`。
//
// 匹配：取最后一个 '.' 之后的部分，不区分大小写，且不跨 '/'（"/a.b/c" 无扩展名）。

import "core:strings"

Content_Type_For :: proc(path: string) -> string {
	ext := path_ext(path)
	if ext == "" {
		return "application/octet-stream"
	}
	lower := strings.to_lower(ext)
	switch lower {
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

// 返回 path 最后一个 '.' 之后（不含 '.'）的部分；遇 '/' 先则无扩展名。
path_ext :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
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
