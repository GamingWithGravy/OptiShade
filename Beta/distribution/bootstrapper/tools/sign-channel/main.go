// Signs a launcher channel payload using the local release key. It prints
// only the public manifest; the private key is read from LOCALAPPDATA.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type payload struct {
	Schema       int               `json:"schema"`
	ComponentID  string            `json:"componentId"`
	Version      string            `json:"version"`
	Channel      string            `json:"channel"`
	SourceCommit string            `json:"sourceCommit"`
	Contracts    map[string]string `json:"contracts"`
	Dependencies []any             `json:"dependencies"`
	Package      struct {
		Path   string `json:"path"`
		LFSOID string `json:"lfsOid,omitempty"`
		Bytes  int64  `json:"bytes"`
		SHA256 string `json:"sha256"`
	} `json:"package"`
}
type signed struct {
	Payload   payload `json:"payload"`
	Signature struct {
		Algorithm string `json:"algorithm"`
		KeyID     string `json:"keyId"`
		Value     string `json:"value"`
	} `json:"signature"`
}

func main() {
	if len(os.Args) != 2 {
		panic("usage: go run ./tools/sign-channel <payload.json>")
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var p payload
	if err = dec.Decode(&p); err != nil {
		panic(err)
	}
	var trailing any
	if err = dec.Decode(&trailing); err != io.EOF {
		panic("payload contains trailing data")
	}
	versionOK, _ := regexp.MatchString(`^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$`, p.Version)
	commitOK, _ := regexp.MatchString(`^[a-fA-F0-9]{40,64}$`, p.SourceCommit)
	hashOK, _ := regexp.MatchString(`^[a-fA-F0-9]{64}$`, p.Package.SHA256)
	if p.Schema != 1 || p.ComponentID != "OptiShade.Launcher" || (p.Channel != "stable" && p.Channel != "beta") || !versionOK || !commitOK || p.Dependencies == nil || p.Package.Bytes < 1 || p.Package.Bytes > 99<<20 || !hashOK || (p.Package.LFSOID != "" && !strings.EqualFold(p.Package.LFSOID, p.Package.SHA256)) || strings.Contains(p.Package.Path, "..") || strings.Contains(p.Package.Path, "\\") || filepath.Base(p.Package.Path) != "OptiShade.exe" {
		panic("launcher payload fields are incomplete")
	}
	privPath := filepath.Join(os.Getenv("LOCALAPPDATA"), "OptiShade", "Distribution", "release-ed25519-private.pem")
	keyData, err := os.ReadFile(privPath)
	if err != nil {
		panic(err)
	}
	block, _ := pem.Decode(keyData)
	if block == nil {
		panic("invalid private key PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		panic(err)
	}
	private, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		panic("private key is not Ed25519")
	}
	canonical, err := json.Marshal(p)
	if err != nil {
		panic(err)
	}
	var result signed
	result.Payload = p
	result.Signature.Algorithm = "Ed25519"
	result.Signature.KeyID = "optishade-release-2026"
	result.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical))
	out, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		panic(err)
	}
	_, err = os.Stdout.Write(append(out, '\n'))
	if err != nil {
		panic(err)
	}
}
