#!/usr/bin/env bash

# dependency check
if ! command -v lsusb &>/dev/null; then
  echo "error: usbutils not installed (pacman -S usbutils)"
  exit 1
fi

# collect devices
devs=()
ids=()

while IFS= read -r line; do
  entry="${line#*ID }"

  id="${entry%% *}"
  name="${entry#* }"

  if [[ -n "$name" ]]; then
    devs+=("$name")
    ids+=("$id")
  fi
done <<< "$(lsusb)"

if [[ ${#devs[@]} -eq 0 ]]; then
  echo "error: no USB devices found"
  exit 1
fi

# terminal information
COLS=$(tput cols)
LINES=$(tput lines)

# terminal setup
setup() {
  tput smcup
  tput civis
  stty -echo
}

teardown() {
  tput cnorm
  tput rmcup
  stty echo
}

trap teardown EXIT INT TERM

# terminal styling

reset() {
  tput sgr0
}

bold() {
  tput bold
  printf '%s' "$1"
  tput sgr0
}

dim() {
  tput dim
  printf '%s' "$1"
  tput sgr0
}

reverse() {
  tput rev
  printf '%s' "$1"
  tput sgr0
}

# cursor + drawing helpers

at() {
  tput cup "$1" "$2"
}

cls() {
  tput clear
}

# box

draw_box() {
  local r=$1
  local c=$2
  local h=$3
  local w=$4

  # top
  at "$r" "$c"
  printf '╭'
  printf '─%.0s' $(seq 1 $((w - 2)))
  printf '╮'

  # sides
  for ((i=1; i<h-1; i++)); do
    at $((r + i)) "$c"
    printf '│'

    # empty interior
    printf '%*s' $((w - 2)) ''

    printf '│'
  done

  # bottom
  at $((r + h - 1)) "$c"
  printf '╰'
  printf '─%.0s' $(seq 1 $((w - 2)))
  printf '╯'
}

# sizing

max_len=0

for name in "${devs[@]}"; do
  (( ${#name} > max_len )) && max_len=${#name}
  done

# maximum visible items
max_items=$((LINES - 10))

(( max_items < 1 )) && max_items=1
(( ${#devs[@]} < max_items )) && max_items=${#devs[@]}

# box dimensions
box_w=$((max_len + 10))

(( box_w > COLS - 4 )) && box_w=$((COLS - 4))

box_h=$((max_items + 2))

# center box
box_row=$(( (LINES - box_h - 4) / 2 + 2 ))
box_col=$(( (COLS - box_w) / 2 ))

selected=0
scroll=0

# header

draw_header() {
  at 0 0

  tput bold

  printf ' ⬡  Xpad controller configure'
  printf '%*s' $((COLS - 31)) ''

  tput sgr0
}

# footer

draw_footer() {
  at $((LINES - 1)) 0

  local keys="  ↑↓ navigate   Enter configure   q quit"

  tput dim
  tput rev

  printf '%s' "$keys"
  printf '%*s' $((COLS - ${#keys})) ''

    tput sgr0
}

# device count

draw_count() {
  local label=" ${#devs[@]} devices connected "
    local col=$(( (COLS - ${#label}) / 2 ))

      at $((box_row - 1)) "$col"

      tput dim
      printf '%s' "$label"
      tput sgr0
}

# item list

draw_items() {
  # Total space inside the box.
  local inner_w=$((box_w - 2))

  for ((i=0; i<max_items; i++)); do

    local dev_idx=$((i + scroll))
    local row=$((box_row + 1 + i))
    local col=$((box_col + 1))

    at "$row" "$col"

    if [[ $dev_idx -eq $selected ]]; then

    # Selected item.
    # Reverse video uses the terminal's own colors.
    tput rev

    printf ' > %-*s' \
      "$((inner_w - 3))" \
      "${devs[$dev_idx]}"

    tput sgr0

  else

  # Normal item.
  printf '   %-*s' \
    "$((inner_w - 3))" \
    "${devs[$dev_idx]}"

    fi
  done
}

# scroll indicator

draw_scroll() {
  [[ ${#devs[@]} -le $max_items ]] && return

    local track_h=$((box_h - 2))

    local thumb_h=$((track_h * max_items / ${#devs[@]}))
      (( thumb_h < 1 )) && thumb_h=1

      local thumb_pos=$((track_h * scroll / ${#devs[@]}))

      # Put scrollbar INSIDE the right border.
      local scr_col=$((box_col + box_w - 2))

      for ((i=0; i<track_h; i++)); do

        at $((box_row + 1 + i)) "$scr_col"

        if (( i >= thumb_pos && i < thumb_pos + thumb_h )); then

          tput rev
          printf ' '
          tput sgr0

        else

          tput dim
          printf '│'
          tput sgr0

        fi
      done
}

# selected device details

draw_detail() {
  local detail_row=$((box_row + box_h + 1))

  at "$detail_row" "$box_col"

  local id="${ids[$selected]}"

  tput dim
  printf ' ID: %s' "$id"
  tput sgr0
}

# configure selected device
configure_device() {
  local id="${ids[$selected]}"
  local vendor="${id%:*}"
  local product="${id#*:}"

  teardown

  echo
  echo "Selected device:"
  echo "  ${devs[$selected]}"
  echo "  ID: $id"
  echo

  # Get a name for this controller.
  get_controller_name

  echo
  echo "Controller name: $CONTROLLER_NAME"
  echo
  echo "WARNING:"
  echo "Use a unique name for this controller."
  echo "An existing configuration with this name may be overwritten."
  echo

  read -rp "Continue? [y/N]: " answer

  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    read -rp "Press Enter to continue..."
    setup
    return
  fi

  # ----------------------------------------------------------
  # Load xpad
  # ----------------------------------------------------------

  echo
  echo "\$ sudo modprobe xpad"

  if ! sudo modprobe xpad; then
    echo
    echo "error: failed to load xpad"
    read -rp "Press Enter to continue..."
    setup
    return
  fi

  # ----------------------------------------------------------
  # Create udev rule
  # ----------------------------------------------------------

  local rule_file="/etc/udev/rules.d/90-xpad-${CONTROLLER_NAME}.rules"

  local rule
  rule="ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$vendor\", ATTR{idProduct}==\"$product\", RUN+=\"/bin/sh -c 'echo $vendor $product > /sys/bus/usb/drivers/xpad/new_id'\""

  echo
  echo "Creating udev rule:"
  echo "  $rule_file"
  echo
  echo "$rule"

  if ! printf '%s\n' "$rule" |
    sudo tee "$rule_file" >/dev/null
then
  echo
  echo "error: failed to create udev rule"
  read -rp "Press Enter to continue..."
  setup
  return
  fi

  # ----------------------------------------------------------
  # Reload udev
  # ----------------------------------------------------------

  echo
  echo "\$ sudo udevadm control --reload-rules"

  if ! sudo udevadm control --reload-rules; then
    echo
    echo "error: failed to reload udev rules"
    read -rp "Press Enter to continue..."
    setup
    return
  fi

  echo
  echo "Configuration completed."
  echo
  echo "Controller: $CONTROLLER_NAME"
  echo "Device:     ${devs[$selected]}"
  echo "USB ID:     $id"
  echo "Rule:       $rule_file"

  read -rp "Press Enter to continue..."

  setup
}

# main draw
draw() {
  draw_header
  draw_count
  draw_box "$box_row" "$box_col" "$box_h" "$box_w"
  draw_items
  draw_scroll
  draw_detail
  draw_footer
}

# input

read_key() {

  IFS= read -rsn1 key

  if [[ $key == $'\x1b' ]]; then
    read -rsn2 -t 0.1 seq
    key+="$seq"
  fi

  printf '%s' "$key"
}

# scrolling

scroll_to() {

  if (( selected < scroll )); then

    scroll=$selected

  elif (( selected >= scroll + max_items )); then

    scroll=$((selected - max_items + 1))

  fi
}

# main loop

setup

while true; do

  draw

  key=$(read_key)

  case $key in
    # up
    $'\x1b[A'|k)
    if (( selected > 0 )); then
      ((selected--))
      scroll_to
    fi
    ;;

    # down
    $'\x1b[B'|j)
    if (( selected < ${#devs[@]} - 1 )); then
      ((selected++))
      scroll_to
    fi
    ;;

    # page up
    $'\x1b[5~')
    ((selected -= max_items))
    (( selected < 0 )) && selected=0

    scroll_to
    ;;

    # page down
    $'\x1b[6~')
    ((selected += max_items))
    (( selected >= ${#devs[@]} )) &&
      selected=$(( ${#devs[@]} - 1 ))

        scroll_to
        ;;

    # go to top
    g)
    selected=0
    scroll=0
    ;;

    # go to bottom
    G)
    selected=$(( ${#devs[@]} - 1 ))
      scroll_to
      ;;

    # Enter
    '')
    configure_device
    ;;

    # quit
    q|Q)
    exit 0
    ;;

  esac

done
