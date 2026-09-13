package teslmodapp
import rt "tesl.generated/teslmodapp/internal/teslrt"
// Invoke the original generated handlers and read ordinary telemetry only.
// No migration metadata, row callback, storage or SQL is supplied by this bridge.
func TestAccessEffects() []string {
 rt.ResetTelemetry()
 effects()
 empty()
 result:=[]string{}
 for _,event:=range rt.TelemetryEvents(){if event.Message=="access-operand" {result=append(result,event.Attributes[0].Tuple2Second)}}
 return result
}
