@echo off
REM Build the 32-bit MPR.dll proxy with Visual Studio 2008 (VC9).
REM Adjust the path below if VS2008 is installed elsewhere.
setlocal
set "VCBIN=%ProgramFiles(x86)%\Microsoft Visual Studio 9.0\VC\bin"
if not exist "%VCBIN%\vcvars32.bat" (
  echo VS2008 vcvars32.bat not found under "%ProgramFiles(x86)%\Microsoft Visual Studio 9.0"
  exit /b 1
)
call "%VCBIN%\vcvars32.bat" || exit /b 1
cl /nologo /W4 /O2 /MT /LD src\mpr_proxy.c /link /def:src\mpr_proxy.def /out:MPR.dll || exit /b 1
echo.
echo Built MPR.dll. Copy it into the ISE 9.2i installation's bin\nt directory.
