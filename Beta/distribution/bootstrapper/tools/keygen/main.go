// Local-only key setup utility. It writes a private signing key under
// %LOCALAPPDATA%\OptiShade\Distribution and prints only the public key.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	root := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(root) {
		panic("LOCALAPPDATA must be an absolute path")
	}
	dir := filepath.Join(root, "OptiShade", "Distribution")
	if err := os.MkdirAll(dir, 0700); err != nil {
		panic(err)
	}
	privatePath := filepath.Join(dir, "release-ed25519-private.pem")
	if existing, err := os.ReadFile(privatePath); err == nil {
		block, _ := pem.Decode(existing)
		if block == nil {
			panic("existing private key is not valid PEM")
		}
		parsed, e := x509.ParsePKCS8PrivateKey(block.Bytes)
		if e != nil {
			panic(e)
		}
		private, ok := parsed.(ed25519.PrivateKey)
		if !ok {
			panic("existing private key has the wrong type")
		}
		fmt.Println(base64.StdEncoding.EncodeToString(private.Public().(ed25519.PublicKey)))
		return
	} else if !os.IsNotExist(err) {
		panic(err)
	}
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		panic(err)
	}
	data := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	f, err := os.OpenFile(privatePath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		panic(err)
	}
	if _, err = f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(privatePath)
		panic(err)
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(privatePath)
		panic(err)
	}
	if err = f.Close(); err != nil {
		_ = os.Remove(privatePath)
		panic(err)
	}
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
}
