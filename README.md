# oes-babl

Запускает отдельный экран Xephyr на весь монитор и Google Chrome с существующим профилем внутри него. Chrome разворачивается как обычное окно: вкладки и адресная строка остаются видимыми.

По умолчанию открывается <https://lms.astanait.edu.kz>. Размер виртуального экрана — 1920×1200.

## Требования

- Linux, Bash и Google Chrome (`google-chrome-stable` или `google-chrome`).
- Xephyr, Openbox, xauth, xprop, mcookie и flock.
- В Wayland-сессии нужен работающий Xwayland и переменная `DISPLAY`. В niri это обычно обеспечивает `xwayland-satellite`.
- Fish необязателен. Windows и macOS не поддерживаются.

В Arch Linux зависимости устанавливаются так:

```bash
sudo pacman -S --needed xorg-server-xephyr openbox xorg-xauth xorg-xprop util-linux
```

Google Chrome устанавливается отдельно.

## Установка

```bash
git clone https://github.com/itisabyl/oes-babl.git
cd oes-babl
./install.sh
```

Установщик копирует скрипт в `~/.local/bin/oes-babl`. Если установлен fish, он также добавляет функцию `oes-babl` в каталог функций fish. При повторной установке эти два файла обновляются.

## Запуск

Сначала сохраните работу и полностью выйдите из обычного Chrome через **⋮ → Выход**. Один каталог профилей нельзя одновременно использовать в двух экземплярах браузера. Если Chrome продолжает работать в фоне, скрипт попросит завершить его.

В fish:

```fish
oes-babl
```

В других оболочках, если `~/.local/bin` отсутствует в `PATH`:

```bash
~/.local/bin/oes-babl
```

Открыть другой сайт:

```bash
oes-babl https://example.com
```

Изменить размер экрана:

```bash
OES_BABL_SIZE=1920x1080 oes-babl
```

Выбрать конкретный профиль Chrome:

```bash
CHROME_PROFILE="Profile 1" oes-babl
```

Имя каталога профиля можно посмотреть в поле **Profile Path** на странице `chrome://version`: например, `Default` или `Profile 1`.

Скрипт использует обычный каталог данных Chrome, учитывая `CHROME_USER_DATA_DIR`, `CHROME_CONFIG_HOME` и `XDG_CONFIG_HOME`. Профили, cookies и пароли остаются на вашем компьютере. Не добавляйте каталог профиля в репозиторий.

## Запись экрана и завершение

Открывайте сайт записи внутри Chrome, запущенного через `oes-babl`. При выборе «Весь экран» проверяйте предпросмотр: он должен показывать экран Xephyr. Выбор источника зависит от версии Chrome и механизма захвата; скрипт не создаёт дополнительный выход монитора в niri.

Закройте Chrome, чтобы завершить процесс и закрыть виртуальный экран. Если включена фоновая работа Chrome, полностью завершите браузер через его меню. При прерывании скрипта он отправляет запущенному Chrome сигнал завершения, затем закрывает Openbox и Xephyr.

Если Xephyr перехватил мышь и клавиатуру, сочетание **Ctrl+Shift** обычно освобождает их.

Временные файлы авторизации удаляются при завершении. Xephyr не слушает TCP и использует отдельный cookie X11.

## Проверка синтаксиса

```bash
bash -n oes-babl install.sh
fish -n fish/oes-babl.fish
./oes-babl --help
```
