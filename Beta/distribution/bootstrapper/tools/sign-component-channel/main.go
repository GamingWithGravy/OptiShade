// Signs a first-party component channel payload with the local OptiShade
// release key. The private key is read from LOCALAPPDATA and never emitted.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const trustedPublicKey = "CWd7aeoyOhR9Zt/DaUvMcT8R+DveOd+2aC3twmAcocQ="
const trustedKeyID = "optishade-release-2026"

type dependency struct {
	ComponentID    string `json:"componentId"`
	MinimumVersion string `json:"minimumVersion"`
}
type packageInfo struct {
	Branch string `json:"branch"`
	Path   string `json:"path"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
}
type releaseFile struct {
	PackagePath        string `json:"packagePath"`
	InstallPath        string `json:"installPath"`
	Bytes              int64  `json:"bytes"`
	SHA256             string `json:"sha256"`
	PreconditionSHA256 string `json:"preconditionSha256"`
}
type payload struct {
	Schema        int    `json:"schema"`
	ComponentID   string `json:"componentId"`
	Version       string `json:"version"`
	Channel       string `json:"channel"`
	PublishedUTC  string `json:"publishedUtc"`
	SourceCommit  string `json:"sourceCommit"`
	LauncherRange struct {
		MinInclusive string `json:"minInclusive"`
		MaxExclusive string `json:"maxExclusive"`
	} `json:"launcherRange"`
	Contracts    map[string]string `json:"contracts"`
	Dependencies []dependency      `json:"dependencies"`
	Package      packageInfo       `json:"package"`
	Files        []releaseFile     `json:"files"`
}
type envelope struct {
	payload
	Signature struct {
		Algorithm string `json:"algorithm"`
		KeyID     string `json:"keyId"`
		Value     string `json:"value"`
	} `json:"signature"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 2 {
		return errors.New("usage: go run ./tools/sign-component-channel <payload.json>")
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var p payload
	if err = dec.Decode(&p); err != nil {
		return fmt.Errorf("decode component payload: %w", err)
	}
	var extra any
	if err = dec.Decode(&extra); err != io.EOF {
		return errors.New("component payload contains trailing data")
	}
	if err = validate(p); err != nil {
		return err
	}
	local := os.Getenv("LOCALAPPDATA")
	if local == "" {
		return errors.New("LOCALAPPDATA is unavailable; local release key was not read")
	}
	keyPath := filepath.Join(local, "OptiShade", "Distribution", "release-ed25519-private.pem")
	keyData, err := os.ReadFile(keyPath)
	if err != nil {
		return fmt.Errorf("read local release key: %w", err)
	}
	block, _ := pem.Decode(keyData)
	if block == nil {
		return errors.New("local release key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return fmt.Errorf("parse local release key: %w", err)
	}
	private, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return errors.New("local release key is not Ed25519")
	}
	public := private.Public().(ed25519.PublicKey)
	if base64.StdEncoding.EncodeToString(public) != trustedPublicKey {
		return errors.New("local signing key does not match the public key trusted by the manager")
	}
	canonical, err := json.Marshal(p)
	if err != nil {
		return err
	}
	var out envelope
	out.payload = p
	out.Signature.Algorithm = "Ed25519"
	out.Signature.KeyID = trustedKeyID
	out.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical))
	result, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(append(result, '\n'))
	return err
}

func validate(p payload) error {
	version := regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$`)
	digest := regexp.MustCompile(`(?i)^[a-f0-9]{64}$`)
	commit := regexp.MustCompile(`(?i)^[a-f0-9]{40,64}$`)
	known := map[string]string{"OptiShade.Core": "core", "OptiShade.Effects": "effects", "OptiShade.OptiMFG": "optimfg", "OptiShade.Providers.AMD": "providers-amd", "OptiShade.Providers.Intel": "providers-intel"}
	prefix, ok := known[p.ComponentID]
	if p.Schema != 1 || !ok || (p.Channel != "stable" && p.Channel != "beta") || !version.MatchString(p.Version) || !commit.MatchString(p.SourceCommit) || p.Dependencies == nil || p.Contracts == nil {
		return errors.New("component payload identity or release metadata is incomplete")
	}
	if _, err := time.Parse(time.RFC3339, p.PublishedUTC); err != nil {
		return errors.New("publishedUtc must be RFC3339 UTC")
	}
	if !version.MatchString(p.LauncherRange.MinInclusive) || !version.MatchString(p.LauncherRange.MaxExclusive) || p.LauncherRange.MinInclusive >= p.LauncherRange.MaxExclusive {
		return errors.New("launcher compatibility range is invalid")
	}
	if p.Package.Branch != prefix+"-"+p.Channel || p.Package.Bytes < 1 || p.Package.Bytes > 99<<20 || !digest.MatchString(p.Package.SHA256) || !safe(p.Package.Path) || path.Base(p.Package.Path) == "." {
		return errors.New("package branch, path, size or digest is invalid")
	}
	if len(p.Files) == 0 || len(p.Files) > 4096 {
		return errors.New("component file inventory is empty or too large")
	}
	seenPackage, seenInstall := map[string]bool{}, map[string]bool{}
	for _, f := range p.Files {
		if !safe(f.PackagePath) || !safe(f.InstallPath) || seenPackage[strings.ToLower(f.PackagePath)] || seenInstall[strings.ToLower(f.InstallPath)] || f.Bytes < 0 || f.Bytes > 512<<20 || !digest.MatchString(f.SHA256) || (f.PreconditionSHA256 != "" && !digest.MatchString(f.PreconditionSHA256)) {
			return fmt.Errorf("invalid or duplicate inventory entry: %q", f.InstallPath)
		}
		seenPackage[strings.ToLower(f.PackagePath)] = true
		seenInstall[strings.ToLower(f.InstallPath)] = true
	}
	return nil
}

func safe(value string) bool {
	if value == "" || strings.Contains(value, `\`) || strings.HasPrefix(value, "/") || strings.Contains(value, ":") {
		return false
	}
	clean := path.Clean(value)
	return clean == value && clean != "." && !strings.HasPrefix(clean, "../")
}
