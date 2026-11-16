#!/bin/bash
# This script contains common functions for Regolith session management

# Settings come in layers, from the weakest to the strongest: the shipped
# defaults (/etc/regolith and the looks in /usr/share/regolith-look), the
# administrator directories <dir>/regolith3 of XDG_CONFIG_DIRS, and the user's
# directory, $XDG_CONFIG_HOME/regolith3 or ~/.config/regolith3.

# The user's directory. XDG_CONFIG_HOME counts only when it is absolute.
if [[ "${XDG_CONFIG_HOME-}" == /* ]]; then
    USER_CONFIG_DIR="${XDG_CONFIG_HOME%/}/regolith3"
else
    USER_CONFIG_DIR="$HOME/.config/regolith3"
fi

# The administrator directories, the most important first: <dir>/regolith3 for
# every absolute entry of XDG_CONFIG_DIRS, each once, at its first position.
# Without XDG_CONFIG_DIRS (unset or empty) that is /etc/xdg/regolith3.
SYSTEM_CONFIG_DIRS=()
resolve_system_config_dirs() {
    local entry dir seen
    local -a entries=()
    SYSTEM_CONFIG_DIRS=()
    IFS=: read -r -a entries <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
    for entry in "${entries[@]}"; do
        [[ "$entry" == /* ]] || continue
        dir="${entry%/}/regolith3"
        for seen in "${SYSTEM_CONFIG_DIRS[@]}"; do
            [ "$seen" != "$dir" ] || continue 2
        done
        SYSTEM_CONFIG_DIRS+=("$dir")
    done
}
resolve_system_config_dirs

# A settings file counts only when it is a readable ordinary file, or a link
# to one. Anything else in its place (a directory, a FIFO, a broken link, a
# file the user cannot read) is taken as absent, without a message.
is_settings_file() {
    [ -f "$1" ] && [ -r "$1" ]
}

# File Locations - Optional User Overrides
USER_XRESOURCE_OVERRIDE_FILE="$USER_CONFIG_DIR/Xresources"
USER_XRESOURCE_SEARCH_PATH="$USER_CONFIG_DIR/Xresources.d"

# File Locations - System Defaults
DEFAULT_XRESOURCE_LOOK_PATH="/usr/share/regolith-look/default"

# The window manager configurations, when no layer has its own (see
# resolve_wm_config_file)
DEFAULT_SYS_I3_CONFIG_FILE="/etc/regolith/i3/config"
DEFAULT_SYS_SWAY_CONFIG_FILE="/etc/regolith/sway/config"

# File Locations - Baseline
BASELINE_XRESOURCE_FILE="$HOME/.Xresources"

# The directories a quoted #include falls back to, after the directory of the
# including file, and the only ones an angle-bracket #include is looked for
# in: the user's Xresources.d, then the administrators', the most important
# first
XRES_INCLUDE_DIRS=("$USER_XRESOURCE_SEARCH_PATH")
for _dir in "${SYSTEM_CONFIG_DIRS[@]}"; do
    XRES_INCLUDE_DIRS+=("$_dir/Xresources.d")
done
unset _dir

# Regolith Look directories
DEFAULT_LOOK_ROOT="/usr/share/regolith-look"
USER_LOOK_ROOT="$USER_CONFIG_DIR/looks"

# The look is applied at the first login only; this directory records it
UPDATE_FLAG_DIR="$USER_CONFIG_DIR/flags"

# File location - user scripts. regolith-post-logout.service runs the script
# from this path in a systemd-managed session.
USER_POST_LOGOUT_SCRIPT_FILE="$HOME/.config/regolith3/logout"

# File location - text scaling factor set from the user's Xft.dpi
XFT_DPI_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/regolith/xft-dpi-text-scaling-factor"

DEFAULT_SESSION_TYPE="i3"

# Preprocessor for Xresources files; keeps non-ASCII values as they are
XRES_CPP="/usr/lib/regolith/regolith-xres-cpp"

# Set the default resource getter
RESOURCE_GETTER="xrescat"
if [ "${XDG_SESSION_TYPE-}" == "wayland" ]; then
	RESOURCE_GETTER="trawlcat"
fi

# Add the variables set in environment.d to the environment of a session that
# gnome-session runs itself (--builtin), as systemd gives them to the services
# of a systemd-managed session. Variables of the login environment win, as in
# that session, where gnome-session imports them into the user manager.
# Ubuntu and Debian link /etc/environment into environment.d, so the PATH
# Ubuntu sets there would otherwise replace the PATH that ~/.profile set.
import_environment_d() {
    local generator=/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
    local line name
    [ -x "$generator" ] || return 0
    while IFS= read -r line; do
        name=${line%%=*}
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # The generator quotes values for the shell, as in VAR="a b"
        if [ -z "${!name+set}" ]; then
            eval "export -- $line"
        fi
    done < <("$generator")
}

# Drop the IPC socket variables of an earlier session. The sway session puts
# SWAYSOCK and I3SOCK into the systemd user environment, and the user manager
# outlives a logout while the user has another session (ssh, lingering, a
# quick new login), so the next session's services and window manager inherit
# them. i3 takes I3SOCK as the path for its own IPC socket, so it would listen
# on the dead sway socket's path, and a stale SWAYSOCK makes tools believe
# they run under sway. The window managers set the variables they need.
clear_wm_sockets() {
    unset I3SOCK SWAYSOCK
    systemctl --user unset-environment I3SOCK SWAYSOCK 2>/dev/null || :
}

# Sets WM_CONFIG_FILE to the configuration of a window manager: the first
# settings file of <user directory>/<wm>/config and <administrator
# directory>/<wm>/config, the most important first, or the shipped one
resolve_wm_config_file() { # resolve_wm_config_file <i3|sway> <shipped config>
    local dir
    for dir in "$USER_CONFIG_DIR" "${SYSTEM_CONFIG_DIRS[@]}"; do
        if is_settings_file "$dir/$1/config"; then
            WM_CONFIG_FILE="$dir/$1/config"
            return 0
        fi
    done
    WM_CONFIG_FILE="$2"
}

# Determine where the default i3 and sway config files are
# Sets I3_CONFIG_FILE and SWAY_CONFIG_FILE
resolve_default_config_file() {
    resolve_wm_config_file i3 "$DEFAULT_SYS_I3_CONFIG_FILE"
    I3_CONFIG_FILE="$WM_CONFIG_FILE"
    resolve_wm_config_file sway "$DEFAULT_SYS_SWAY_CONFIG_FILE"
    SWAY_CONFIG_FILE="$WM_CONFIG_FILE"
}

# The running window manager keeps the configuration file it started with
# (i3 restarts and sway reloads with the same path): a file created since then
# in a stronger layer takes effect at the next start. Fails when the window
# manager reports a configuration file that is no longer there: restarting i3
# with it would end the session, and sway would refuse to reload. Succeeds
# when the window manager can't be asked.
wm_config_present() {
    local ipc=i3-msg raw=() file
    if [[ ${XDG_SESSION_TYPE-} == "wayland" ]]; then
        ipc=swaymsg
        raw=(-r) # JSON, as i3-msg prints it
    fi
    # The path, unescaped from the JSON reply
    file=$("$ipc" "${raw[@]}" -t get_version 2>/dev/null \
        | sed -n 's/.*"loaded_config_file_name": *"\(\([^"\\]\|\\.\)*\)".*/\1/p' \
        | sed 's/\\\(.\)/\1/g') || return 0
    [ -z "$file" ] || is_settings_file "$file"
}

# Print the settings files <dir>/<name> of the administrator directories,
# the weakest first, and of the user's directory, one per line
layer_settings_files() { # layer_settings_files <name>
    local i file
    for (( i = ${#SYSTEM_CONFIG_DIRS[@]} - 1; i >= 0; i-- )); do
        file="${SYSTEM_CONFIG_DIRS[i]}/$1"
        if is_settings_file "$file"; then
            printf '%s\n' "$file"
        fi
    done
    file="$USER_CONFIG_DIR/$1"
    if is_settings_file "$file"; then
        printf '%s\n' "$file"
    fi
}

# The Xresources files of the administrators, the weakest first, and the user's
resolve_layer_xres_files() {
    mapfile -t LAYER_XRESOURCE_FILES < <(layer_settings_files Xresources)
}

# Print the files the display manager merges, in its order: the readable
# ordinary files in /etc/X11/Xresources named with letters, digits, '_'
# and '-' only
system_xres_files() {
    local sysresources=/etc/X11/Xresources LC_ALL=C file name
    for file in "$sysresources"/*; do
        name=${file##*/}
        case $name in
            *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) continue ;;
        esac
        if [ -r "$file" ] && [ -f "$file" ]; then
            printf '%s\n' "$file"
        fi
    done
}

# Print an Xresources file preprocessed, or fail when it does not preprocess:
# an include that cannot be found or read, or includes that chase each other
# in a circle. A quoted #include is looked up next to the including file
# first, then in XRES_INCLUDE_DIRS, and an angle-bracket one only there. The
# file and the directories are passed as arguments: xrdb and trawld would
# hand them to the preprocessor on a command line split at spaces.
preprocess_xres_file() { # preprocess_xres_file <file> [<cpp option>...]
    local file=$1 dir include_args=()
    shift
    for dir in "${XRES_INCLUDE_DIRS[@]}"; do
        include_args+=(-I "$dir")
    done
    "$XRES_CPP" -P -nostdinc "${include_args[@]}" "$@" "$file"
}

# Sets XRDB_SYMBOLS to the symbols xrdb defines for the preprocessor
# (SERVERHOST, WIDTH, COLOR and so on), as xrdb passes them: without the
# shell quotes 'xrdb -symbols' prints around some values
xrdb_symbols() {
    local symbol
    XRDB_SYMBOLS=()
    while IFS= read -r symbol; do
        if [[ "$symbol" =~ ^(-D[^=]+=)\"(.*)\"$ ]]; then
            symbol="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        fi
        XRDB_SYMBOLS+=("$symbol")
    done < <(xrdb -symbols 2>/dev/null)
}

# Preprocess and merge Xresources files into the X resources. xrdb merges
# whatever the preprocessor printed before it failed, so preprocess here,
# with xrdb's symbols, and merge a file only when all of it preprocessed.
xrdb_merge_files() { # xrdb_merge_files <file>...
    local file resources
    xrdb_symbols
    for file in "$@"; do
        if resources=$(preprocess_xres_file "$file" "${XRDB_SYMBOLS[@]}"); then
            printf '%s\n' "$resources" | xrdb -nocpp -merge
        fi
    done
}

# Preprocess and merge Xresources files into trawl. trawld would run the
# preprocessor itself, in its own environment: preprocess here instead and
# merge the result as it is. trawld reads the result by its path, from the
# session's runtime directory, as trawl_sway_cleanup does.
trawl_merge_files() { # trawl_merge_files <file>...
    local file out="$XDG_RUNTIME_DIR/trawl_merge.$$.tmp"
    : > "$out"
    for file in "$@"; do
        # A file that does not preprocess is not merged at all
        if preprocess_xres_file "$file" > "$out.part"; then
            cat "$out.part" >> "$out"
        fi
    done
    trawldb --nocpp --merge "$out"
    rm -f "$out" "$out.part"
}

# Load default Xresources
load_standard_xres() {
    if is_settings_file "$BASELINE_XRESOURCE_FILE"; then
        xrdb_merge_files "$BASELINE_XRESOURCE_FILE"
    fi
}

# Load default Xresources
load_standard_trawlres() {
    if is_settings_file "$BASELINE_XRESOURCE_FILE"; then
        trawl_merge_files "$BASELINE_XRESOURCE_FILE"
    fi
}

# Print NAME=VALUE, each ending with a NUL, for the session environment files
# <wm>/env of the administrators, the weakest first, then of the user. A line
# holds NAME=VALUE, NAME a shell identifier; empty lines, lines starting with
# '#' or ';' and any other line are skipped. A value of two or more
# characters that opens and closes with the same single or double quote, and
# holds no other one of that mark, sheds those two marks; any other value,
# such as 'a' 'b', stays as written. Nothing is expanded or run.
session_environment() { # session_environment <i3|sway>
    local file line name value quote inner
    while IFS= read -r file; do
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                '' | '#'* | ';'*) continue ;;
                *=*) ;;
                *) continue ;;
            esac
            name=${line%%=*}
            value=${line#*=}
            [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            if [ "${#value}" -ge 2 ]; then
                quote=${value:0:1}
                inner=${value:1:${#value}-2}
                if [[ ( "$quote" == \" || "$quote" == \' ) &&
                      "${value: -1}" == "$quote" && "$inner" != *"$quote"* ]]; then
                    value=$inner
                fi
            fi
            printf '%s=%s\0' "$name" "$value"
        done < "$file"
    done < <(layer_settings_files "$1/env")
}

# Export the session environment files' variables, so that they reach the
# window manager and everything it starts. Later files win, and all of them
# win over the environment the session started with.
load_session_environment() { # load_session_environment <i3|sway>
    local assignment
    local -a assignments=()
    mapfile -d '' -t assignments < <(session_environment "$1" 2>/dev/null)
    for assignment in "${assignments[@]}"; do
        # A name the shell will not export (a read-only one such as UID) is
        # passed over: exporting it would end this script, so try it in a
        # subshell first. The argument is NAME=VALUE.
        # shellcheck disable=SC2163
        if (export -- "$assignment") 2>/dev/null; then
            export -- "$assignment"
        fi
    done
}

# Change the quotes in workspace names from double to to single.
# Due to a limitation of the preprocessor they have double quotes.
# The i3-wm workspace command fails with double quotes in the name
# grep exits 1 when no workspace names are defined; callers run with
# "set -e -o pipefail", so that must not end the script (it once stopped
# the X11 login before i3 started, which is why the call was removed then).
xres_i3_cleanup() {
    xrdb -query | { grep wm.workspace. || true; } | sed "s/\"/'/g" | xrdb -nocpp -merge
}

trawl_sway_cleanup() {
    trawldb --query wm.workspace.|sed "s/\"/'/g" > $XDG_RUNTIME_DIR/trawl_sway_cleanup.tmp
    trawldb --nocpp --merge $XDG_RUNTIME_DIR/trawl_sway_cleanup.tmp
}

# Set DEFAULT_XRESOURCE_LOOK_PATH to the look used when regolith.look.path is
# not set: the most recently installed look directory, by birth time, as
# package updates change the mtime. Use the mtime where there is no birth time.
resolve_default_look_path() {
    local by_birth=--time=birth newest
    if stat -c %W "$DEFAULT_LOOK_ROOT"/*/ 2>/dev/null | grep -vx '[1-9][0-9]*' >/dev/null; then
        by_birth=
    fi
    newest=$(ls -td ${by_birth:+"$by_birth"} "$DEFAULT_LOOK_ROOT"/*/ 2>/dev/null | head -n 1) || true
    if [ -d "$newest" ]; then
        DEFAULT_XRESOURCE_LOOK_PATH="${newest%/}"
    fi
}

# Set LOOK_STYLE_ROOT_PATH to the look in use, from the resources merged so
# far: the directory regolith.look.path names, when it holds a root file, or
# else the most recently installed look. LOOK_STYLE_ROOT_FILE is its root.
resolve_look_path() { # resolve_look_path <xrescat|trawlcat>
    resolve_default_look_path

    LOOK_STYLE_ROOT_PATH=$("$1" regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH" 2>/dev/null) \
        || LOOK_STYLE_ROOT_PATH=""

    if [ -z "$LOOK_STYLE_ROOT_PATH" ] || ! is_settings_file "$LOOK_STYLE_ROOT_PATH/root"; then
        LOOK_STYLE_ROOT_PATH="$DEFAULT_XRESOURCE_LOOK_PATH"
    fi
    LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"
}

# 1. Load the administrators' and the user's Xresources, the user's last
# 2. Load the Regolith Look Xresource as they define it, or the default
# 3. Re-merge the administrators' and the user's Xresources over the look
load_regolith_xres() {
    resolve_layer_xres_files

    if [ "${#LAYER_XRESOURCE_FILES[@]}" -gt 0 ]; then
        xrdb_merge_files "${LAYER_XRESOURCE_FILES[@]}"
    fi

    resolve_look_path xrescat

    if is_settings_file "$LOOK_STYLE_ROOT_FILE"; then
        xrdb_merge_files "$LOOK_STYLE_ROOT_FILE"
    fi #TODO: emit some dialog notifying user of invalid configuration on else

    if [ "${#LAYER_XRESOURCE_FILES[@]}" -gt 0 ]; then
        xrdb_merge_files "${LAYER_XRESOURCE_FILES[@]}"
    fi
}

# In the X11 session gsd-xsettings owns Xft.dpi: it publishes 96 dpi times
# org.gnome.desktop.interface text-scaling-factor, times the UI scale of GNOME
# Flashback, over XSETTINGS, where GTK reads it, and writes the same value into
# the X resources over the user's own. To keep an Xft.dpi set in ~/.Xresources
# or the administrators' or the user's Regolith Xresources working, set the
# text scaling factor that makes gsd-xsettings publish that value, and publish
# it in the X resources the same way, over a look's own Xft.dpi. The factor
# is recorded so that removing Xft.dpi later resets it, unless it was changed
# elsewhere in the meantime.
apply_user_xft_dpi() {
    local file resources value dpi="" current scale=1 factor
    xrdb_symbols
    resolve_layer_xres_files
    # Later files win, as in the login path. A value that is not a plain
    # number is ignored, as is a file that does not preprocess.
    for file in "$BASELINE_XRESOURCE_FILE" "${LAYER_XRESOURCE_FILES[@]}"; do
        is_settings_file "$file" || continue
        resources=$(preprocess_xres_file "$file" "${XRDB_SYMBOLS[@]}" 2>/dev/null) || continue
        value=$(printf '%s\n' "$resources" | xrdb -n -nocpp -load 2>/dev/null \
                | sed -n 's/^Xft\.dpi:[[:space:]]*//p' | tail -n 1) || true
        case $value in
            '') ;;
            *[!0-9.]* | .* | *.*.*)
                echo "Ignoring Xft.dpi: $value is not a number" >&2 ;;
            *)
                dpi=$value ;;
        esac
    done
    if [ -n "$dpi" ]; then
        printf 'Xft.dpi: %s\n' "$dpi" | xrdb -nocpp -merge
    fi

    command -v gsettings >/dev/null 2>&1 || return 0
    current=$(gsettings get org.gnome.desktop.interface text-scaling-factor 2>/dev/null) || return 0

    if [ -z "$dpi" ]; then
        if [ -f "$XFT_DPI_STATE_FILE" ]; then
            if same_number "$current" "$(cat "$XFT_DPI_STATE_FILE")"; then
                gsettings reset org.gnome.desktop.interface text-scaling-factor
            fi
            rm -f "$XFT_DPI_STATE_FILE"
        fi
        return 0
    fi

    # gsd-xsettings uses a UI scale of 1 if GNOME Flashback does not answer.
    # Flashback starts with the session, so wait for it briefly.
    if command -v gdbus >/dev/null 2>&1 \
       && gdbus wait --session --timeout 5 org.gnome.Mutter.X11 >/dev/null 2>&1; then
        scale=$(gdbus call --session --dest org.gnome.Mutter.X11 \
                    --object-path /org/gnome/Mutter/X11 \
                    --method org.freedesktop.DBus.Properties.Get \
                    org.gnome.Mutter.X11 UiScalingFactor 2>/dev/null \
                | tr -cd '0-9') || true
        [ "${scale:-0}" -ge 1 ] 2>/dev/null || scale=1
    fi
    factor=$(awk -v dpi="$dpi" -v scale="$scale" 'BEGIN { printf "%.17g", dpi / (96 * scale) }')
    if ! same_number "$current" "$factor"; then
        gsettings set org.gnome.desktop.interface text-scaling-factor "$factor"
    fi
    mkdir -p "${XFT_DPI_STATE_FILE%/*}"
    echo "$factor" > "$XFT_DPI_STATE_FILE"
}

same_number() { # same_number <a> <b>
    awk -v a="$1" -v b="$2" 'BEGIN { exit !((a - b) ^ 2 < 1e-12) }'
}

# Loads the Xresource files into trawl, as load_regolith_xres does
# NOTE: Will load sway specific reource files
load_regolith_trawlres() {
    resolve_layer_xres_files

    if [ "${#LAYER_XRESOURCE_FILES[@]}" -gt 0 ]; then
        trawl_merge_files "${LAYER_XRESOURCE_FILES[@]}"
    fi

    resolve_look_path trawlcat

    if is_settings_file "$LOOK_STYLE_ROOT_FILE"; then
        trawl_merge_files "$LOOK_STYLE_ROOT_FILE"
    fi #TODO: emit some dialog notifying user of invalid configuration on else

    if [ "${#LAYER_XRESOURCE_FILES[@]}" -gt 0 ]; then
        trawl_merge_files "${LAYER_XRESOURCE_FILES[@]}"
    fi
}

# Merge the system resources, as the display manager's Xsession does
# source ~ https://git.launchpad.net/ubuntu/+source/gdm3/tree/debian/patches/ubuntu/xresources_is_a_dir.patch?h=applied/ubuntu/noble
load_system_xres() {
    local file
    while IFS= read -r file; do
        xrdb -nocpp -merge "$file"
    done < <(system_xres_files)
}

# The Wayland session has no display manager merging the system resources:
# merge them into trawl in the same way
load_system_trawlres() {
    local file
    while IFS= read -r file; do
        trawldb --nocpp --merge "$file"
    done < <(system_xres_files)
}

# Load the X resources as the login does: ~/.Xresources first, then the look,
# then the administrators' and the user's Regolith Xresources, which win
load_i3_resources() {
    load_standard_xres # ~/.Xresources
    load_regolith_xres # the look and the Regolith Xresources of every layer
    xres_i3_cleanup    # Single-quote workspace names for i3
    apply_user_xft_dpi # Xft.dpi from the files above, through gsd-xsettings
}

# Load the trawl resources as the login does
load_sway_resources() {
    load_standard_trawlres
    load_regolith_trawlres
    # workaround to prevent always loading the default look
    load_regolith_trawlres
    trawl_sway_cleanup
}

# Start the X resource database again from what it holds before the login
# loads the files: clear it and merge the system resources as the display
# manager does. Loading the files into it then rebuilds it as a login does;
# merging into the old database instead would keep resources that the
# previous look set and the new one doesn't, or that the user removed from
# their files. Resources merged by hand or by programs, outside any file, go
# too, except gsd-xsettings' Xft.* and Xcursor.*: it writes them only when its
# settings change, and X programs (i3 too) take the DPI from Xft.dpi.
clear_xres() {
    local xsettings
    xsettings=$(xrdb -query | grep -E '^(Xft|Xcursor)\.' || true)
    xrdb -remove
    load_system_xres
    if [ -n "$xsettings" ]; then
        printf '%s\n' "$xsettings" | xrdb -nocpp -merge
    fi
}

# Rebuild the X resources from scratch, as the login builds them
reload_i3_resources() {
    clear_xres
    load_i3_resources
}

# Rebuild trawl's resources from scratch, starting with the system resources.
# trawld runs as long as the user's systemd instance, so it can also hold an
# earlier session's resources.
reload_sway_resources() {
    trawldb --remove
    load_system_trawlres
    load_sway_resources
}
