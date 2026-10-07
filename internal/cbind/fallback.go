//go:build linux && !cgo

package cbind

// cgo-less linux 下的同签名空实现。
//
// 存在的唯一理由：`CGO_ENABLED=0 GOOS=linux go build ./...` 也要能过类型检查
// （AGENTS.md §4.1 的 linux 类型检查门禁）。所有操作 fail-closed，不假装成功。

// Ctx 在无 cgo 时不可用。
type Ctx struct{}

// Connect 无 cgo 时永远失败。
func Connect(string) *Ctx { return nil }

// Free 空实现。
func (*Ctx) Free() {}

// Lookup 无 cgo 时回「不支持」。
func (*Ctx) Lookup(string) (string, int) { return "", 8 }

// LookupID 无 cgo 时回「不支持」。
func (*Ctx) LookupID(string) (uint32, int) { return 0, 8 }

// Invoke 无 cgo 时回「不支持」。
func (*Ctx) Invoke(uint32, string, string, string) (string, int) { return "", 8 }

// Handler 见 cbind.go（无 cgo 时也不会有入站调用）。
type Handler func(obj, method, paramsJSON string) (int, string)

// SetHandler 空实现。
func SetHandler(Handler) {}

// StartServer 无 cgo 时不做任何事。
func StartServer(string) int { return -1 }

// StopServer 空实现。
func StopServer() {}

// UCISections 无 cgo 时回「不支持」。
func UCISections(string, string) (string, int) { return "", 8 }

// UCIListConfigs 无 cgo 时回「不支持」。
func UCIListConfigs() (string, int) { return "", 8 }

// VerifyPassword 无 cgo 时 fail-closed。
func VerifyPassword(string, string) bool { return false }

// UCIDelta 无 cgo 时回「不支持」。
func UCIDelta(string, string) (string, int) { return "", 8 }

// Txn 在无 cgo 时不可用（begin 永远失败）。
type Txn struct{}

// TxnBegin 无 cgo 时永远失败。
func TxnBegin(string, string) (*Txn, int) { return nil, 8 }

// End 空实现。
func (*Txn) End() {}

// Sections 无 cgo 时回空串。
func (*Txn) Sections() string { return "" }

// SectionExists 无 cgo 时 fail-closed。
func (*Txn) SectionExists(string) bool { return false }

// AddSection 无 cgo 时回「不支持」。
func (*Txn) AddSection(string, string) (string, int) { return "", 8 }

// OptionState 无 cgo 时回「不存在」。
func (*Txn) OptionState(string, string) (bool, bool, string) { return false, false, "" }

// Delete / Set / AddList / Rename / Save 无 cgo 时回「不支持」。
func (*Txn) Delete(string, string) int          { return 8 }
func (*Txn) Set(string, string, string) int     { return 8 }
func (*Txn) AddList(string, string, string) int { return 8 }
func (*Txn) Rename(string, string, string) int  { return 8 }
func (*Txn) Save() int                          { return 8 }

// Reorder 无 cgo 时 fail-closed。
func (*Txn) Reorder(string, int) bool { return false }

// UCICommit / UCIRevert / UCIApplyConfig / ReloadConfig 无 cgo 时回「不支持」。
func UCICommit(string, string) int    { return 8 }
func UCIRevert(string, string) int    { return 8 }
func UCIApplyConfig(string, bool) int { return 8 }
func ReloadConfig() int               { return 8 }

// IfAddr / Neighbor / GetIfaddrs / GetNeighbors / IwinfoJSON 同签名空实现。
type IfAddr struct {
	Name    string
	Family  int
	Addr    string
	Netmask string
	DstAddr string
	Flags   uint32
	IfIndex int
	HAType  int
	HALen   int
	MAC     string
}

type Neighbor struct {
	IP  string
	MAC string
}

// GetIfaddrs 无 cgo 时回空。
func GetIfaddrs() []IfAddr { return nil }

// GetNeighbors 无 cgo 时回空。
func GetNeighbors() []Neighbor { return nil }

// IwinfoJSON 无 cgo 时 fail-closed。
func IwinfoJSON(string, bool) (string, bool) { return "", false }
