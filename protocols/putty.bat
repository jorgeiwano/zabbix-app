@ECHO OFF
set string=%1
set user=%2
set pass=%3

set string=%string:putty:=%
for /f "delims=? " %%a in (%string%) do set host=%%a
start c:\putty.exe -ssh %user%@%host% -pw %pass%
exit

