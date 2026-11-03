package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	app "tesl.generated/teslmodapp/internal/teslmodapp"
	current "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
	rt "tesl.generated/teslmodapp/internal/teslrt"
)

func main() {
	port, _ := strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"))
	app.MainDatabase.Config = rt.PostgresConfig{Host: os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST"), Port: port, DBName: os.Getenv("ROW_DATABASE"), User: os.Getenv("ROW_REQUEST"), Schema: "notes", MigrationTopology: "Worker", ControlOwner: os.Getenv("ROW_OWNER"), WorkerRole: os.Getenv("ROW_WORKER"), RequestRole: os.Getenv("ROW_REQUEST"), DDLConnection: os.Getenv("ROW_DDL")}
	if err := rt.PreflightApplicationDatabases(app.MainDatabase); err != nil {
		panic(err)
	}
	if os.Args[1] == "park" {
		rt.WithDatabase(app.MainDatabase, func() {
			fmt.Println("opened")
			scanner := bufio.NewScanner(os.Stdin)
			for scanner.Scan() {
				if scanner.Text() == "quit" {
					return
				}
				value, found, err := rt.CalibrationRead(context.Background(), app.MainDatabase, app.MainDatabaseCompiledRowStorage0, "one")
				if err != nil {
					json.NewEncoder(os.Stdout).Encode(map[string]any{"error": err.Error()})
				} else {
					json.NewEncoder(os.Stdout).Encode(map[string]any{"found": found, "value": value})
				}
			}
		})
		return
	}
	if os.Args[1] == "tx-update" {
		if err := rt.CalibrationReadThenUpdate(context.Background(), app.MainDatabase, app.MainDatabaseCompiledRowStorage0, os.Args[2], func(v current.Note) current.Note { v.Title = "transaction updated"; return v }); err != nil {
			panic(err)
		}
		fmt.Println("updated")
		return
	}
	if os.Args[1] == "read" || os.Args[1] == "reject" {
		key := "one"
		if os.Args[1] == "reject" {
			key = "reject"
		}
		value, found, err := rt.CalibrationRead(context.Background(), app.MainDatabase, app.MainDatabaseCompiledRowStorage0, key)
		if err != nil || !found {
			panic(fmt.Sprint(found, err))
		}
		json.NewEncoder(os.Stdout).Encode(value)
		return
	}
	if os.Args[1] == "cancel" {
		old, found, err := rt.CalibrationRead(context.Background(), app.MainDatabase, app.MainDatabaseCompiledRowStorage0, "one")
		if err != nil || !found {
			panic(fmt.Sprint(found, err))
		}
		old.Id = "canceled"
		if err := rt.CalibrationCancelAfterDML(app.MainDatabase, app.MainDatabaseCompiledRowStorage0, old); err != nil {
			panic(err)
		}
		return
	}
	if os.Args[1] == "insert" {
		old, found, err := rt.CalibrationRead(context.Background(), app.MainDatabase, app.MainDatabaseCompiledRowStorage0, "one")
		if err != nil || !found {
			panic(fmt.Sprint(found, err))
		}
		old.Id = "two"
		old.Owner = "new owner"
		if err := rt.CalibrationInsert(context.Background(), app.MainDatabase, app.MainDatabaseCompiledRowStorage0, old); err != nil {
			panic(err)
		}
		return
	}
	if os.Args[1] == "update" {
		if err := rt.CalibrationUpdate(context.Background(), app.MainDatabase, app.MainDatabaseCompiledRowStorage0, "one", func(v current.Note) current.Note { v.Title = "updated"; return v }); err != nil {
			panic(err)
		}
		return
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
