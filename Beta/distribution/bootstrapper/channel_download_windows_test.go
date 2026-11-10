//go:build windows

package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func signedLauncherManifest(t *testing.T) ([]byte, string, *channelPayload, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p := &channelPayload{Schema: 1, ComponentID: "OptiShade.Launcher", Version: "1.0.77", Channel: "stable", SourceCommit: strings.Repeat("a", 40), Contracts: map[string]string{}, Dependencies: []any{}}
	p.Package.Path = "packages/OptiShade.exe"
	p.Package.Bytes = 16
	p.Package.SHA256 = strings.Repeat("b", 64)
	canonical, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	signed := signedChannel{Payload: *p}
	signed.Signature.Algorithm = "Ed25519"
	signed.Signature.KeyID = keyID
	signed.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))
	data, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}
	return data, base64.StdEncoding.EncodeToString(pub), p, priv
}

func TestVerifySignedChannelAcceptsOnlyValidTrustedManifest(t *testing.T) {
	data, pub, payload, priv := signedLauncherManifest(t)
	if _, err := verifySignedChannel(data, "stable", pub); err != nil {
		t.Fatalf("valid signed manifest rejected: %v", err)
	}
	if _, err := verifySignedChannel(data, "beta", pub); err == nil {
		t.Fatal("stable manifest accepted for beta channel")
	}
	if _, err := verifySignedChannel(append(data, []byte("{}")...), "stable", pub); err == nil {
		t.Fatal("manifest with trailing JSON accepted")
	}

	var tampered signedChannel
	if err := json.Unmarshal(data, &tampered); err != nil {
		t.Fatal(err)
	}
	tampered.Payload.Version = "9.9.9"
	changed, _ := json.Marshal(tampered)
	if _, err := verifySignedChannel(changed, "stable", pub); err == nil {
		t.Fatal("payload alteration accepted without a new signature")
	}

	payload.Package.Path = "../OptiShade.exe"
	canonical, _ := json.Marshal(payload)
	tampered = signedChannel{Payload: *payload}
	tampered.Signature.Algorithm = "Ed25519"
	tampered.Signature.KeyID = keyID
	tampered.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))
	unsafePath, _ := json.Marshal(tampered)
	if _, err := verifySignedChannel(unsafePath, "stable", pub); err == nil {
		t.Fatal("signed path traversal accepted")
	}
	if _, err := verifySignedChannel(data, "stable", "not-a-key"); err == nil {
		t.Fatal("malformed pinned public key accepted")
	}
	payload.Package.SHA256 = strings.Repeat("g", 64)
	canonical, _ = json.Marshal(payload)
	tampered = signedChannel{Payload: *payload}
	tampered.Signature.Algorithm = "Ed25519"
	tampered.Signature.KeyID = keyID
	tampered.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))
	badDigest, _ := json.Marshal(tampered)
	if _, err := verifySignedChannel(badDigest, "stable", pub); err == nil {
		t.Fatal("non-hex SHA-256 accepted in signed manifest")
	}
}

func TestGitHubContentHostAllowlist(t *testing.T) {
	for _, host := range []string{"raw.githubusercontent.com", "objects.githubusercontent.com"} {
		if !githubContentHostAllowed(host) {
			t.Errorf("GitHub content host %q unexpectedly rejected", host)
		}
	}
	for _, host := range []string{"github.com", "raw.githubusercontent.com.evil.invalid", "evilgithubusercontent.com", "httpbin.org"} {
		if githubContentHostAllowed(host) {
			t.Errorf("non-GitHub content host %q unexpectedly allowed", host)
		}
	}
}

func TestDownloadVerifiedLauncherChecksTransportSizeAndDigest(t *testing.T) {
	body := []byte("locally served verified launcher")
	digest := sha256.Sum256(body)
	sha := hex.EncodeToString(digest[:])
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(body)
	}))
	defer server.Close()
	serverHost, _, err := net.SplitHostPort(server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	allowHost := func(host string) bool { return host == strings.ToLower(serverHost) }
	client := launcherHTTPClient(2*time.Second, allowHost)
	client.Transport = server.Client().Transport
	var progress int64
	path, err := downloadVerifiedLauncherWithClient(server.URL+"/OptiShade.exe", int64(len(body)), sha, allowHost, func(n, total int64) {
		if total != int64(len(body)) {
			t.Errorf("progress total %d, want %d", total, len(body))
		}
		progress = n
	}, client)
	if err != nil {
		t.Fatalf("valid local download rejected: %v", err)
	}
	defer os.Remove(path)
	got, err := os.ReadFile(path)
	if err != nil || string(got) != string(body) {
		t.Fatalf("downloaded file mismatch: err=%v", err)
	}
	if progress != int64(len(body)) {
		t.Fatalf("progress ended at %d, want %d", progress, len(body))
	}

	if _, err = downloadVerifiedLauncherWithClient(server.URL, int64(len(body)), strings.Repeat("0", 64), allowHost, nil, client); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("wrong digest was not rejected: %v", err)
	}
	if _, err = downloadVerifiedLauncherWithClient(server.URL, int64(len(body)), strings.Repeat("g", 64), allowHost, nil, client); err == nil {
		t.Fatal("malformed SHA-256 accepted")
	}
	if _, err = downloadVerifiedLauncherWithClient(server.URL, int64(len(body)+1), sha, allowHost, nil, client); err == nil || !strings.Contains(err.Error(), "size") {
		t.Fatalf("wrong signed size was not rejected: %v", err)
	}
	if _, err = downloadVerifiedLauncherWithClient(strings.Replace(server.URL, "https://", "http://", 1), int64(len(body)), sha, allowHost, nil, client); err == nil {
		t.Fatal("unencrypted launcher URL accepted")
	}
	if _, err = downloadVerifiedLauncherWithClient(server.URL, int64(len(body)), sha, func(string) bool { return false }, nil, client); err == nil {
		t.Fatal("untrusted download host accepted")
	}
}

func TestDownloadVerifiedLauncherRejectsUntrustedRedirect(t *testing.T) {
	redirect := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://untrusted.invalid/OptiShade.exe", http.StatusFound)
	}))
	defer redirect.Close()
	redirectHost, _, err := net.SplitHostPort(redirect.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	allowHost := func(host string) bool { return host == strings.ToLower(redirectHost) }
	client := launcherHTTPClient(2*time.Second, allowHost)
	client.Transport = redirect.Client().Transport
	_, err = downloadVerifiedLauncherWithClient(redirect.URL, 1, strings.Repeat("0", 64), allowHost, nil, client)
	if err == nil || !strings.Contains(err.Error(), "unsafe redirect") {
		t.Fatalf("untrusted redirect was not blocked: %v", err)
	}
}
