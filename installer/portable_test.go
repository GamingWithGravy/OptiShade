package main

import (
 "os"
 "path/filepath"
 "testing"
)

func TestPortableStore(t *testing.T) {
 root:=t.TempDir()
 local:=filepath.Join(root,"LocalAppData")
 path,portable:=managerStore(filepath.Join(root,"OptiShade.exe"),local)
 if portable || path!=filepath.Join(local,"OptiShade") {t.Fatal("regular data location changed")}
 marker:=filepath.Join(root,"portable.txt")
 if err:=os.WriteFile(marker,[]byte("portable"),0600);err!=nil{t.Fatal(err)}
 path,portable=managerStore(filepath.Join(root,"OptiShade.exe"),local)
 if !portable || path!=filepath.Join(root,"Data") {t.Fatal("portable data is not beside EXE")}
 moved:=filepath.Join(root,"Moved folder")
 if err:=os.Mkdir(moved,0700);err!=nil{t.Fatal(err)}
 if err:=os.Rename(marker,filepath.Join(moved,"portable.txt"));err!=nil{t.Fatal(err)}
 path,portable=managerStore(filepath.Join(moved,"OptiShade.exe"),local)
 if !portable || path!=filepath.Join(moved,"Data") {t.Fatal("moved portable location is stale")}
}
