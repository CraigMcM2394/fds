@echo off

Rem Batch file used to build a 32 bit version of FDS

set envfile=%homedrive%\%homepath%\fds_smv_env.bat
IF EXIST %envfile% GOTO endif_envexist
echo ***Fatal error.  The environment setup file %envfile% does not exist. 
echo Create a file named %envfile% and use SMV_5/scripts/fds_smv_env_template.bat
echo as an example.
echo.
echo Aborting now...
pause>NUL
goto:eof

:endif_envexist

Rem location of batch files used to set up Intel compilation environment

call %envfile%

set target=intel_linux_64
set scriptdir=%linux_svn_root%/Utilities/Scripts


set fdsdir=%linux_svn_root%/Utilities/Makefile/Intel_Linux_64
plink %svn_logon% %scriptdir%/MAKE_fds_onhost.csh %target% %fdsdir% fire79 clean

set fdsdir=%linux_svn_root%/Utilities/Makefile/Mpi_Intel_Linux_64
plink %svn_logon% %scriptdir%/MAKE_fds_onhost.csh %target% %fdsdir% fire79 clean

pause