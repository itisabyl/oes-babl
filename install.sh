#!/usr/bin/env bash
set -Eeuo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -Dm755 "$source_dir/oes-babl" "$HOME/.local/bin/oes-babl"
printf 'Установлено: %s/.local/bin/oes-babl\n' "$HOME"

if command -v fish >/dev/null; then
    fish_config=${XDG_CONFIG_HOME:-$HOME/.config}/fish
    install -Dm644 "$source_dir/fish/oes-babl.fish" "$fish_config/functions/oes-babl.fish"
    printf '%s\n' 'Команда oes-babl доступна в fish без перезапуска терминала.'
else
    printf '%s\n' 'Для запуска используйте ~/.local/bin/oes-babl или добавьте ~/.local/bin в PATH.'
fi
