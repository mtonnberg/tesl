package install

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/childprocess"
)

type launchObservation struct {
	PID       int      `json:"pid"`
	Arguments []string `json:"arguments"`
	Root      string   `json:"root"`
	Pin       string   `json:"pin"`
}

func TestInstalledLaunchHelper(t *testing.T) {
	switch os.Getenv("TESL_LAUNCH_HELPER") {
	case "":
		return
	case "launcher":
		executable, err := os.Executable()
		if err != nil || os.Setenv("TESL_LAUNCH_HELPER", "selected") != nil {
			os.Exit(2)
		}
		err = Launch(executable, "tesl", os.Args[1:])
		var status *exec.ExitError
		if errors.As(err, &status) {
			os.Exit(status.ExitCode())
		}
		if err != nil {
			_, _ = os.Stderr.WriteString(err.Error())
			os.Exit(2)
		}
		os.Exit(0)
	case "selected":
		observation := launchObservation{PID: os.Getpid(), Arguments: os.Args[1:], Root: os.Getenv("TESL_TOOLCHAIN_ROOT"), Pin: os.Getenv("TESL_INSTALL_VERSION")}
		data, err := json.Marshal(observation)
		if err != nil || os.WriteFile(os.Getenv("TESL_LAUNCH_OBSERVATION"), data, 0600) != nil {
			os.Exit(2)
		}
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := os.Stat(os.Getenv("TESL_LAUNCH_STOP")); err == nil {
				code, _ := strconv.Atoi(os.Getenv("TESL_LAUNCH_EXIT"))
				os.Exit(code)
			}
			time.Sleep(10 * time.Millisecond)
		}
		os.Exit(3)
	default:
		os.Exit(2)
	}
}

func TestNativeLauncherPinsSelectionAndHoldsLeaseUntilChildExit(t *testing.T) {
	m := testManager(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	m.Executable = executable
	binary, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	entries := fixtureEntries(t, "0.3.1")
	entries[0].data = binary
	archive, digest := fixtureArchive(t, "0.3.1", "zip", entries)
	if _, err := m.Install(context.Background(), archive, digest); err != nil {
		t.Fatal(err)
	}
	installFixture(t, m, "0.3.2")
	observationFile := filepath.Join(t.TempDir(), "observation.json")
	stop := filepath.Join(t.TempDir(), "stop")
	literal := "literal argument å 😀 ; & $()"
	command := exec.Command(filepath.Join(m.Root, "bin", "tesl"+binarySuffix()), "-test.run=^TestInstalledLaunchHelper$", "--", literal)
	command.Env = append(launcherEnvironment(filepath.Join(m.Root, "bin", "tesl"+binarySuffix())),
		"TESL_LAUNCH_HELPER=launcher", "TESL_INSTALL_VERSION=0.3.1", "TESL_LAUNCH_EXIT=37",
		"TESL_LAUNCH_OBSERVATION="+observationFile, "TESL_LAUNCH_STOP="+stop)
	child, err := childprocess.Start(command)
	if err != nil {
		t.Fatal(err)
	}
	if command.Process == nil {
		t.Fatal("launcher returned without starting a process")
	}
	waited := false
	t.Cleanup(func() {
		if !waited {
			child.Kill()
			_ = child.Wait()
		}
	})
	var observation launchObservation
	deadline := time.Now().Add(15 * time.Second)
	for {
		data, err := os.ReadFile(observationFile)
		if err == nil && json.Unmarshal(data, &observation) == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("selected frontend never reported its launch: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if observation.Root != filepath.Join(m.Root, "versions", "0.3.1") || observation.Pin != "" {
		t.Fatalf("launcher selection environment: %+v", observation)
	}
	if got := observation.Arguments[len(observation.Arguments)-1]; got != literal {
		t.Fatalf("literal argument changed: %q", got)
	}
	if runtime.GOOS != "windows" && observation.PID != command.Process.Pid {
		t.Fatal("Unix launcher did not preserve its PID through exec")
	}
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err == nil || !strings.Contains(err.Error(), "in use") {
		t.Fatalf("inherited launcher lease failed: %v", err)
	}
	if _, err := m.Select("0.3.2"); err != nil {
		t.Fatalf("running frontend blocked selecting another version: %v", err)
	}
	if err := os.WriteFile(stop, []byte("stop"), 0600); err != nil {
		t.Fatal(err)
	}
	err = child.Wait()
	waited = true
	var status *exec.ExitError
	if !errors.As(err, &status) || status.ExitCode() != 37 {
		t.Fatalf("child status was not preserved: %v", err)
	}
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err != nil {
		t.Fatalf("completed frontend retained its lease: %v", err)
	}
}

func TestLaunchSelectionRejectsUnknownOrMalformedPins(t *testing.T) {
	m := testManager(t)
	installFixture(t, m, "0.3.1")
	bootstrap := filepath.Join(m.Root, "bin", "tesl-install"+binarySuffix())
	for _, name := range []string{"sh", "tesl-install", "TESL", "tesl.exe.exe", "tesl-malicious"} {
		if IsFrontend(name) {
			t.Fatalf("unrecognized frontend accepted: %q", name)
		}
	}
	for _, name := range Frontends {
		if !IsFrontend(filepath.Join("some directory", name+binarySuffix())) {
			t.Fatalf("valid frontend rejected: %q", name)
		}
	}
	for _, version := range []string{"../outside", "0.3.9"} {
		t.Setenv("TESL_INSTALL_VERSION", version)
		if _, lease, err := selectedFrontend(bootstrap, "tesl"); err == nil {
			_ = lease.Close()
			t.Fatalf("invalid pin %q resolved", version)
		}
	}
}

func TestLauncherEnvironmentDropsCrossRootPin(t *testing.T) {
	t.Setenv("TESL_INSTALL_VERSION", "0.3.1")
	t.Setenv("TESL_TOOLCHAIN_ROOT", "stale installation root")
	selected := filepath.Join(t.TempDir(), "versions", "0.3.2", "bin", "tesl"+binarySuffix())
	count := 0
	for _, entry := range launcherEnvironment(selected) {
		key, value, _ := strings.Cut(entry, "=")
		if strings.EqualFold(key, "TESL_INSTALL_VERSION") {
			t.Fatal("pin escaped into selected frontend environment")
		}
		if strings.EqualFold(key, "TESL_TOOLCHAIN_ROOT") {
			count++
			if value != filepath.Dir(filepath.Dir(selected)) {
				t.Fatal("frontend did not receive selected manifest root")
			}
		}
	}
	if count != 1 {
		t.Fatal("selected manifest root was absent or duplicated")
	}
}
