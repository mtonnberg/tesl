package cli

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func (app *App) watch(ctx context.Context, args []string) error {
	if len(args) >= 2 && args[0] == "--backend" {
		if args[1] != "go" {
			return fmt.Errorf("only the Go backend is supported")
		}
		args = args[2:]
	}
	files, err := app.files(args)
	if err != nil {
		return err
	}
	file := files[0]
	programArgs := files[1:]
	if !filepath.IsAbs(file) {
		file = filepath.Join(app.Directory, file)
	}
	dependencies := func() []string {
		paths := []string{file}
		if output, err := app.capture(ctx, "compiler", app.Directory, "--deps", file); err == nil {
			for _, path := range strings.Split(output, "\n") {
				path = strings.TrimSpace(path)
				if path != "" {
					if !filepath.IsAbs(path) {
						path = filepath.Join(app.Directory, path)
					}
					paths = append(paths, path)
				}
			}
		}
		sort.Strings(paths)
		return paths
	}
	paths := dependencies()
	previous := watchFingerprint(paths)
	var cancel context.CancelFunc
	var stopped chan struct{}
	stop := func() {
		if cancel != nil {
			cancel()
			<-stopped
			cancel = nil
		}
	}
	defer stop()
	start := func() {
		childContext, childCancel := context.WithCancel(ctx)
		cancel = childCancel
		stopped = make(chan struct{})
		go func(done chan struct{}) {
			defer close(done)
			defer childCancel()
			if err := app.executeSource(childContext, file, programArgs, false, false, "", ""); err != nil && childContext.Err() == nil {
				_, _ = fmt.Fprintln(app.Stderr, "tesl watch:", err, "— waiting for changes")
			}
		}(stopped)
	}
	start()
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			current := watchFingerprint(paths)
			if current == previous {
				continue
			}
			stop()
			paths = dependencies()
			previous = watchFingerprint(paths)
			_, _ = fmt.Fprintln(app.Stderr, "tesl watch: source changed; restarting")
			start()
		}
	}
}

// Include directory entries so creating a previously missing imported module
// causes a retry, as do deletion/rename and same-size content changes.
func watchFingerprint(paths []string) [32]byte {
	hash := sha256.New()
	directories := map[string]bool{}
	for _, path := range paths {
		_, _ = fmt.Fprintln(hash, path)
		data, err := os.ReadFile(path) // #nosec G304 -- watch intentionally reads the entry and compiler-resolved dependency paths.
		if err != nil {
			_, _ = fmt.Fprintln(hash, err)
		} else {
			_, _ = hash.Write(data)
		}
		directory := filepath.Dir(path)
		if directories[directory] {
			continue
		}
		directories[directory] = true
		entries, err := os.ReadDir(directory)
		if err != nil {
			_, _ = fmt.Fprintln(hash, err)
			continue
		}
		for _, entry := range entries {
			if strings.HasSuffix(strings.ToLower(entry.Name()), ".tesl") {
				_, _ = fmt.Fprintln(hash, entry.Name())
			}
		}
	}
	var digest [32]byte
	copy(digest[:], hash.Sum(nil))
	return digest
}
