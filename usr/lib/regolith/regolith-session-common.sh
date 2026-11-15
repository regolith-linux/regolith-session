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

# The desktop settings of the Regolith sessions
#
# The user's other desktops (plain GNOME, for one) read the same dconf
# databases as the Regolith sessions, so the look's settings and every change
# made in a Regolith session would reach them. The Regolith sessions use a
# dconf profile of their own instead: Regolith's own user database, which
# takes every write made in them, above the databases that the user's sessions
# read without Regolith, in their order. Keys Regolith never wrote show the
# values of those databases, and administrator defaults and locks apply as
# they do there. The profile is written when it is needed, as the databases
# below Regolith's depend on the login environment and the system.
# dconf takes letters, digits and underscores in database names
REGOLITH_DCONF_DB="regolith_session"
REGOLITH_DCONF_PROFILE_HEADER="# Desktop settings of the Regolith sessions, written by regolith-session"
REGOLITH_DCONF_PLAIN_PREFIX="# DCONF_PROFILE without Regolith: "

# The profile lives in dconf's runtime directory, next to dconf's own runtime
# profile, where sandboxes given dconf access (Flatpak's xdg-run/dconf) find
# it too. No database can have its name: dconf doesn't take hyphens there.
regolith_dconf_profile_file() {
    echo "${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/dconf/regolith-session-profile"
}

# is_regolith_dconf_profile <DCONF_PROFILE>: whether it names Regolith's profile
is_regolith_dconf_profile() {
    [[ ${1-} == /* ]] && [ -f "$1" ] \
        && [ "$(head -n 1 "$1" 2>/dev/null)" == "$REGOLITH_DCONF_PROFILE_HEADER" ]
}

# regolith_dconf_plain_profile <file>: print the DCONF_PROFILE that Regolith's
# profile <file> was written for, empty for none
regolith_dconf_plain_profile() {
    local line
    while IFS= read -r line; do
        if [[ $line == "$REGOLITH_DCONF_PLAIN_PREFIX"* ]]; then
            line=${line#"$REGOLITH_DCONF_PLAIN_PREFIX"}
            is_regolith_dconf_profile "$line" || echo "$line"
            return 0
        fi
    done < "$1"
}

# find_dconf_profile <name>: print the file of the dconf profile <name> as dconf
# finds it: a path as it is, a name in /etc/dconf/profile and then in the
# dconf/profile directories of the data directories
find_dconf_profile() {
    local name=$1 dir dirs
    if [[ $name == /* ]]; then
        [ -e "$name" ] || return 1
        echo "$name"
        return 0
    fi
    IFS=: read -r -a dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    for dir in /etc "${dirs[@]}"; do
        if [ -n "$dir" ] && [ -e "$dir/dconf/profile/$name" ]; then
            echo "$dir/dconf/profile/$name"
            return 0
        fi
    done
    return 1
}

# plain_dconf_sources <DCONF_PROFILE>: print the databases (the user-db: and
# system-db: lines) of the profile that dconf picks for the user's sessions
# without Regolith: the profile named by DCONF_PROFILE if it is not empty, else
# the runtime profile, a "user" profile, or the built-in default. Fails where
# Regolith's database can't go above them: for a missing named profile, which
# gives no databases at all, for a profile that does not start with a user
# database, and with a mandatory profile, which dconf uses whatever
# DCONF_PROFILE says.
plain_dconf_sources() {
    local profile=$1 file sources
    local runtime_profile="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/dconf/profile"
    [ ! -e "/run/dconf/user/$(id -u)" ] || return 1
    if [ -n "$profile" ]; then
        file=$(find_dconf_profile "$profile") || return 1
    elif [ -e "$runtime_profile" ]; then
        file=$runtime_profile
    elif ! file=$(find_dconf_profile user); then
        echo "user-db:user"
        return 0
    fi
    # The sources only, as dconf reads them: no comments, blanks, or lines
    # dconf ignores
    sources=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                  -e '/^\(user\|system\|service\|file\)-db:/!d' "$file") \
        || return 1
    [[ $sources == user-db:* ]] || return 1
    echo "$sources"
}

# Use the desktop settings of the Regolith sessions: write Regolith's dconf
# profile and export DCONF_PROFILE naming it, for this script and everything
# it starts. The launchers and the session scripts pass it on to the whole
# session. A DCONF_PROFILE that an earlier Regolith session left behind is
# replaced by the profile written for the DCONF_PROFILE that session had.
# --outside-session: for the tools that may run without the session's
# environment. With no DCONF_PROFILE set, they use the databases that the last
# Regolith session of the user used.
# Sets REGOLITH_SETTINGS_DB and PLAIN_SETTINGS_DB, the user databases that the
# Regolith sessions and the other sessions write. They are empty, and
# DCONF_PROFILE is left as it was, where Regolith's database can't be put
# above the user's databases.
use_regolith_settings() {
    local file plain=${DCONF_PROFILE-} sources db n=1 profile tmp
    REGOLITH_SETTINGS_DB="" PLAIN_SETTINGS_DB=""
    file=$(regolith_dconf_profile_file)
    if is_regolith_dconf_profile "$plain"; then
        plain=$(regolith_dconf_plain_profile "$plain")
    elif [ -z "$plain" ] && [ "${1-}" == "--outside-session" ] \
         && is_regolith_dconf_profile "$file"; then
        plain=$(regolith_dconf_plain_profile "$file")
    fi
    if ! sources=$(plain_dconf_sources "$plain"); then
        echo "Regolith's desktop settings can't be kept apart with the dconf profile ${plain:-user}" >&2
        if [ -n "$plain" ]; then
            export DCONF_PROFILE="$plain"
        else
            unset DCONF_PROFILE
        fi
        return 0
    fi
    # A name none of the user's own databases has
    db=$REGOLITH_DCONF_DB
    while grep -qxF "user-db:$db" <<< "$sources"; do
        n=$((n + 1))
        db="${REGOLITH_DCONF_DB}_$n"
    done
    profile=$(printf '%s\n' "$REGOLITH_DCONF_PROFILE_HEADER" \
                  "$REGOLITH_DCONF_PLAIN_PREFIX$plain" "user-db:$db" "$sources")
    # Clients read the profile when they start: replace it in one step
    if [ "$(cat "$file" 2>/dev/null)" != "$profile" ]; then
        # Private, as dconf makes it
        (umask 077 && mkdir -p "${file%/*}")
        tmp=$(mktemp "$file.XXXXXX")
        echo "$profile" > "$tmp"
        mv -f "$tmp" "$file"
    fi
    export DCONF_PROFILE="$file"
    REGOLITH_SETTINGS_DB=$db
    PLAIN_SETTINGS_DB=${sources%%$'\n'*}
    PLAIN_SETTINGS_DB=${PLAIN_SETTINGS_DB#user-db:}
}

# skip_locked_settings <command...>: run a look's load_look with gsettings
# leaving out the keys that an administrator locked. They keep the
# administrator's value, and the loader would stop at the first key it can't
# write, without applying the rest of the look.
skip_locked_settings() {
    # shellcheck disable=SC2329 # the look's loader calls it
    gsettings() {
        if [ "${1-}" == "set" ] && [ "$#" -eq 4 ] \
           && [ "$(command gsettings writable "$2" "$3" 2>/dev/null)" == "false" ]; then
            echo "Not setting $2 $3: the administrator locked it" >&2
            return 0
        fi
        command gsettings "$@"
    }
    "$@"
    unset -f gsettings
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

# Rebuild trawl's resources from scratch. trawld runs as long as the user's
# systemd instance, so it can also hold an earlier session's resources.
reload_sway_resources() {
    trawldb --remove
    load_sway_resources
}
