@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0routes"
if not exist bin mkdir bin
cl /nologo /std:c++17 /EHsc /MT /O2 /Zi /LD msfs2024.cpp /Fobin\msfs2024.obj /Febin\OptiShadeMSFS2024.dll /link user32.lib d3d12.lib dxguid.lib /DEBUG /PDB:bin\OptiShadeMSFS2024.pdb /PDBALTPATH:OptiShadeMSFS2024.pdb /INCREMENTAL:NO
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /MT /O2 /Zi /LD msfs2020.cpp /Fobin\msfs2020.obj /Febin\OptiShadeMSFS2020.dll /link user32.lib d3d12.lib dxguid.lib /DEBUG /PDB:bin\OptiShadeMSFS2020.pdb /PDBALTPATH:OptiShadeMSFS2020.pdb /INCREMENTAL:NO
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /MT /O2 /Zi /LD xplane12.cpp /Fobin\xplane12.obj /Febin\OptiShadeXPlane12.dll /link user32.lib d3d12.lib dxguid.lib /DEBUG /PDB:bin\OptiShadeXPlane12.pdb /PDBALTPATH:OptiShadeXPlane12.pdb /INCREMENTAL:NO
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /MT /O2 /Zi /LD generic.cpp /Fobin\generic.obj /Febin\OptiShadeGeneric.dll /link user32.lib d3d12.lib dxguid.lib /DEBUG /PDB:bin\OptiShadeGeneric.pdb /PDBALTPATH:OptiShadeGeneric.pdb /INCREMENTAL:NO
exit /b %errorlevel%
