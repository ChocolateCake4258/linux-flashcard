# Проверки и границы приёмки

Сводка приёмки Debian-ветки на 22 октября 2026. Локальные диагностические отчёты,
идентификаторы устройств, персональные paths и артефакты хранятся отдельно.

## Подтверждено

- Windows 10 x64, AMD Ryzen 5, 16 GiB RAM; файловые запуски обычным пользователем.
- TCG и WHPX; persistent Linux image/VARS, повторные запуски и штатное выключение.
- Нативный x86-64 UEFI и общие файлы после смены режимов подтверждены пользователем.
- CLI/languages, IDE, PostgreSQL/SQLite, офис/математика, Docker и Wireshark:
  функциональные, persistence и GUI checks полного учебного набора.
- Исходный boot-to-Shell исправлен согласованными PCI paths и bootindex;
  shell-only exit0 сохраняется как ошибка загрузки.
- Реальная physical запись 32-ГБ USB с полным deferred body/boot-region read-back.
- Backup/restore stopped-комплекта с SHA, ZIP64, проверкой corruption и busy-image guards.
- Автономный RC6 capsule: независимая распаковка, Limited CHECK/Plan, полный новый
  десятиэтапный REBUILD с restricted guest network. 1439 package/version/status
  записей совпали с frozen factory base.
- RC6 seal: проверочные TXT на Desktop отсутствуют. Реальный consumer boot до
  обычного приглашения первого пароля, затем ACPI powerdown/exit0.

## Автоматическая проверка

Linux CI: source encodings/syntax, ShellCheck, Python state/recovery/packaging
tests и сборка/проверка Windows ZIP. Windows CI: PowerShell 5.1, file-backed writer,
USB coordinator, backup и native launcher contracts. Прямые native disk calls
изолированы fixtures; CI не является записью настоящего USB или GUI-приёмкой Linux.

## Оставшаяся аппаратная матрица

- Windows 11 и дополнительные Intel/AMD машины.
- Учебные ПК со стандартной учётной записью и различной готовностью WHPX.
- Контрольная физическая цепочка именно нового публичного RC: START из чистой
  распаковки → новая сборка → полная запись → пользовательская приёмка.

Полный RC6 replay проверен до image; после этого новая physical запись текущей
рабочей USB не выполнялась. Текущий рабочий носитель принят пользователем.
