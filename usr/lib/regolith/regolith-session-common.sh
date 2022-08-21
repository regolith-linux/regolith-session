#!/bin/bash
# This script contains common functions for Regolith session management

# File Locations - Optional User Overrides
USER_XRESOURCE_OVERRIDE_FILE="$HOME/.config/regolith2/Xresources"
USER_XRESOURCE_SEARCH_PATH="$HOME/.config/regolith2/Xresources.d"

# File Locations - System Defaults
DEFAULT_XRESOURCE_LOOK_PATH="/usr/share/regolith-look/default"

DEFAULT_SYS_I3_CONFIG_FILE="/etc/regolith/i3/config"
DEFAULT_USER_I3_CONFIG_FILE="$HOME/.config/regolith2/i3/config"

DEFAULT_SYS_SWAY_CONFIG_FILE="/etc/regolith/sway/config"
DEFAULT_USER_SWAY_CONFIG_FILE="$HOME/.config/regolith2/sway/config"

# File Locations - Baseline
BASELINE_XRESOURCE_FILE="$HOME/.Xresources"

# Regolith Look directories
DEFAULT_LOOK_ROOT="/usr/share/regolith-look"
USER_LOOK_ROOT="$HOME/.config/regolith2/looks"

# File location - user scripts
USER_POST_LOGOUT_SCRIPT_FILE="$HOME/.config/regolith2/logout"

DEFAULT_SESSION_TYPE="i3"

# Set the default resource getter
RESOURCE_GETTER="xrescat"
if [ $XDG_SESSION_TYPE == "wayland" ]; then
	RESOURCE_GETTER="trawlcat"
fi

# Determine where the default i3 and sway config files are
# Sets I3_CONFIG_FILE and SWAY_CONFIG_FILE
resolve_default_config_file() {
    if [ -f "$DEFAULT_USER_I3_CONFIG_FILE" ]; then
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
    if [ -f "$BASELINE_XRESOURCE_FILE" ]; then
        xrdb -merge "$BASELINE_XRESOURCE_FILE"
    fi
}

# Load default Xresources
load_standard_trawlres() {
    if [ -f "$BASELINE_XRESOURCE_FILE" ]; then
        trawldb --merge "$BASELINE_XRESOURCE_FILE"
    fi
}

# Change the quotes in workspace names from double to to single.
# Due to a limitation of the preprocessor they have double quotes.
# The i3-wm workspace command fails with double quotes in the name
# NOTE: Calling this function in Regolith 2 desktop sessio was removed due to silent failures
xres_i3_cleanup() {
    xrdb -query |grep i3-wm.workspace.|sed "s/\"/'/g"|xrdb -merge
}

trawl_sway_cleanup() {
    trawldb --query i3-wm.workspace.|sed "s/\"/'/g" > $XDG_RUNTIME_DIR/trawl_sway_cleanup.tmp
    trawldb --merge $XDG_RUNTIME_DIR/trawl_sway_cleanup.tmp
}

# 1. Load the Regolith Xresource override file if exists
# 2. Load Regolith Look Xresource as defined in override or use default
# 3. Re-merge Regolith Xresource override file if exists
load_regolith_xres() {
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        xrdb -merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi

    LOOK_STYLE_ROOT_PATH=$(xrescat regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH")
    LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"

    if [ -f "$LOOK_STYLE_ROOT_FILE" ]; then
        xrdb -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$LOOK_STYLE_ROOT_FILE"
    fi

    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        xrdb -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi
}

# Loads the Xresource files into trawl. 
# NOTE: Will load sway specific reource files
load_regolith_trawlres() {
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        trawldb --merge "$USER_XRESOURCE_OVERRIDE_FILE" 
    fi

    LOOK_STYLE_ROOT_PATH=$(trawlcat regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH")
    LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"

    if [ -f "$LOOK_STYLE_ROOT_FILE" ]; then
        trawldb -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$LOOK_STYLE_ROOT_FILE" 
    fi
    
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        trawldb -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi
}
