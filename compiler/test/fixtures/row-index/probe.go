package main

import (
 "context"
 "fmt"
 "os"
 "time"
 "github.com/jackc/pgx/v5"
 app "tesl.generated/teslmodapp/internal/teslmodapp"
 rt "tesl.generated/teslmodapp/internal/teslrt"
)
func main() {
 ctx,cancel:=context.WithTimeout(context.Background(),10*time.Second);defer cancel()
 conn,err:=pgx.Connect(ctx,os.Getenv("ROW_DDL"));if err!=nil{panic(err)};defer conn.Close(ctx)
 roles:=rt.PgMigrationControlRoles{Owner:os.Getenv("ROW_OWNER"),Worker:os.Getenv("ROW_WORKER"),Request:os.Getenv("ROW_REQUEST")}
 err=rt.TeslTestRowIndexRegistration(ctx,conn,app.MainDatabase,roles,os.Getenv("ROW_INDEX_WRONG")=="1")
 if err==nil {panic("registration probe unexpectedly committed")}
 fmt.Println(err)
}
