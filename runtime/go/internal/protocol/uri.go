package protocol

import (
	"errors"
	"net/url"
	"path"
	"path/filepath"
	"runtime"
	"strings"
)

func URIToPath(value string) (string, error) {
	return uriToPath(value, runtime.GOOS == "windows")
}

func uriToPath(value string, windows bool) (string, error) {
	parsed, err := url.Parse(value)
	if err != nil {
		return "", err
	}
	if parsed.Scheme != "file" {
		return "", errors.New("protocol: document URI is not a file URI")
	}
	if parsed.Opaque != "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.ForceQuery {
		return "", errors.New("protocol: file URI must contain only an absolute file path")
	}
	filePath, err := url.PathUnescape(parsed.EscapedPath())
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(filePath, "/") || strings.ContainsRune(filePath, 0) || strings.Contains(filePath, "\\") {
		return "", errors.New("protocol: invalid absolute file URI path")
	}
	remote := parsed.Host != "" && !strings.EqualFold(parsed.Host, "localhost")
	if strings.ContainsAny(parsed.Host, ":\\") {
		return "", errors.New("protocol: invalid file URI host")
	}
	filePath = path.Clean(filePath)
	if windows {
		if remote {
			filePath = "//" + parsed.Host + filePath
		} else if len(filePath) >= 3 && filePath[0] == '/' && asciiLetter(filePath[1]) && filePath[2] == ':' && (len(filePath) == 3 || filePath[3] == '/') {
			filePath = strings.TrimPrefix(filePath, "/")
			if len(filePath) == 2 {
				filePath += "/"
			}
		} else {
			return "", errors.New("protocol: Windows file URI needs a drive or UNC host")
		}
		return strings.ReplaceAll(filePath, "/", "\\"), nil
	}
	if remote {
		filePath = "//" + parsed.Host + filePath
	}
	return filePath, nil
}

func PathToURI(path string) string {
	absolute, err := filepath.Abs(path)
	if err == nil {
		path = absolute
	}
	return pathToURI(path, runtime.GOOS == "windows")
}

func asciiLetter(c byte) bool { return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }

func pathToURI(filePath string, windows bool) string {
	host := ""
	if windows {
		filePath = strings.ReplaceAll(filePath, "\\", "/")
		if strings.HasPrefix(filePath, "//") {
			host, filePath, _ = strings.Cut(strings.TrimPrefix(filePath, "//"), "/")
			filePath = "/" + filePath
		} else if len(filePath) >= 2 && asciiLetter(filePath[0]) && filePath[1] == ':' {
			filePath = "/" + filePath
		}
	}
	return (&url.URL{Scheme: "file", Host: host, Path: filePath}).String()
}
