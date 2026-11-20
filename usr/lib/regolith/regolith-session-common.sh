#!/bin/bash
# This script contains common functions for Regolith session management

# File Locations - Optional User Overrides
USER_XRESOURCE_OVERRIDE_FILE="$HOME/.config/regolith3/Xresources"
USER_XRESOURCE_SEARCH_PATH="$HOME/.config/regolith3/Xresources.d"

# File Locations - System Defaults
DEFAULT_XRESOURCE_LOOK_PATH="/usr/share/regolith-look/default"

DEFAULT_SYS_I3_CONFIG_FILE="/etc/regolith/i3/config"
DEFAULT_USER_I3_CONFIG_FILE="$HOME/.config/regolith3/i3/config"

DEFAULT_SYS_SWAY_CONFIG_FILE="/etc/regolith/sway/config"
DEFAULT_USER_SWAY_CONFIG_FILE="$HOME/.config/regolith3/sway/config"

# File Locations - Baseline
BASELINE_XRESOURCE_FILE="$HOME/.Xresources"

# Regolith Look directories
DEFAULT_LOOK_ROOT="/usr/share/regolith-look"
USER_LOOK_ROOT="$HOME/.config/regolith3/looks"

# File location - user scripts
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

# Determine where the default i3 and sway config files are
# Sets I3_CONFIG_FILE and SWAY_CONFIG_FILE
resolve_default_config_file() {
    if [ -e "$DEFAULT_USER_I3_CONFIG_FILE" ]; then
        I3_CONFIG_FILE="$DEFAULT_USER_I3_CONFIG_FILE"
    else
        I3_CONFIG_FILE="$DEFAULT_SYS_I3_CONFIG_FILE"
    fi
    
    # To be changed with sway config locations
    if [ -f "$DEFAULT_USER_SWAY_CONFIG_FILE" ]; then
        SWAY_CONFIG_FILE="$DEFAULT_USER_SWAY_CONFIG_FILE"
    else
        SWAY_CONFIG_FILE="$DEFAULT_SYS_SWAY_CONFIG_FILE"
    fi
}

# Load default Xresources
load_standard_xres() {
    if [ -e "$BASELINE_XRESOURCE_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -merge "$BASELINE_XRESOURCE_FILE"
    fi
}

# Load default Xresources
load_standard_trawlres() {
    if [ -f "$BASELINE_XRESOURCE_FILE" ]; then
        trawldb --cpp "$XRES_CPP" --merge "$BASELINE_XRESOURCE_FILE"
    fi
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

# Workspace names
# The workspace keys run "workspace number $wsN", where $wsN is the value of
# wm.workspace.NN.name, for the workspaces 1 to 19. The window managers take
# the number of the workspace from the leading digits of the name, so a name
# without them (wm.workspace.01.name: terminal), or one that starts with
# another number (wm.workspace.04.name: 2024 plans), breaks the keys of that
# workspace, and an empty name breaks them in i3.
WORKSPACE_NAME_COUNT=19

# workspace_name_with_number <N> <value>: print the value in the form the
# workspace keys of workspace N need: as it is if its leading digits are the
# number N (1, 01, 1: term), N if it is empty, otherwise N: and the value.
workspace_name_with_number() {
    local n=$1 value=$2 digits
    digits=${value%%[!0-9]*}
    while [[ $digits == 0?* ]]; do
        digits=${digits#0}
    done
    if [ -z "$value" ]; then
        printf '%s' "$n"
    elif [ "$digits" = "$n" ]; then
        printf '%s' "$value"
    else
        printf '%s:%s' "$n" "$value"
    fi
}

# workspace_name_values <array>: read the lines of xrdb -query or trawldb
# --query from stdin and set <array>[N] to the value of wm.workspace.NN.name
# as the database lists it: xrdb escapes backslashes and line breaks, trawl
# keeps the text of the file. Unset names stay unset.
# shellcheck disable=SC2034 # values_ref is the caller's array
workspace_name_values() {
    local -n values_ref=$1
    local line key n
    values_ref=()
    while IFS= read -r line || [ -n "$line" ]; do
        key=${line%%:*}
        [[ $key =~ ^wm\.workspace\.([0-9][0-9])\.name[[:space:]]*$ ]] || continue
        n=$((10#${BASH_REMATCH[1]}))
        (( n >= 1 && n <= WORKSPACE_NAME_COUNT )) || continue
        line=${line#*:}
        values_ref[n]=${line#"${line%%[![:space:]]*}"}
    done
}

# numbered_workspace_name_lines: read the lines of xrdb -query or trawldb
# --query from stdin and print a resource line for each wm.workspace.NN.name
# that lacks the number of its workspace. Unset names stay unset: the window
# manager configs default them to N. The values stay as the database lists
# them, so they merge back unchanged.
numbered_workspace_name_lines() {
    local -a values=()
    local n stored
    workspace_name_values values
    for n in "${!values[@]}"; do
        stored=$(workspace_name_with_number "$n" "${values[n]}")
        if [ "$stored" != "${values[n]}" ]; then
            printf 'wm.workspace.%02d.name: %s\n' "$n" "$stored"
        fi
    done
}

# Give every workspace name the number of its workspace, in the X resources
xres_number_workspace_names() {
    local lines
    lines=$(xrdb -query | numbered_workspace_name_lines)
    if [ -n "$lines" ]; then
        printf '%s\n' "$lines" | xrdb -nocpp -merge
    fi
}

# Give every workspace name the number of its workspace, in trawl
trawl_number_workspace_names() {
    local lines
    lines=$(trawldb --query wm.workspace. | numbered_workspace_name_lines)
    if [ -n "$lines" ]; then
        printf '%s\n' "$lines" > "$XDG_RUNTIME_DIR/trawl_workspace_names.tmp"
        trawldb --nocpp --merge "$XDG_RUNTIME_DIR/trawl_workspace_names.tmp"
    fi
}

# i3_workspace_name <value>: print the name i3 gives the workspace of a
# wm.workspace.NN.name value as xrdb -query lists it. i3 reads the resource
# with xcb-xrm, which turns \\, \n and octal escapes into characters and keeps
# other backslashes. The workspace keys then pass it unquoted to the workspace
# command, whose name ends at a ";", a "," or a line break and which turns \\
# and \" into \ and ".
i3_workspace_name() {
    local in=$1 out="" c next i=0
    while [ "$i" -lt "${#in}" ]; do
        c=${in:i:1}
        next=${in:i+1:1}
        if [ "$c" = "\\" ] && [ "$next" = "\\" ]; then
            out+="\\"; i=$((i + 2))
        elif [ "$c" = "\\" ] && [ "$next" = n ]; then
            out+=$'\n'; i=$((i + 2))
        elif [ "$c" = "\\" ] && [[ ${in:i+1:3} =~ ^[0-7]{3}$ ]]; then
            printf -v c '%b' "\\0${in:i+1:3}"
            out+=$c; i=$((i + 4))
        else
            out+=$c; i=$((i + 1))
        fi
    done
    in=${out#"${out%%[!$' \t']*}"}
    in=${in%%[;,$'\r\n']*}
    out="" i=0
    while [ "$i" -lt "${#in}" ]; do
        c=${in:i:1}
        next=${in:i+1:1}
        if [ "$c" = "\\" ] && { [ "$next" = "\\" ] || [ "$next" = '"' ]; }; then
            c=$next; i=$((i + 1))
        fi
        out+=$c; i=$((i + 1))
    done
    printf '%s' "${out:-}"
}

# sway_unescape <text>: print the text as sway's config reader unescapes the
# arguments of a line: C escapes become characters, \0 ends the text, a
# trailing backslash goes and other backslashes stay.
sway_unescape() {
    local in=$1 out="" c hex i=0
    while [ "$i" -lt "${#in}" ]; do
        c=${in:i:1}
        i=$((i + 1))
        if [ "$c" != "\\" ]; then
            out+=$c
            continue
        fi
        c=${in:i:1}
        i=$((i + 1))
        case $c in
            '') ;;
            0) break ;;
            a) out+=$'\a' ;;
            b) out+=$'\b' ;;
            f) out+=$'\f' ;;
            n) out+=$'\n' ;;
            r) out+=$'\r' ;;
            t) out+=$'\t' ;;
            v) out+=$'\v' ;;
            "\\" | "'" | '"' | '?') out+=$c ;;
            x)
                hex=${in:i:2}
                hex=${hex%%[!0-9A-Fa-f]*}
                if [ -n "$hex" ]; then
                    printf -v c '%b' "\\x$hex"
                    out+=$c; i=$((i + ${#hex}))
                else
                    out+="\\x"
                fi ;;
            *) out+="\\$c" ;;
        esac
    done
    printf '%s' "$out"
}

# sway_workspace_name <value>: print the name sway gives the workspace of a
# wm.workspace.NN.name value as trawl holds it. The sway config sets $wsN to
# the value in double quotes and binds the workspace keys to "workspace
# number $wsN"; both lines unescape it. Running the binding then drops the
# quotes that no backslash escapes.
sway_workspace_name() {
    local in out="" c i=0 in_str=false in_chr=false escaped=false
    # The dots keep a final line break, which $(...) would drop
    in=$(sway_unescape "$1"; printf .)
    in=$(sway_unescape "${in%.}"; printf .)
    in=\"${in%.}\"
    while [ "$i" -lt "${#in}" ]; do
        c=${in:i:1}
        i=$((i + 1))
        if [ "$c" = "'" ] && ! $in_str && ! $escaped; then
            if $in_chr; then in_chr=false; else in_chr=true; fi
            continue
        elif [ "$c" = '"' ] && ! $in_chr && ! $escaped; then
            if $in_str; then in_str=false; else in_str=true; fi
            continue
        elif [ "$c" = "\\" ]; then
            if $escaped; then escaped=false; else escaped=true; fi
        else
            escaped=false
        fi
        out+=$c
    done
    printf '%s' "$out"
}

# workspace_names <array>: set <array>[N] to the name that the window manager
# of this session gives workspace N from the current wm.workspace.NN.name, or
# N where it is unset or empty
workspace_names() {
    local -n names_ref=$1
    local -a values=()
    local n
    names_ref=()
    if [ "${XDG_SESSION_TYPE-}" == "wayland" ]; then
        workspace_name_values values < <(trawldb --query wm.workspace. 2>/dev/null)
    else
        workspace_name_values values < <(xrdb -query 2>/dev/null)
    fi
    for n in $(seq "$WORKSPACE_NAME_COUNT"); do
        if [ -z "${values[n]-}" ]; then
            names_ref[n]=$n
        elif [ "${XDG_SESSION_TYPE-}" == "wayland" ]; then
            names_ref[n]=$(sway_workspace_name "${values[n]}"; printf .)
            names_ref[n]=${names_ref[n]%.}
        else
            names_ref[n]=$(i3_workspace_name "${values[n]}")
        fi
    done
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

# 1. Load the Regolith Xresource override file if exists
# 2. Load Regolith Look Xresource as defined in override or use default
# 3. Re-merge Regolith Xresource override file if exists
load_regolith_xres() {
    if [ -e "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi

    resolve_default_look_path

    LOOK_STYLE_ROOT_PATH=$(xrescat regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH")

    if [ -d "$LOOK_STYLE_ROOT_PATH" ]; then
        LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"
    else 
        LOOK_STYLE_ROOT_FILE="$DEFAULT_XRESOURCE_LOOK_PATH/root"
    fi

    if [ -e "$LOOK_STYLE_ROOT_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$LOOK_STYLE_ROOT_FILE"
    fi #TODO: emit some dialog notifying user of invalid configuration on else

    if [ -e "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi
}

# In the X11 session gsd-xsettings owns Xft.dpi: it publishes 96 dpi times
# org.gnome.desktop.interface text-scaling-factor, times the UI scale of GNOME
# Flashback, over XSETTINGS, where GTK reads it, and writes the same value into
# the X resources over the user's own. To keep an Xft.dpi set in ~/.Xresources
# or the Regolith Xresources working, set the text scaling factor that makes
# gsd-xsettings publish that value. The factor is recorded so that removing
# Xft.dpi later resets it, unless it was changed elsewhere in the meantime.
apply_user_xft_dpi() {
    command -v gsettings >/dev/null 2>&1 || return 0
    local file value dpi="" current scale=1 factor
    # Later files win, as in the login path
    for file in "$BASELINE_XRESOURCE_FILE" "$USER_XRESOURCE_OVERRIDE_FILE"; do
        [ -e "$file" ] || continue
        value=$(xrdb -n -I"$USER_XRESOURCE_SEARCH_PATH" -load "$file" 2>/dev/null \
                | sed -n 's/^Xft\.dpi:[[:space:]]*//p' | tail -n 1) || true
        [ -z "$value" ] || dpi=$value
    done
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
    case $dpi in
        *[!0-9.]* | .* | *.*.*)
            echo "Ignoring Xft.dpi: $dpi is not a number" >&2
            return 0 ;;
    esac

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

# Loads the Xresource files into trawl. 
# NOTE: Will load sway specific reource files
load_regolith_trawlres() {
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        trawldb --cpp "$XRES_CPP" -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi

    resolve_default_look_path

    LOOK_STYLE_ROOT_PATH=$(trawlcat regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH")

    if [ -d "$LOOK_STYLE_ROOT_PATH" ]; then
        LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"
    else 
        LOOK_STYLE_ROOT_FILE="$DEFAULT_XRESOURCE_LOOK_PATH/root"
    fi

    if [ -f "$LOOK_STYLE_ROOT_FILE" ]; then
        trawldb --cpp "$XRES_CPP" -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$LOOK_STYLE_ROOT_FILE" 
    fi #TODO: emit some dialog notifying user of invalid configuration on else
    
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        trawldb --cpp "$XRES_CPP" -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi
}

# Merge the system resources, as the display manager's Xsession does
# source ~ https://git.launchpad.net/ubuntu/+source/gdm3/tree/debian/patches/ubuntu/xresources_is_a_dir.patch?h=applied/ubuntu/noble
load_system_xres() {
    local sysresources=/etc/X11/Xresources i
    for i in `ls "$sysresources" 2>/dev/null` ; do
        if [ -r "$sysresources/$i"  -a -f "$sysresources/$i" ] && expr "$i" : '^[[:alnum:]_-]\+$' > /dev/null; then
            xrdb -nocpp -merge "$sysresources/$i"
        fi
    done
}

# Load the X resources as the login does: ~/.Xresources first, then the
# Regolith Xresources and the look, which win over it
load_i3_resources() {
    load_standard_xres # ~/.Xresources
    load_regolith_xres # ~/.config/regolith3/Xresources and the look
    xres_i3_cleanup    # Single-quote workspace names for i3
    xres_number_workspace_names # Workspace names start with their number
    apply_user_xft_dpi # Xft.dpi from the files above, through gsd-xsettings
}

# Load the trawl resources as the login does
load_sway_resources() {
    load_standard_trawlres
    load_regolith_trawlres
    # workaround to prevent always loading the default look
    load_regolith_trawlres
    trawl_sway_cleanup
    trawl_number_workspace_names
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

# Rebuild trawl's resources from scratch. trawld runs as long as the user's
# systemd instance, so it can also hold an earlier session's resources.
reload_sway_resources() {
    trawldb --remove
    load_sway_resources
}
