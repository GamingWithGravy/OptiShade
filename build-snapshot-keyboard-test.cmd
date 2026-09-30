@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
python tests\snapshot-keyboard.py
if errorlevel 1 exit /b 1
cl /nologo /std:c++20 /EHsc /W3 /DUNICODE /D_UNICODE /DIMGUI_ENABLE_TEST_ENGINE /I optiscaler\external\freetype test-run\snapshot-keyboard.cpp optiscaler\OptiScaler\include\imgui\imgui.cpp optiscaler\OptiScaler\include\imgui\imgui_draw.cpp optiscaler\OptiScaler\include\imgui\imgui_tables.cpp optiscaler\OptiScaler\include\imgui\imgui_widgets.cpp optiscaler\OptiScaler\include\imgui\misc\freetype\imgui_freetype.cpp optiscaler\external\freetype\freetype.lib user32.lib /Fe:test-run\snapshot-keyboard.exe /Fo:test-run\
if errorlevel 1 exit /b 1
test-run\snapshot-keyboard.exe
exit /b %errorlevel%
