@echo off
rem Builds zemu into .\build. Usage: build.bat [debug|release]
if not exist build mkdir build
if "%1"=="debug" (
	odin build src -out:build\zemu.exe -debug -vet -strict-style
) else (
	odin build src -out:build\zemu.exe -o:speed -vet -strict-style -subsystem:windows
)
if errorlevel 1 exit /b 1
rem SDL3.dll ships with Odin's vendor:sdl3 package.
for /f "delims=" %%i in ('odin root') do copy /y "%%i\vendor\sdl3\SDL3.dll" build\ >nul
