package main

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"testing"
	"testing/fstest"
)

func fixturePackage() fstest.MapFS {
	body := []byte("synthetic binary")
	return fstest.MapFS{
		"PayloadFusion/winmm.dll":  {Data: body},
		"PayloadFusion/files.json": {Data: []byte(fmt.Sprintf(`[{"Path":"winmm.dll","Hash":"%x"}]`, sha256.Sum256(body)))},
	}
}
func TestFinalPackageVerification(t *testing.T) {
	if _, err := verifyPackageFiles(fixturePackage()); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"Prompt.md", "Codex_task.txt", "FusionNR Engine/run.py", "FusionNR/run.py", "FusionNR.py", "OptiShade-diagnostics-user.zip", "private/support.json", "model.onnx"} {
		files := fixturePackage()
		files[name] = &fstest.MapFile{Data: []byte("private fixture")}
		if _, err := verifyPackageFiles(files); err == nil {
			t.Fatalf("accepted %s", name)
		}
	}
	files := fixturePackage()
	files["PayloadFusion/winmm.dll"].Data = []byte("damaged")
	if _, err := verifyPackageFiles(files); err == nil {
		t.Fatal("accepted damaged payload")
	}
	files = fixturePackage()
	delete(files, "PayloadFusion/winmm.dll")
	if _, err := verifyPackageFiles(files); err == nil {
		t.Fatal("accepted missing/quarantined payload")
	}
	files = fixturePackage()
	files["PayloadFusion/extra.dll"] = &fstest.MapFile{Data: []byte("untracked")}
	if _, err := verifyPackageFiles(files); err == nil {
		t.Fatal("accepted unmanifested payload")
	}
	files = fixturePackage()
	files["PayloadFusion/files.json"].Data = []byte(`[{"Path":"../outside","Hash":"bad"}]`)
	if _, err := verifyPackageFiles(files); err == nil {
		t.Fatal("accepted traversal")
	}
}

func TestFreshExtractionIncludesSetupHelpers(t *testing.T) {
	original := fixturePackage()
	original["FusionSetup.exe"] = &fstest.MapFile{Data: []byte("synthetic helper")}
	original["manager.ps1"] = &fstest.MapFile{Data: []byte("synthetic script")}
	copyFixture := func() fstest.MapFS {
		result := fstest.MapFS{}
		for name, file := range original {
			clone := *file
			clone.Data = append([]byte{}, file.Data...)
			result[name] = &clone
		}
		return result
	}
	if err := comparePackageInventories(original, copyFixture()); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"FusionSetup.exe", "manager.ps1", "PayloadFusion/winmm.dll"} {
		extracted := copyFixture()
		delete(extracted, name)
		if err := comparePackageInventories(original, extracted); err == nil {
			t.Fatalf("accepted quarantined %s", name)
		}
		extracted = copyFixture()
		extracted[name].Data = []byte("changed after extraction")
		if err := comparePackageInventories(original, extracted); err == nil {
			t.Fatalf("accepted changed %s", name)
		}
	}
	extracted := copyFixture()
	extracted["unexpected.txt"] = &fstest.MapFile{Data: []byte("extra")}
	if err := comparePackageInventories(original, extracted); err == nil {
		t.Fatal("accepted unexpected extraction file")
	}
	extracted = copyFixture()
	extracted["manager.ps1"].Mode = fs.ModeSymlink
	if err := comparePackageInventories(original, extracted); err == nil {
		t.Fatal("accepted linked extraction file")
	}
}
