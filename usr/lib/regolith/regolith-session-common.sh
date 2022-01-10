#!/bin/bash
# This script contains common functions for Regolith session management

# File Locations - Optional User Overrides
USER_XRESOURCE_OVERRIDE_FILE="$HOME/.config/regolith/Xresources"
USER_XRESOURCE_SEARCH_PATH="$HOME/.config/regolith/Xresources.d"

# File Locations - System Defaults
DEFAULT_XRESOURCE_LOOK_PATH="/usr/share/regolith-look/default"
ETC_XRESOURCE_DIR="/etc/regolith/Xresources.d"

DEFAULT_SYS_I3_CONFIG_FILE="/etc/regolith/i3/config"
DEFAULT_USER_I3_CONFIG_FILE="$HOME/.config/regolith/i3/config"

# File Locations - Baseline
BASELINE_XRESOURCE_FILE="$HOME/.Xresources"

# Regolith Look base directory
DEFAULT_LOOK_ROOT="/usr/share/regolith-look"

# File location - user scripts
USER_POST_LOGOUT_SCRIPT_FILE="$HOME/.config/regolith/logout"

# Determine where the default i3 config file is
# Sets I3_CONFIG_FILE
resolve_default_config_file() {
    if [ -f "$DEFAULT_USER_I3_CONFIG_FILE" ]; then
        I3_CONFIG_FILE="$DEFAULT_USER_I3_CONFIG_FILE"
    else
        I3_CONFIG_FILE="$DEFAULT_SYS_I3_CONFIG_FILE"
    fi
}

# Load default Xresources
load_standard_xres() {    
    if [ -f "$BASELINE_XRESOURCE_FILE" ]; then
        xrdb -merge "$BASELINE_XRESOURCE_FILE"
    fi
}

# Change the quotes in workspace names from double to to single.
# Due to a limitation of the preprocessor they have double quotes.
# The i3-wm workspace command fails with double quotes in the name
xres_i3_cleanup() {   
    xrdb -query |grep i3-wm.workspace.|sed "s/\"/'/g"|xrdb -merge
}

# Generate a Xresource file from merging the following into ~/.config/regolith/Xresources-generated:
# 1. /usr/share/regolith-look/default/root or override defined in ~/.Xresources
# 2. ~/.config/regolith/Xresources
# 3. /etc/regolith/Xresources.d
load_regolith_xres() {    
    GENERATED_XRES_DIR="$HOME/.cache/regolith"
    GENERATED_XRES_FILE="$GENERATED_XRES_DIR/Xresources-generated"
    if [ ! -d "$GENERATED_XRES_DIR" ]; then
        mkdir -p "$GENERATED_XRES_DIR"
    fi
    
    LOOK_STYLE_ROOT_PATH=$(xrescat regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH")
    LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"

    echo "!+ Merged $LOOK_STYLE_ROOT_FILE from ($(date))" > "$GENERATED_XRES_FILE"
    cat "$LOOK_STYLE_ROOT_FILE" >> "$GENERATED_XRES_FILE"

    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        printf "\n!+ Merged from %s at (%s)\n" "$USER_XRESOURCE_OVERRIDE_FILE" "$(date)" >> "$GENERATED_XRES_FILE"
        cat "$USER_XRESOURCE_OVERRIDE_FILE" >> "$GENERATED_XRES_FILE"
    fi

    for filename in "$ETC_XRESOURCE_DIR"/*; do
        printf "\n!+ Merged from %s at (%s)\n" "$filename" "$(date)" >> "$GENERATED_XRES_FILE"
        cat "$filename" >> "$GENERATED_XRES_FILE"
    done

    xrdb -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$GENERATED_XRES_FILE"
}



