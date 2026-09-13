package teslmodapp
import rt "tesl.generated/teslmodapp/internal/teslrt"
func TestAccessDebug() []*rt.DebugSQLCapture {
 scope:=rt.DebugEnter(rt.DebugFrame{ID:"access-test-outer"});defer scope.Leave()
 one()
 read:=rt.DebugRuntimeStateSnapshot().SQL
 editOne()
 write:=rt.DebugRuntimeStateSnapshot().SQL
 return []*rt.DebugSQLCapture{read,write}
}
