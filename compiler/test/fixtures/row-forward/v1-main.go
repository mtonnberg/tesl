package main

import (
	"fmt"
	"os"
	"strconv"
	app "tesl.generated/teslmodapp/internal/teslmodapp"
	rt "tesl.generated/teslmodapp/internal/teslrt"
)

func main() {
	port, _ := strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"))
	app.MainDatabase.Config = rt.PostgresConfig{Host: os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST"), Port: port, DBName: os.Getenv("ROW_DATABASE"), User: os.Getenv("ROW_REQUEST"), Schema: "notes", MigrationTopology: "Worker", ControlOwner: os.Getenv("ROW_OWNER"), WorkerRole: os.Getenv("ROW_WORKER"), RequestRole: os.Getenv("ROW_REQUEST"), DDLConnection: os.Getenv("ROW_DDL")}
	if err := rt.PreflightApplicationDatabases(app.MainDatabase); err != nil {
		panic(err)
	}
	if os.Args[1] == "observe" {
		rt.WithDatabase(app.MainDatabase, func() { fmt.Println("ready") })
		return
	}
	args := []string{"--schema", os.Args[1], "--json"}
	if os.Args[1] == "install" {
		args = append(args, "--worker", os.Getenv("ROW_WORKER"), "--request", os.Getenv("ROW_REQUEST"))
	}
	handled, code := rt.RunSchemaCommand(args, os.Stdout, os.Stderr)
	if !handled {
		panic("not handled")
	}
	os.Exit(code)
}
