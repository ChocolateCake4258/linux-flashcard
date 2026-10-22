# Архитектура LinuxFlashcard

## Одна система и общие данные

Большой NTFS-раздел USB содержит фиксированный 26-GiB `linux.img.vtoy`, portable
QEMU и кнопки запуска. Маленький FAT-раздел содержит EFI Ventoy. Нативный
x86-64 UEFI/Ventoy/vtoyboot и файловый QEMU открывают одну Linux-систему.
Между режимами требуется штатное выключение Linux.

Windows-запуск обычным пользователем: TCG либо явно выбранный WHPX; постоянный
VARS и launch.lock общие. Root PCI4/net PCI3 и bootindex совпадают с фабрикой.
Профиль видео — VGA 1024×768/60, GTK gl=off; RTC localtime.

## Автоматическая подготовка

`START.bat → win/build-all.ps1` выбирает USB по модели/serial/capacity,
подтверждает стирание и создаёт отдельный workspace. Фабрика проходит:

```text
inputs → seed → images → provision → layout → assemble → direct1 → ventoy2 → direct3 → finalize
```

Гость создаётся из проверенного Debian 13 generic image. Программы и GUI
проверяются в VM, три маршрута подтверждают общий root и persistence. Student
остаётся locked до первого пользовательского запуска и установки пароля.

Фабрика работает с собственными file-backed дисками. Physical writer вызывается
после завершения сборки и повторной проверки identity выбранного USB. Тело диска
полностью проверяется до публикации GPT/boot regions; итог ready требует receipt
полной записи и проверки, а не только успешного выхода процесса.

## Продолжение и хранение

Sources snapshot, pins, capacity, storage policy, job ownership и receipts
сохраняются в workspace. Atomic JSON и locks защищают продолжение. Background
jobs принадлежат конкретному build/job и переживают закрытие coordinator.

Compact mode удаляет intermediates после проверки successor. Fixed VHD
превращается в RAW на месте после footer/GPT/SHA checks с recovery journal.
Пик для типового 32-ГБ USB: 26 GiB + capacity + 6 GiB; рекомендуется 70 GB.

Process-local TEMP/profile/cache находятся в рабочих каталогах. Python и QEMU
подготовляются автоматически; пользовательская Windows-конфигурация профиля
постоянно не меняется.

## Два вида архивов

Пользовательский `*-windows.zip` содержит установочные скрипты и скачивает
проверенные входы при подготовке. Основная кнопка — START.bat.

Автономный pipeline capsule содержит также cached inputs и clean prepared base
с закреплёнными package/container versions. Он создаёт новый build ID и повторяет
проверки с restricted network. Его START также готовит USB, а REBUILD выпускает
только image. Подробности: [pipeline-capsule.md](pipeline-capsule.md).
