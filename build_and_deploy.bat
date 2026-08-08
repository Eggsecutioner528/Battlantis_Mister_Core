@echo off
setlocal

:: ==========================================
:: MiSTer FPGA Build & Deploy Script
:: ==========================================
set MISTER_IP=10.0.0.47
echo [0] Targeted MiSTer at %MISTER_IP%

set MISTER_USER=root
set MISTER_PASS=1

set PROJECT_NAME=Template
set MRA_FILE=Battlantis.mra

set SSH_OPTS=-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL
set SCP_OPTS=-O %SSH_OPTS%

echo [1] Compiling %PROJECT_NAME% core...
:: Use the absolute path provided to Quartus
"J:\Intel Quartus\17.0\quartus\bin64\quartus_sh.exe" --flow compile %PROJECT_NAME%
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Quartus compilation failed!
    exit /b %ERRORLEVEL%
)

echo [2] Compilation successful. Deploying to MiSTer at %MISTER_IP%...

:: Since FTP is not installed on the MiSTer, we will strictly use SCP.
echo Uploading .rbf core (Password is '1')...
rundll32 user32.dll,MessageBeep
:: Rename it locally first to guarantee SCP uses the correct name
copy /Y "output_files\%PROJECT_NAME%.rbf" "output_files\Battlantis.rbf" >nul
scp %SCP_OPTS% "output_files\Battlantis.rbf" %MISTER_USER%@%MISTER_IP%:/media/fat/_Arcade/cores/

echo Uploading .mra file (Password is '1')...
rundll32 user32.dll,MessageBeep
scp %SCP_OPTS% "%MRA_FILE%" %MISTER_USER%@%MISTER_IP%:/media/fat/_Arcade/Battlantis.mra

echo [3] Deployment complete! Starting Battlantis on MiSTer (Password is '1')...
rundll32 user32.dll,MessageBeep
ssh %SSH_OPTS% %MISTER_USER%@%MISTER_IP% "echo 'load_core /media/fat/_Arcade/Battlantis.mra' > /dev/MiSTer_cmd"

echo [4] Done!
pause
