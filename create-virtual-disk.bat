@echo off
setlocal

:: Запрашиваем размер диска в ГБ, по умолчанию 25
set /p size="Enter disk size in GB (default 25): "
if "%size%"=="" set size=25

:: Выполняем команду создания диска
echo Creating disk virtual-disk.qcow2 with size %size%G...
/qemu/qemu-img.exe create -f qcow2 virtual-disk.qcow2 %size%G

:: Пауза, чтобы окно не закрылось сразу
pause