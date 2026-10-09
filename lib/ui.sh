# shellcheck shell=bash
# Terminal output for s3seal: colours on a terminal only, and never when NO_COLOR
# is set. Output piped or redirected is plain text.

ui_color_on() { [[ -t 1 && -z "${NO_COLOR:-}" ]]; }

# ui_paint CODE TEXT: prints TEXT in the ANSI style CODE when colours are on.
ui_paint() {
  if ui_color_on; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

ui_title() { ui_paint '1' "$1"; printf '\n'; }

# ui_row BULLET_CODE NAME WIDTH HOST NOTE: one aligned line of an alias list.
ui_row() {
  ui_paint "$1" '●'; printf ' '
  ui_paint '1' "$(printf '%-*s' "$3" "$2")"
  printf '  %s  ' "$4"
  ui_paint '2' "$5"; printf '\n'
}

# ui_notice SYMBOL_CODE TITLE: a highlighted heading line.
ui_notice() {
  ui_paint "$1" "!"; printf ' '; ui_paint '1' "$2"; printf '\n'
}

# ui_hint TEXT: an indented line under a notice.
ui_hint() { printf '    %s\n' "$1"; }
