@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W3 /DUNICODE /D_UNICODE /DIMGUI_ENABLE_TEST_ENGINE /I optiscaler\external\nlohmann /I optiscaler\external\freetype tests\mfg-ui.cpp optiscaler\OptiScaler\include\imgui\imgui.cpp optiscaler\OptiScaler\include\imgui\imgui_draw.cpp optiscaler\OptiScaler\include\imgui\imgui_tables.cpp optiscaler\OptiScaler\include\imgui\imgui_widgets.cpp optiscaler\OptiScaler\include\imgui\misc\freetype\imgui_freetype.cpp optiscaler\external\freetype\freetype.lib /Fe:test-run\mfg-ui.exe /Fo:test-run\
if errorlevel 1 exit /b 1
test-run\mfg-ui.exe
