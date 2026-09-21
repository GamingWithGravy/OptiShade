package main

import (
 "crypto/sha256"
 "encoding/json"
 "fmt"
 "strings"
 "testing"
)

// Check the embedded bytes, not just the staging directory: go:embed normally
// excludes dot files such as Cache/.keep, even when files.json includes them.
func TestEmbeddedPayload(t *testing.T) {
 data, err := bundle.ReadFile("PayloadFusion/files.json")
 if err != nil { t.Fatal(err) }
 var entries []struct { Path, Hash string }
 if err := json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\ufeff")), &entries); err != nil { t.Fatal(err) }
 if len(entries) == 0 { t.Fatal("empty payload catalogue") }
 for _, entry := range entries {
  path := "PayloadFusion/" + strings.ReplaceAll(entry.Path, "\\", "/")
  bytes, err := bundle.ReadFile(path)
  if err != nil { t.Errorf("missing embedded file %s: %v", path, err); continue }
  if !strings.EqualFold(fmt.Sprintf("%x", sha256.Sum256(bytes)), entry.Hash) { t.Errorf("embedded hash mismatch: %s", path) }
 }
 t.Logf("Verified all %d embedded payload files", len(entries))
}

// Windows PowerShell 5.1 interprets BOM-less scripts using the ANSI code page.
// Non-ASCII punctuation can then become quote characters and break parsing.
func TestEmbeddedPowerShellEncoding(t *testing.T) {
 entries, err := bundle.ReadDir(".")
 if err != nil { t.Fatal(err) }
 for _, entry := range entries {
  if !strings.HasSuffix(entry.Name(), ".ps1") { continue }
  data, err := bundle.ReadFile(entry.Name())
  if err != nil { t.Fatal(err) }
  if !strings.HasPrefix(string(data), "\ufeff") { t.Errorf("%s needs a UTF-8 BOM for Windows PowerShell 5.1", entry.Name()) }
 }
}
