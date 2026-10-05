# Используемое ПО и версии

## Сборка ISO (Linux)

- **Kubuntu 24.04 LTS**: https://cdimage.ubuntu.com/kubuntu/releases/24.04/release/
  - актуальная версия задаётся в `config.sh` (`KUBUNTU_VERSION`), контрольные суммы берутся
    из `SHA256SUMS` того же каталога автоматически
- Утилиты сборки (`make prepare`): `xorriso`, `isolinux`, `syslinux-common`,
  `squashfs-tools`, `rsync`, `wget`, `curl`
- Примечание: старый путь `…/kubuntu/releases/24.04.3/…` тоже существовал, но
  канонический путь — `…/releases/24.04/release/…`

## Windows (флешка)

- **QEMU (portable)**: https://qemu.weilnetz.de/w64/
  - скрипты ищут его в папке `qemu\` рядом с `win\`, либо в `%LOCALAPPDATA%\qemu` /
    Program Files / PATH. Установка не требуется — просто распаковать.
  - если QEMU нет, `build-all.bat` (стадия 1) сам определяет последнюю сборку
    в каталоге weilnetz (имя файла содержит дату и меняется с релизом), качает
    установщик и сверяет SHA-512 по файлу `.sha512`. Адрес можно задать вручную:
    `build-all.bat -QemuUrl https://qemu.weilnetz.de/w64/qemu-w64-setup-XXXXXXXX.exe`.
- **Win32 Disk Imager** (альтернативная запись RAW):
  https://win32diskimager.org/
- Встроенные скрипты `write-image.bat` выполняют запись напрямую —
  сторонние утилиты не нужны.

## Способ B — флешка «два тома» (`win\build-all.bat`)

- Установочный образ: **Ubuntu live-server** (автоматизация через autoinstall)
  https://releases.ubuntu.com/26.04/ (`ubuntu-26.04-live-server-amd64.iso`,
  SHA256 из `SHA256SUMS`). Версия/URL — константы в `win\build-all.ps1`.
- Разметка задаётся в `win\autoinstall.yaml` (GPT: 1M bios-boot + FAT32 ESP
  «FLASHCARD» 2 GiB + ext4 «/» ~26 GiB в новых заводских образах на 28 GiB;
  `DiskSizeGb=28` сохраняется для совместимости с обычными флешками на 32 GB).
- После сборки на ПК остаются артефакты `virtual-disk.img` (raw) и
  `virtual-disk.qcow2` — для клонирования и файлового режима `run-from-usb`.

### Почему стадия 5 запускает ядро вручную

`autoinstall` обязан попасть в **командную строку ядра**. Если загрузить ISO
штатным GRUB, параметра там нет, и инсталлятор показывает экран подтверждения
разметки диска: в окне это видно, в скрытом режиме — тишина навсегда
(в `autoinstall.yaml` раньше был бесполезный `bootcmd` с `sed` по
`/proc/cmdline`: `bootcmd` выполняется слишком поздно).

Поэтому `win\build-all.ps1` (стадия 5):

1. монтирует ISO (`Get-PfIsoBootFiles` в `win\lib\pf-tools.psm1`) и копирует
   `casper/vmlinuz` и `casper/initrd.img` в `.cache\boot\` (кеш переиспользуется);
2. отдаёт QEMU `-kernel`, `-initrd`, `-append "autoinstall ds=nocloud …"`,
   оставляя ISO подключённым cdrom — оттуда initrd берёт live-систему;
3. пишет последовательную консоль в `install.log` и следит за ВМ через QMP
   (`query-status`, `query-blockstats`), поэтому видно и запись на диск, и что
   установка идёт, даже когда гость молчит.

Та же схема с `console=ttyS0` прописана в GRUB устанавливаемой системы —
без неё стадия 6 (пробная загрузка) не смогла бы ничего проверить.

### Две тонкости конфигурации

- **Диск.** К QEMU он подключён как `if=virtio`, то есть в гостевой системе это
  `/dev/vda`, а не `/dev/sda`. Поэтому в `autoinstall.yaml` указан
  `match: {size: largest}`, а не путь: cdrom-образы в кандидаты не попадают, а
  имя устройства может измениться вместе с настройками хоста.
- **Сеть.** Интерфейс не фиксируется по имени (`match: {name: "en*"}` +
  DHCP): один и тот же конфиг работает и в QEMU (virtio), и на реальном ноутбуке
  при нативной загрузке с флешки.

## Внутри образа (устанавливается скриптами)

- При сборке флешки ставятся рабочий стол и базовые инструменты
  (`packages:` в `win\autoinstall.yaml`).
- Тяжёлый стек (docker, golang, rust, node.js, jupyter, libreoffice, postgresql,
  VS Code, PyCharm) ставится при **первом запуске** готовой системы службой
  `first-boot-setup.service` — сборка не срывается из-за обрыва сети.
  Лог: `/var/log/first-boot-setup.log`.
- VS Code, PyCharm, Wireshark, GeoGebra — snap-пакеты, ставятся на первом
  запуске (скрипт `first-boot-setup.sh`).
- Firefox — deb из PPA `mozillateam/ppa`, чтобы не тянуть snap.
- Остальное — штатные репозитории Ubuntu (см. `packages.list` — он же используется
  способом A). Способ A дополнительно ставит VS Code и .NET SDK 8.0 из
  `packages.microsoft.com` с проверкой подписи (`install-chroot.sh`); в способе B
  .NET не ставится — если он нужен, добавьте его в `first-boot-setup.sh`
  (`sudo snap install dotnet-sdk --classic`).
