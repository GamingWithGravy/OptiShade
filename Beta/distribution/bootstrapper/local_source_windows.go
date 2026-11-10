//go:build windows

// Copyright (c) 2026 GamingWithGravy. OptiShade proprietary bootstrapper source.
package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// The same variable the launcher uses for component channels. When it names a
// folder, the installer reads <folder>/launcher-stable/... instead of GitHub,
// so a release can be tested end to end before it is published. Everything read
// from it is still checked against the signed channel and its SHA-256.
const localSourceRootEnv = "OPTISHADE_COMPONENT_SOURCE_ROOT"

func localSourceRoot() (string, bool, error) {
	value := strings.TrimSpace(os.Getenv(localSourceRootEnv))
	if value == "" {
		return "", false, nil
	}
	if !filepath.IsAbs(value) {
		return "", true, errors.New("the local release folder must be an absolute path")
	}
	info, err := os.Lstat(value)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", true, errors.New("the local release folder must be an existing normal folder")
	}
	resolved, err := filepath.EvalSymlinks(value)
	if err != nil || !strings.EqualFold(filepath.Clean(resolved), filepath.Clean(value)) {
		return "", true, errors.New("the local release folder resolves through a link")
	}
	return filepath.Clean(value), true, nil
}

// openLocalSourceFile opens <root>/<branch>/<relative> refusing links and oversized files.
func openLocalSourceFile(root, branch, relative string, maximum int64) (*os.File, int64, error) {
	if strings.Contains(relative, "..") || strings.HasPrefix(relative, "/") || strings.Contains(relative, `\`) || strings.Contains(branch, "/") || strings.Contains(branch, `\`) {
		return nil, 0, errors.New("local release path is unsafe")
	}
	path := filepath.Join(root, branch)
	for _, segment := range append([]string{""}, strings.Split(relative, "/")...) {
		if segment != "" {
			path = filepath.Join(path, segment)
		}
		info, err := os.Lstat(path)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			return nil, 0, errors.New("local release file is missing or traverses a link")
		}
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximum {
		return nil, 0, errors.New("local release file is not a regular file or is too large")
	}
	file, err := os.Open(path)
	return file, info.Size(), err
}

func readLocalSourceFile(root, branch, relative string, maximum int64) ([]byte, error) {
	file, _, err := openLocalSourceFile(root, branch, relative, maximum)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || int64(len(data)) > maximum {
		return nil, errors.New("local release file is unreadable or too large")
	}
	return data, nil
}

// copyLocalLauncher copies the local package to a temporary file. The caller
// verifies its size and SHA-256 against the signed channel before installing.
func copyLocalLauncher(root, branch, packagePath string, size int64, onProgress func(current, total int64)) (string, error) {
	source, actual, err := openLocalSourceFile(root, branch, packagePath, maxLauncherBytes)
	if err != nil {
		return "", err
	}
	defer source.Close()
	if actual != size {
		return "", errors.New("local launcher package size does not match the signed channel")
	}
	temp, err := os.CreateTemp(os.TempDir(), "OptiShade-launcher-*.download")
	if err != nil {
		return "", err
	}
	name := temp.Name()
	_, copyErr := io.Copy(temp, io.LimitReader(source, size+1))
	closeErr := temp.Close()
	if copyErr == nil {
		copyErr = closeErr
	}
	if copyErr != nil {
		os.Remove(name)
		return "", copyErr
	}
	if onProgress != nil {
		onProgress(size, size)
	}
	return name, nil
}
