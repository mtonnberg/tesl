package teslmodapp
import (
 "fmt"
 "strings"
 current "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 rt "tesl.generated/teslmodapp/internal/teslrt"
)
func TestAccessBindings() string {
 expect:=func(run func()){failed:=false;func(){defer func(){failed=recover()!=nil}();run()}();if !failed{panic("invalid typed access registration accepted")}}
 if err:=rt.PreflightApplicationDatabases(MainDatabase);err==nil||!strings.Contains(err.Error(),"entity access bindings are incomplete"){panic(fmt.Sprint("wrong missing access guard: ",err))}
 if _,err:=MainDatabaseCompiledRowTransform0.Run(old.Note{});err==nil{panic("failed preflight sealed callback")}
 expect(func(){rt.RegisterCompiledRowAccess[old.Note,current.Note](nil,current.TeslRowAccessNote)})
 expect(func(){rt.RegisterCompiledRowAccess(MainDatabaseCompiledRowStorage0,(*rt.PgRowAccessSlot[current.Note])(nil))})
 rt.RegisterCompiledRowAccess(MainDatabaseCompiledRowStorage0,current.TeslRowAccessNote)
 expect(func(){rt.RegisterCompiledRowAccess(MainDatabaseCompiledRowStorage0,rt.NewPgRowAccessSlot[current.Note]())})
 if err:=rt.PreflightApplicationDatabases(MainDatabase);err!=nil{panic(err)}
 expect(func(){rt.RegisterCompiledRowAccess(MainDatabaseCompiledRowStorage0,rt.NewPgRowAccessSlot[current.Note]())})
 return "missing/zero/nil/duplicate/late access and unsealed callback retry passed"
}
