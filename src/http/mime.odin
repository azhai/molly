package http

// 扩展名 → Content-Type。**逐条对齐原厂 uhttpd**（2026-10-07 真机实测，36 个扩展名，
// 见 tests/golden.sh 的 HTTP 面）。三条容易记错的规则：
//   1. uhttpd **从不带 charset**（`text/html`、不是 `text/html; charset=utf-8`）；
//   2. `.js` 是 `text/javascript`，不是 `application/javascript`；
//   3. 表外扩展名一律 `application/octet-stream`——实测 ico / woff / woff2 / ttf / eot /
//      otf / mjs / map / webmanifest / md / csv / webm / webp / avif 全是它。
// uhttpd 表里的长尾（office / deb / rpm / perl / php / x-csrc…）**未收录**：那些文件不会
// 出现在 molly 送出的路径上（LuCI 前端只有 html/css/js/json/图片），真要用到再补。
//
// 匹配规则：取最后一个 '.' 之后的部分，不区分大小写，且不跨 '/'
// （"/a.b/c" 没有扩展名）。
content_type_for :: proc(path: string) -> string {
	ext := path_ext(path)
	if len(ext) == 0 {
		return "application/octet-stream"
	}
	switch {
	case ascii_equal_fold(ext, "html"), ascii_equal_fold(ext, "htm"):
		return "text/html"
	case ascii_equal_fold(ext, "css"):
		return "text/css"
	case ascii_equal_fold(ext, "js"):
		return "text/javascript"
	case ascii_equal_fold(ext, "json"):
		return "application/json"
	case ascii_equal_fold(ext, "xml"):
		return "application/xml"
	case ascii_equal_fold(ext, "txt"), ascii_equal_fold(ext, "conf"), ascii_equal_fold(ext, "log"):
		return "text/plain"
	case ascii_equal_fold(ext, "svg"):
		return "image/svg+xml"
	case ascii_equal_fold(ext, "png"):
		return "image/png"
	case ascii_equal_fold(ext, "jpg"), ascii_equal_fold(ext, "jpeg"):
		return "image/jpeg"
	case ascii_equal_fold(ext, "gif"):
		return "image/gif"
	case ascii_equal_fold(ext, "bmp"):
		return "image/bmp"
	case ascii_equal_fold(ext, "pdf"):
		return "application/pdf"
	case ascii_equal_fold(ext, "zip"):
		return "application/zip"
	case ascii_equal_fold(ext, "gz"):
		return "application/x-gzip"
	case ascii_equal_fold(ext, "tar"):
		return "application/x-tar"
	case ascii_equal_fold(ext, "mp4"):
		return "video/mp4"
	case ascii_equal_fold(ext, "mp3"):
		return "audio/mpeg"
	case ascii_equal_fold(ext, "wav"):
		return "audio/x-wav"
	case ascii_equal_fold(ext, "sh"):
		return "application/x-shellscript"
	}
	return "application/octet-stream"
}

// 返回 path 最后一个 '.' 之后的部分（不含 '.'）。没有扩展名时返回空串。
@(private)
path_ext :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		switch path[i] {
		case '/':
			return ""
		case '.':
			if i + 1 >= len(path) {
				return ""
			}
			return path[i + 1:]
		}
	}
	return ""
}