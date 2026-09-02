package protocol

import (
	"errors"
	"net/url"
	"path/filepath"
	"strings"
)

func URIToPath(value string) (string, error) {
	parsed, err := url.Parse(value)
	if err != nil {
		return "", err
	}
	if parsed.Scheme != "file" {
		return "", errors.New("protocol: document URI is not a file URI")
	}
	path, err := url.PathUnescape(parsed.EscapedPath())
	if err != nil {
		return "", err
	}
	if parsed.Host != "" && parsed.Host != "localhost" {
		path = "//" + parsed.Host + path
	}
	if filepath.Separator == '\\' && strings.HasPrefix(path, "/") && len(path) > 2 && path[2] == ':' {
		path = path[1:]
	}
	cleaned := filepath.Clean(path)
	if parsed.Host != "" && parsed.Host != "localhost" && filepath.Separator == '/' {
		cleaned = "//" + strings.TrimPrefix(cleaned, "/")
	}
	return cleaned, nil
}

func PathToURI(path string) string {
	absolute, err := filepath.Abs(path)
	if err == nil {
		path = absolute
	}
	return (&url.URL{Scheme: "file", Path: filepath.ToSlash(path)}).String()
}
