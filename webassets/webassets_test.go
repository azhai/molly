package webassets

import "testing"

// 两个构建形态各测一半：默认构建必须**没有**内置资源；带 tag 的构建必须**有**。
// 二者互为镜像——测的那一半在另一种构建下会 Skip，所以两种构建都能跑同一份测试。

func TestDefaultBuildHasNoAssets(t *testing.T) {
	if Available() {
		t.Skip("本次是 -tags embed_assets 构建，由 TestEmbeddedAssetsPresent 覆盖")
	}
	if _, ok := ReadFile("/luci-static/resources/luci.js"); ok {
		t.Error("默认构建不该读到内置资源")
	}
}

func TestEmbeddedAssetsPresent(t *testing.T) {
	if !Available() {
		t.Skip("本次是默认构建，由 TestDefaultBuildHasNoAssets 覆盖")
	}
	// luci.js 是 LuCI 前端的入口，抄资源时必然有；读不到说明 tools/embed-assets.sh
	// 抄错了目录（例如抄了 /www/luci-static 之外的东西）。
	if _, ok := ReadFile("/luci-static/resources/luci.js"); !ok {
		t.Error("-tags embed_assets 构建应能读到 /luci-static/resources/luci.js")
	}
}
