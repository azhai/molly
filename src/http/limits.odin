package http

// HTTP 边界常量。net/http 时代这些散在标准库里；手写服务必须显式设限，
// 否则一条恶意连接就能把内存吃光。取值对齐 uhttpd 量级、并给 cgi-io 上传留足空间。

MAX_URI_BYTES           :: 32 * 1024        // 请求行里的 target 上限
MAX_REQUEST_HEADERS_BYTES :: 64 * 1024       // 头部块总字节上限
MAX_HEADER_COUNT        :: 100               // 单请求最多头字段数
MAX_BODY_BYTES          :: 64 * 1024 * 1024  // 请求体上限（cgi-io 上传 sysupgrade 镜像可达数十 MB）
READ_CHUNK              :: 8 * 1024          // 逐块读的缓冲大小
