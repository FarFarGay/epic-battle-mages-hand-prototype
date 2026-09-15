@echo off
setlocal
set "GODOT=D:\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64.exe"
if not exist "%GODOT%" (
  echo Godot 4.7 was not found. Open project.godot with Godot 4.7 or newer.
  pause
  exit /b 1
)
start "Iron Citadel" "%GODOT%" --path "%~dp0"
