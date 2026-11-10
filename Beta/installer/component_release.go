package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"strings"
)

const optiShadeReleaseKeyID = "optishade-release-2026"
const optiShadeReleasePublicKey = "CWd7aeoyOhR9Zt/DaUvMcT8R+DveOd+2aC3twmAcocQ="

type signedComponentRelease struct {
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
	Dependencies []struct {
		ComponentID    string `json:"componentId"`
		MinimumVersion string `json:"minimumVersion"`
	} `json:"dependencies"`
	Package struct {
		Branch string `json:"branch"`
		Path   string `json:"path"`
		LFSOID string `json:"lfsOid,omitempty"`
		Bytes  int64  `json:"bytes"`
		SHA256 string `json:"sha256"`
	} `json:"package"`
	Files []struct {
		PackagePath        string `json:"packagePath"`
		InstallPath        string `json:"installPath"`
		Bytes              int64  `json:"bytes"`
		SHA256             string `json:"sha256"`
		PreconditionSHA256 string `json:"preconditionSha256"`
	} `json:"files"`
	Signature struct {
		Algorithm string `json:"algorithm"`
		KeyID     string `json:"keyId"`
		Value     string `json:"value"`
	} `json:"signature"`
}

var releaseVersionPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$`)
var releaseDigestPattern = regexp.MustCompile(`(?i)^[a-f0-9]{64}$`)

// verifySignedComponentRelease checks publisher authenticity and the complete
// file inventory before a package can be staged for a transaction. This
// intentionally does not treat HTTPS or a GitHub branch as publisher proof.
func verifySignedComponentRelease(data []byte) (*signedComponentRelease, error) {
	return verifySignedComponentReleaseWithKey(data, optiShadeReleasePublicKey, optiShadeReleaseKeyID)
}

func verifySignedComponentReleaseWithKey(data []byte, publicKeyB64, keyID string) (*signedComponentRelease, error) {
	if len(data) == 0 || len(data) > 256<<10 {
		return nil, errors.New("component release manifest is empty or exceeds 256 KiB")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var release signedComponentRelease
	if err := dec.Decode(&release); err != nil {
		return nil, fmt.Errorf("invalid signed component manifest: %w", err)
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return nil, errors.New("component release manifest contains trailing data")
	}
	if err := validateSignedComponentRelease(&release); err != nil {
		return nil, err
	}
	if release.Signature.Algorithm != "Ed25519" || release.Signature.KeyID != keyID {
		return nil, errors.New("component publisher signing key is not trusted")
	}
	pub, err := base64.StdEncoding.DecodeString(publicKeyB64)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, errors.New("embedded component publisher key is invalid")
	}
	sig, err := base64.StdEncoding.DecodeString(release.Signature.Value)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return nil, errors.New("component publisher signature is malformed")
	}
	canonical, err := marshalComponentReleasePayload(&release)
	if err != nil || !ed25519.Verify(ed25519.PublicKey(pub), canonical, sig) {
		return nil, errors.New("component release signature verification failed")
	}
	return &release, nil
}

func marshalComponentReleasePayload(r *signedComponentRelease) ([]byte, error) {
	// The schema signs every field except the signature object. Marshal the
	// exact declared payload shape, rather than trusting JSON key order/input.
	return json.Marshal(struct {
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
		Dependencies any               `json:"dependencies"`
		Package      any               `json:"package"`
		Files        any               `json:"files"`
	}{r.Schema, r.ComponentID, r.Version, r.Channel, r.PublishedUTC, r.SourceCommit, r.LauncherRange, r.Contracts, r.Dependencies, r.Package, r.Files})
}

func validateSignedComponentRelease(r *signedComponentRelease) error {
	if r.Schema != 1 || r.ComponentID != "OptiShade.Launcher" && r.ComponentID != "OptiShade.Core" && r.ComponentID != "OptiShade.OptiMFG" && r.ComponentID != "OptiShade.Effects" && r.ComponentID != "OptiShade.Providers.AMD" && r.ComponentID != "OptiShade.Providers.Intel" {
		return errors.New("unsupported component release schema or component ID")
	}
	if !releaseVersionPattern.MatchString(r.Version) || (r.Channel != "stable" && r.Channel != "beta") || !regexp.MustCompile(`^[a-fA-F0-9]{40,64}$`).MatchString(r.SourceCommit) {
		return errors.New("component release version, channel or source commit is invalid")
	}
	if !releaseVersionPattern.MatchString(r.LauncherRange.MinInclusive) || !releaseVersionPattern.MatchString(r.LauncherRange.MaxExclusive) || compareComponentVersions(r.LauncherRange.MinInclusive, r.LauncherRange.MaxExclusive) >= 0 {
		return errors.New("component release launcher compatibility range is invalid")
	}
	if len(r.Contracts) > 64 || len(r.Dependencies) > 16 {
		return errors.New("component release contract or dependency list is too large")
	}
	for name, value := range r.Contracts {
		if !regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._-]{0,63}$`).MatchString(name) || value == "" || len(value) > 128 {
			return errors.New("component release contains an invalid compatibility contract")
		}
	}
	seenDependencies := map[string]bool{}
	for _, dependency := range r.Dependencies {
		if dependency.ComponentID == r.ComponentID || !releaseVersionPattern.MatchString(dependency.MinimumVersion) || !regexp.MustCompile(`^OptiShade\.(Launcher|Core|OptiMFG|Effects|Neural|Providers(\.(AMD|Intel))?)$`).MatchString(dependency.ComponentID) || seenDependencies[dependency.ComponentID] {
			return errors.New("component release contains an invalid or duplicate dependency")
		}
		seenDependencies[dependency.ComponentID] = true
	}
	branch := map[string]string{"OptiShade.Launcher": "launcher", "OptiShade.Core": "core", "OptiShade.OptiMFG": "optimfg", "OptiShade.Effects": "effects", "OptiShade.Providers.AMD": "providers-amd", "OptiShade.Providers.Intel": "providers-intel"}[r.ComponentID] + "-" + r.Channel
	if r.Package.Branch != branch || r.Package.Bytes < 1 || r.Package.Bytes > componentDownloadMaxBytes || !releaseDigestPattern.MatchString(r.Package.SHA256) || (r.Package.LFSOID != "" && (!releaseDigestPattern.MatchString(r.Package.LFSOID) || !strings.EqualFold(r.Package.LFSOID, r.Package.SHA256))) {
		return errors.New("component package branch, size or digest is invalid")
	}
	if !safeReleasePath(r.Package.Path) || path.Base(r.Package.Path) == "." {
		return errors.New("component package path is unsafe")
	}
	if len(r.Files) == 0 || len(r.Files) > 4096 {
		return errors.New("component file inventory is empty or too large")
	}
	seenPackage, seenInstall := map[string]bool{}, map[string]bool{}
	for _, f := range r.Files {
		if !safeReleasePath(f.PackagePath) || !safeReleasePath(f.InstallPath) || seenPackage[strings.ToLower(f.PackagePath)] || seenInstall[strings.ToLower(f.InstallPath)] || f.Bytes < 0 || f.Bytes > 512<<20 || !releaseDigestPattern.MatchString(f.SHA256) {
			return errors.New("component file inventory contains an unsafe, duplicate or invalid entry")
		}
		if f.PreconditionSHA256 != "" && !releaseDigestPattern.MatchString(f.PreconditionSHA256) {
			return errors.New("component file precondition hash is invalid")
		}
		seenPackage[strings.ToLower(f.PackagePath)] = true
		seenInstall[strings.ToLower(f.InstallPath)] = true
	}
	return nil
}

// validateComponentLauncherRange is deliberately a separate check from
// signature validation: the signature proves who published a release, while
// this check proves the current manager is within the publisher-declared
// compatibility interval before any package bytes are staged for install.
func validateComponentLauncherRange(release *signedComponentRelease, launcherVersion string) error {
	if release == nil || !releaseVersionPattern.MatchString(launcherVersion) {
		return errors.New("current launcher version is missing or invalid")
	}
	if compareComponentVersions(launcherVersion, release.LauncherRange.MinInclusive) < 0 ||
		compareComponentVersions(launcherVersion, release.LauncherRange.MaxExclusive) >= 0 {
		return fmt.Errorf("component %s v%s supports launcher versions [%s, %s); this launcher is %s",
			release.ComponentID, release.Version, release.LauncherRange.MinInclusive,
			release.LauncherRange.MaxExclusive, launcherVersion)
	}
	return nil
}

func safeReleasePath(value string) bool {
	if value == "" || strings.Contains(value, `\`) || strings.HasPrefix(value, "/") || strings.Contains(value, ":") {
		return false
	}
	clean := path.Clean(value)
	return clean == value && clean != "." && !strings.HasPrefix(clean, "../")
}
