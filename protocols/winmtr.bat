@ECHO OFF
set string=%1

set string=%string:winmtr:=%
for /f "delims=? " %%a in (%string%) do set host=%%a
start c:\winmtr.exe %host%
exit

