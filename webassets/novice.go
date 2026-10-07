package webassets

import _ "embed"

// NoviceHTML 是**新手版**（挂在 `/`）那一整页。
//
// 它是单文件（CSS/JS 内联、零外部依赖），用 go:embed 在编译期嵌进二进制，所以不依赖
// docroot 上的任何文件、也不碰 ucode。服务端只在响应时替换两个占位符：`__SID__`
// （会话 id）与 `__EXPERT_PREFIX__`（专家版前缀），见 internal/handlers/novice.go。
//
// 为什么和 luci-static 同包：两者是同一类东西——**要编进二进制的前端资源**。放一起，
// 「二进制里到底带了哪些前端」只有一个入口。
//
// 与 luci-static 的区别：那份是设备 LuCI 静态资源的**兜底副本**（可选、按构建 tag 编入）；
// 这一页是我们自己的东西，**恒编入**。
//
//go:embed novice/index.html
var NoviceHTML string
