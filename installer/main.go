// Copyright (c) 2026 gravy / GamingWithGravy. All Rights Reserved.
// OptiShade Proprietary Material: standalone launcher source only.
// See LICENSES/OPTISHADE-PROPRIETARY.txt and OPTISHADE_LICENSING.md.
// Embedded third-party/GPL payloads retain their own licences.
// Earlier GPL grants and applicable platform permissions remain intact.
// No further copying, modification, redistribution or incorporation into
// another project is permitted except under the applicable licence or law.
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

//go:embed DumpSummary.cs crash-dumps.ps1 diagnostics.ps1 menu-settings.ps1 import-effects.ps1 dialog-theme.xaml release-notes.ps1 neural-download.ps1 recovery.ps1 FusionCinema/* Help/*.txt updates.ps1 update-worker.ps1 update-install.ps1 compatibility.ps1 manager.ps1 library.ps1 ownership.ps1 effects.ps1 consent.ps1 EffectPackages.ini all:PayloadFusion FusionSetup.exe manager.xaml OptiShade.ico OptiShade-app.ico OptiShade-icon.png nvidia.ps1 nvidia-files.json streamline-files.json
var bundle embed.FS

func main() {
 updating:=len(os.Args)>1&&(os.Args[1]=="--apply-update"||os.Args[1]=="--check-update")
 result:="";if updating&&len(os.Args)>2{result=os.Args[2]}
 fail:=func(err error){
  if updating{folder:=filepath.Join(os.Getenv("LOCALAPPDATA"),"OptiShade");os.MkdirAll(folder,0700);os.WriteFile(filepath.Join(folder,"Update-error.txt"),[]byte(err.Error()),0600);if result!=""{os.WriteFile(result,[]byte("ERROR: "+err.Error()),0600)}}
  os.Exit(1)
 }
 original, err := os.Executable(); if err != nil { os.Exit(1) }
 root := filepath.Join(os.Getenv("LOCALAPPDATA"), "OptiShade", "Sessions")
 if err=os.MkdirAll(root,0700);err!=nil{fail(err)}
 var required uint64=64*1024*1024
 err=fs.WalkDir(bundle,".",func(path string,d fs.DirEntry,e error)error{if e!=nil{return e};if !d.IsDir(){info,e:=d.Info();if e!=nil{return e};required+=uint64(info.Size())};return nil});if err!=nil{fail(err)}
 var available uint64;rootPtr,_:=syscall.UTF16PtrFromString(root)
 ok,_,spaceErr:=syscall.NewLazyDLL("kernel32.dll").NewProc("GetDiskFreeSpaceExW").Call(uintptr(unsafe.Pointer(rootPtr)),uintptr(unsafe.Pointer(&available)),0,0)
 if ok==0{fail(fmt.Errorf("Cannot check temporary extraction space: %v",spaceErr))}
 if available<required{fail(fmt.Errorf("Not enough disk space to extract OptiShade Manager: need %d MB, available %d MB. Free space and retry; game files were not changed.",required/1048576,available/1048576))}
 work,err:=os.MkdirTemp(root,"setup-");if err!=nil{fail(err)}
 defer func(){os.RemoveAll(work);os.Remove(root);os.Remove(filepath.Dir(root))}()
 err=fs.WalkDir(bundle,".",func(path string,d fs.DirEntry,walkErr error)error{
  if walkErr!=nil{return walkErr};if path=="."{return nil};target:=filepath.Join(work,filepath.FromSlash(path))
  if d.IsDir(){return os.MkdirAll(target,0700)};data,e:=bundle.ReadFile(path);if e!=nil{return e};return os.WriteFile(target,data,0600)
 });if err!=nil{os.RemoveAll(work);fail(err)}
 args:=[]string{original};if updating{args=append(args,os.Args[1]);os.Remove(filepath.Join(filepath.Dir(root),"Update-error.txt"))}
 cmd:=exec.Command(filepath.Join(work,"FusionSetup.exe"),args...)
 cmd.SysProcAttr=&syscall.SysProcAttr{CreationFlags:0x08000000}
 if output,runErr:=cmd.CombinedOutput();runErr!=nil{
  if updating{detail,_:=os.ReadFile(filepath.Join(filepath.Dir(root),"Update-error.txt"));os.RemoveAll(work);fail(fmt.Errorf("Update helper failed: %v\n%s\n%s",runErr,output,detail))}
  message:=fmt.Sprintf("OptiShade could not open: %v\n%s",runErr,output)
  text,_:=syscall.UTF16PtrFromString(message);title,_:=syscall.UTF16PtrFromString("OptiShade setup")
  syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0,uintptr(unsafe.Pointer(text)),uintptr(unsafe.Pointer(title)),0x10)
 }
 if updating&&result!=""{if err=os.WriteFile(result,[]byte("OK"),0600);err!=nil{fail(err)}}
 // Older updater versions do not clean their recovery copy after success.
 // Only remove the exact sibling backup after the game-update helper succeeded.
 if updating&&os.Args[1]=="--apply-update"{os.Remove(original+".previous")}
}
