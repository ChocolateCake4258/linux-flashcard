# Сборка и продолжение

Обычный запуск из корня архива: `START.bat`. Полный выпуск файла-образа без
физической записи: `BUILD-IMAGE.bat`. Перед первым запуском выполните `CHECK.bat`.

## Рабочий каталог

По умолчанию используется `LinuxFlashcard-work` рядом с распакованным проектом,
на том же диске. Состояние выбора носителя — `last-build.json`, образной сборки —
`last-image-build.json`. Перенести место сборки можно явным `-Workspace`.

```bat
START.bat -Workspace E:\LinuxFlashcard-new
BUILD-IMAGE.bat -Workspace E:\LinuxFlashcard-image-new
```

Требуется локальный NTFS. Временные каталоги, portable Python, кэш, исходный snapshot,
runner и результаты находятся в выбранных рабочих каталогах. Переменные окружения
задаются только текущим процессам; настройки профиля Windows не изменяются.

## Этапы

`inputs → seed → images → provision → layout → assemble → direct1 → ventoy2 → direct3 → finalize`.

Входы проверяются по pinned hashes, QEMU — по фиксированному runtime lock.
Установка и функциональные/GUI проверки происходят внутри новой VM.
Следующие три запуска проверяют прямой режим, Ventoy и сохранение общих данных.
Пользовательский пароль в сборку не включается: он задаётся при первом входе.

По умолчанию используется compact storage: после проверки ISO убирается staging,
после assembly с SHA — standalone RAW/VARS. Финальный fixed VHD превращается в RAW
на месте с проверкой footer/GPT/SHA и сохранённым журналом восстановления. Пик для
32-ГБ USB около 65,4 GB; рекомендуется 70 GB. Кэш входов и receipts сохраняются.
`-KeepIntermediates` при создании workspace отключает уборку и оставляет прежнюю
двухфайловую конвертацию (около 100 GB). Storage policy фиксирована для workspace;
прежние workspace автоматически остаются в keep mode.

Итог: `artifacts/linux-flashcard-usb.img`, `.sha256`, `.sha256sum`, `build-result.json`.
USB-подготовка после этого выполняет запись и проверку чтением всех диапазонов.

## Возобновление и диагностика

Повторите кнопку или укажите прежний workspace. Исходный snapshot фиксирован;
`-NewBuild` создаёт новую сборку. Уже опубликованный образ не пересоздаётся молча.

После удаления standalone image обновление source snapshot через RefreshSources
отвергается: новые исходники требуют новой workspace. Обычный Resume продолжает
проверенную цепочку и не пересоздаёт уже изменявшуюся общую установку.

```bat
START.bat -Status
BUILD-IMAGE.bat -Status
BUILD-IMAGE.bat -NewBuild
win\build-debian.bat -Workspace E:\LinuxFlashcard-image-new -Resume
win\build-debian.bat -Workspace E:\LinuxFlashcard-image-new -Status
```

`factory-state.json` хранит завершённые этапы и текущий job; `jobs/<id>` содержит
stdout/stderr, serial и JSON receipts. Собственный runner продолжает работу после
закрытия окна. Для штатной остановки используйте:

```bat
win\build-debian.bat -Workspace E:\LinuxFlashcard-image-new -Stop
```

Ошибки записи не засчитываются как готовая USB. Смена номера Disk N допускается
только при совпадении path/serial/capacity. Готовый носитель повторно записывается
только с явным `START.bat -Rewrite` и подтверждением выбора.

## Если Windows не подготовила USB

Ошибка physical writer после `finalize` не требует повторной установки Linux:
проверенный образ остаётся в `artifacts`. Повторный запуск с тем же workspace
проверит его SHA и повторит только запись. В RC4 уже пустой носитель повторно не
очищается. Synthetic whole-device view после удаления GPT нормализуется только
при доказанно пустой таблице и отсутствии томов. Восстановление через native empty
GPT не создаёт файловых разделов; обе таблицы/CRC и identity проверяются до копирования.
