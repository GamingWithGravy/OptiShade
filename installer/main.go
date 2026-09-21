package main

import (
 "embed"
 "io/fs"
 "os"
 "os/exec"
 "path/filepath"
 "syscall"
 "fmt"
 "unsafe"
)

//go:embed Help/*.txt updates.ps1 update-worker.ps1 update-install.ps1 compatibility.ps1 manager.ps1 library.ps1 ownership.ps1 effects.ps1 consent.ps1 EffectPackages.ini all:PayloadFusion FusionSetup.exe manager.xaml OptiShade.ico OptiShade-app.ico OptiShade-icon.png nvidia.ps1 nvidia-files.json streamline-files.json
var bundle embed.FS

func main() {
 original, err := os.Executable(); if err != nil { os.Exit(1) }
 root := filepath.Join(os.Getenv("LOCALAPPDATA"), "OptiShade", "Sessions")
 if os.MkdirAll(root,0700)!=nil{os.Exit(1)}
 work,err:=os.MkdirTemp(root,"setup-");if err!=nil{os.Exit(1)}
 defer func(){os.RemoveAll(work);os.Remove(root);os.Remove(filepath.Dir(root))}()
 err=fs.WalkDir(bundle,".",func(path string,d fs.DirEntry,walkErr error)error{
  if walkErr!=nil{return walkErr};if path=="."{return nil};target:=filepath.Join(work,filepath.FromSlash(path))
  if d.IsDir(){return os.MkdirAll(target,0700)};data,e:=bundle.ReadFile(path);if e!=nil{return e};return os.WriteFile(target,data,0600)
 });if err!=nil{os.RemoveAll(work);os.Exit(1)}
 args:=[]string{original};updating:=len(os.Args)>1&&os.Args[1]=="--apply-update";if updating{args=append(args,"--apply-update")}
 cmd:=exec.Command(filepath.Join(work,"FusionSetup.exe"),args...)
 cmd.SysProcAttr=&syscall.SysProcAttr{CreationFlags:0x08000000}
 if output,runErr:=cmd.CombinedOutput();runErr!=nil{
  if updating{os.RemoveAll(work);os.Exit(1)}
  message:=fmt.Sprintf("OptiShade could not open: %v\n%s",runErr,output)
  text,_:=syscall.UTF16PtrFromString(message);title,_:=syscall.UTF16PtrFromString("OptiShade setup")
  syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0,uintptr(unsafe.Pointer(text)),uintptr(unsafe.Pointer(title)),0x10)
 }
}
