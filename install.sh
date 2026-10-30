#!/usr/bin/env bash
set -Eeuo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

valid_size() { [[ $1 =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]]; }

detect_size() {
    local detected=
    # Prefer niri's physical mode: Xwayland may report a scaled logical size.
    if command -v niri >/dev/null && command -v python3 >/dev/null; then
        detected=$(niri msg --json focused-output 2>/dev/null | python3 -c '
import json, sys
try:
    output = json.load(sys.stdin)
    mode = output["modes"][output["current_mode"]]
    width, height = mode["width"], mode["height"]
    transform = output.get("logical", {}).get("transform", "Normal")
    if transform in ("90", "270", "Flipped90", "Flipped270"):
        width, height = height, width
    print(f"{width}x{height}")
except (ValueError, KeyError, TypeError, IndexError, AttributeError):
    sys.exit(1)
' 2>/dev/null) || detected=
        if valid_size "$detected"; then
            printf '%s\n' "$detected"
            return
        fi
    fi

    # On X11, choose the primary active output, or the first active output.
    if command -v xrandr >/dev/null; then
        detected=$(xrandr --query 2>/dev/null | awk '
            $2 == "connected" {
                primary = ($3 == "primary")
                for (i = 3; i <= NF; i++) {
                    if ($i ~ /^[0-9]+x[0-9]+[+-][0-9]+[+-][0-9]+$/) {
                        size = $i
                        sub(/[+-].*$/, "", size)
                        if (!first) first = size
                        if (primary) preferred = size
                        break
                    }
                }
            }
            END { if (preferred) print preferred; else if (first) print first }
        ') || detected=
        if valid_size "$detected"; then
            printf '%s\n' "$detected"
            return
        fi
    fi
    return 1
}

if screen_size=$(detect_size); then
    printf 'Определено разрешение монитора: %s\n' "$screen_size"
else
    screen_size=1920x1080
    printf 'Монитор не определён. Используется стандартное разрешение: %s\n' "$screen_size"
fi
config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/oes-babl
mkdir -p "$config_dir"
printf '%s\n' "$screen_size" > "$config_dir/screen-size"
printf 'Размер сохранён: %s/screen-size\n' "$config_dir"

install -Dm755 "$source_dir/oes-babl" "$HOME/.local/bin/oes-babl"
printf 'Установлено: %s/.local/bin/oes-babl\n' "$HOME"

install -Dm644 "$source_dir/bash/oes-babl.bash" "$config_dir/oes-babl.bash"
bash_source_line='[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/oes-babl/oes-babl.bash" ] || . "${XDG_CONFIG_HOME:-$HOME/.config}/oes-babl/oes-babl.bash"'
if ! grep -Fqx -- "$bash_source_line" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# oes-babl\n%s\n' "$bash_source_line" >> "$HOME/.bashrc"
fi
printf '%s\n' 'Команда oes-babl добавлена в Bash. Откройте новый терминал или выполните: source ~/.bashrc'

if command -v fish >/dev/null; then
    fish_config=${XDG_CONFIG_HOME:-$HOME/.config}/fish
    install -Dm644 "$source_dir/fish/oes-babl.fish" "$fish_config/functions/oes-babl.fish"
    printf '%s\n' 'Команда oes-babl доступна в fish без перезапуска терминала.'
else
    printf '%s\n' 'Для запуска используйте ~/.local/bin/oes-babl или добавьте ~/.local/bin в PATH.'
fi
