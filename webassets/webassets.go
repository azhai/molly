// Package webassets —— 编进二进制的前端资源。
//
// 两类资源，都在本包（项目根目录下的 webassets/）：
//
//   - `NoviceHTML`（novice.go）：新手版（挂在 `/`）那一整页，**恒编入**；
//   - `luci-static/`（assets_embed.go）：设备 LuCI 静态资源的**兜底副本**，可选——
//     `-tags embed_assets` 编译时才带，docroot 里找不到的文件再由它送出去，于是
//     「只丢一个二进制上去」也能把界面跑起来。
//
// 默认构建不带 luci-static（`Available()` 为 false）：静态文件仍从 `--docroot` 读，
// 设备上那份 LuCI 版本的资源优先。为什么是**兜底**而不是优先——内置那份是**编译时**
// 抄的，设备升级 LuCI 之后两份会漂移（浏览器端 JS 与 ucode 视图不同步 → 界面坏）；
// 设备上有的就信设备。
//
// luci-static 不随仓库分发（体积 + 版本漂移），用 `./tools/embed-assets.sh <host>`
// 从设备抄一份；抄出来的目录已 gitignore。
package webassets

// Available 报告本二进制是否带了内置资源。
//   - 默认构建：false
//   - `-tags embed_assets`：true
func Available() bool { return available }

// ReadFile 读内置资源；name 与 URL 同形（如 "/luci-static/resources/luci.js"）。
// 未编入资源、或该路径不在资源里时返回 ok = false（调用方据此走原来的 404）。
func ReadFile(name string) ([]byte, bool) { return readEmbedded(name) }
