# Разработка и подготовка релиза

Основной пользовательский сценарий: скачать `*-windows.zip`, распаковать,
подключить USB и открыть START.bat. Windows-фабрика создаёт и проверяет систему
до записи выбранного носителя. Архитектура: [docs/architecture.md](docs/architecture.md).

## Проверки исходников

Для разработки используйте Python 3.14, Bash, ShellCheck и Windows PowerShell 5.1.
Дополнительные Python packages для регрессионных тестов не требуются.

```sh
make check
make lint
```

На Windows запускайте каждый PS harness отдельным процессом: тесты изолируют
native types и состояние модулей. Точный список находится в
`.github/workflows/shellcheck.yml`. Эти тесты используют файловые fixtures;
настоящие носители и Linux VM для CI не нужны.

PowerShell-файлы: UTF-8 BOM/LF. BAT: ASCII/CRLF. Guest shell/Python/JSON: UTF-8/LF.
При изменении public payload обновляйте allowlist в `tools/make-public-download.py`.

## Локальная упаковка

```sh
make release OUTPUT=/tmp/linux-flashcard-release
```

Выходной каталог должен быть новым и находиться вне исходников. Упаковщик
проверяет полный manifest и dependency closure, создаёт ZIP и SHA256. Версия
берётся из VERSION. VM images, caches, персональные профили и журналы хранятся
вне Git. Подтверждённые версии входов — inputs.json/runtime.lock и fetch-inputs.py.

## Публикация

1. Обновить VERSION и CHANGELOG.md, выполнить проверки и просмотреть diff.
2. Сохранить изменения отдельным коммитом после проверки.
3. Создать и отправить тег `v<VERSION>`.
4. Workflow `Publish Windows download` повторит Linux/Windows CI, соберёт
   пользовательский ZIP и опубликует его вместе с SHA256.

RC-теги создают prerelease. Существующие releases не перезаписываются; для
изменённых файлов используется новая версия. Сам commit или push ветки без тега
запускает проверки, но не публикует release.

## Проверки оборудования

Результаты и границы приёмки: [docs/validation.md](docs/validation.md).
Новая физическая запись выполняется после явного выбора USB и подтверждения.
Для проверки только образа есть BUILD-IMAGE.bat. Обновление frozen inputs или
опубликованного результата выполняется в новом workspace.

Исходники проекта распространяются под MIT. Debian, QEMU, Ventoy и загружаемые
приложения сохраняют собственные лицензии.
