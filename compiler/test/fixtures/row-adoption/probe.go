package main

import (
 "context"
 "encoding/json"
 "fmt"
 "os"
 "time"
 "github.com/jackc/pgx/v5"
 "tesl.generated/teslmodapp/internal/teslmodapp"
 "tesl.generated/teslmodapp/internal/teslrt"
)

func main() {
 if err := inspect(); err != nil { fmt.Fprintln(os.Stderr,err);os.Exit(1) }
}
func inspect() error {
 db:=teslmodapp.MainDatabase
 if err:=teslrt.PreflightApplicationDatabases(db);err!=nil{return err}
 ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second);defer cancel()
 conn,err:=pgx.Connect(ctx,os.Getenv("ADOPTION_REQUEST_CONNECTION"));if err!=nil{return err}
 defer func(){_ = conn.Close(context.Background())}()
 result,err:=teslrt.InspectPgCompiledRowAdoption(ctx,conn,db);if err!=nil{return err}
 return json.NewEncoder(os.Stdout).Encode(result.Summary())
}
