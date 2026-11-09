@echo off
rem Stream E900V22C partitions to PC via adb exec-out (binary-safe cmd redirection).
rem Prereq: adb.exe in PATH, box ADB connected and rooted (see README step 2).
rem Usage: edit DEV below to your box IP, run from an empty target folder.
rem NOTE: the trailing "2>/dev/null" on every dd is REQUIRED - adb exec-out
rem       mixes dd stderr statistics (~91 bytes) into the binary stream otherwise.
setlocal
set ADB=adb
set DEV=192.168.1.100:5555
set OUT=%~dp0backup
if not exist "%OUT%" mkdir "%OUT%"

rem --- small partitions: raw images ---
for %%p in (bootloader boot recovery dtbo vbmeta logo env misc cri_data skparam skmac param) do (
  echo [%time%] Backing up %%p raw ...
  "%ADB%" -s %DEV% exec-out "dd if=/dev/block/%%p bs=1048576 2>/dev/null" > "%OUT%\%%p.img"
  if errorlevel 1 echo ERROR on %%p
)

rem --- large partitions: gzip compressed on box ---
for %%p in (system vendor ctc skbackup) do (
  echo [%time%] Backing up %%p gzip ...
  "%ADB%" -s %DEV% exec-out "dd if=/dev/block/%%p bs=1048576 2>/dev/null | gzip -4" > "%OUT%\%%p.img.gz"
  if errorlevel 1 echo ERROR on %%p
)

echo [%time%] ALL DONE - verify sizes with: adb -s %DEV% shell blockdev --getsize64 /dev/block/NAME
dir "%OUT%"
