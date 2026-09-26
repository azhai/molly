package http

// 扩展名 → Content-Type。
//
// 取值覆盖 /www 下真正会出现的类型（LuCI 前端只有 html/css/js/json/字体/图片）。
// 是否逐条与 uhttpd 的 mimetypes.h 一致，要等真机抓样本校准（R7）；未收录的
// 扩展名统一回 application/octet-stream，比猜一个 text/plain 更安全。
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
		return "text/html; charset=utf-8"
	case ascii_equal_fold(ext, "css"):
		return "text/css; charset=utf-8"
	case ascii_equal_fold(ext, "js"), ascii_equal_fold(ext, "mjs"):
		return "application/javascript; charset=utf-8"
	case ascii_equal_fold(ext, "json"), ascii_equal_fold(ext, "map"):
		return "application/json; charset=utf-8"
	case ascii_equal_fold(ext, "txt"), ascii_equal_fold(ext, "md"):
		return "text/plain; charset=utf-8"
	case ascii_equal_fold(ext, "svg"):
		return "image/svg+xml"
	case ascii_equal_fold(ext, "png"):
		return "image/png"
	case ascii_equal_fold(ext, "jpg"), ascii_equal_fold(ext, "jpeg"):
		return "image/jpeg"
	case ascii_equal_fold(ext, "gif"):
		return "image/gif"
	case ascii_equal_fold(ext, "webp"):
		return "image/webp"
	case ascii_equal_fold(ext, "ico"):
		return "image/x-icon"
	case ascii_equal_fold(ext, "woff"):
		return "font/woff"
	case ascii_equal_fold(ext, "woff2"):
		return "font/woff2"
	case ascii_equal_fold(ext, "ttf"):
		return "font/ttf"
	case ascii_equal_fold(ext, "otf"):
		return "font/otf"
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