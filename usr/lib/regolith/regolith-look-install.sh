# shellcheck shell=bash
# Sourced by regolith-look: fetching looks from git repositories with
# regolith-look install, update, remove and list --installed.
#
# Looks fetched from git repositories
#
# 'regolith-look install' fetches a look into USER_LOOK_ROOT. A fetched look
# may not run code of its own or read files from elsewhere, any more than a
# colour scheme can: it holds only folders and ordinary, non-executable files,
# and the resources the session reads from it, once preprocessed, pull in no
# file from outside its folder and DEFAULT_LOOK_ROOT, set no resource the
# window manager runs as a command, name no loader but a shipped one, and
# send the Wayland session to no look outside its folder and DEFAULT_LOOK_ROOT.
# The source, revision and folder of each fetched look are recorded outside
# the looks folder, so that a folder placed there by hand is never taken for
# a fetched one. install, update and remove take a lock there and run one at
# a time.
INSTALLED_LOOK_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/regolith/looks"

# Resources the window manager runs as commands, and the look loader
WM_STATUS_COMMAND_RESOURCE="wm.bar.status_command"
WM_PROGRAM_RESOURCE_PREFIX="wm.program."
LOOK_LOADER_RESOURCE="regolith.look.loader"

# xrdb defines these for the preprocessor in the X11 session, with values
# from the display, as well as macros named after the display's host, vendor,
# extensions and visual classes, with the prefixes below. trawldb defines none.
XRDB_SYMBOLS="HOST SERVERHOST DISPLAY_NUM CLIENTHOST VERSION REVISION VENDOR RELEASE NUM_SCREENS SCREEN_NUM WIDTH HEIGHT X_RESOLUTION Y_RESOLUTION PLANES BITS_PER_RGB CLASS COLOR"
XRDB_SYMBOL_PREFIXES="SRVR_ CLNT_ VNDR_ EXT_ CLASS_"

# Characters of a look name, spelled out: outside the C locale a range such
# as a-z can match other letters too
LOOK_NAME_START_CHARS="abcdefghijklmnopqrstuvwxyz0123456789"
LOOK_NAME_CHARS="$LOOK_NAME_START_CHARS._-"

LOOK_LABEL=""      # name of the look being fetched, for messages
WORK_DIR=""        # scratch folder of the fetch
PLACED_LOOK=""     # look folder to take away if the fetch fails
KEPT_LOOK=""       # earlier contents to put back at KEPT_LOOK_DIR if it fails
KEPT_LOOK_DIR=""

look_error() {
    echo "regolith-look: ${LOOK_LABEL:+$LOOK_LABEL: }$*" >&2
}

# valid_look_name <name>: 1 to 64 lower-case letters, digits, '.', '_' and
# '-', starting with a letter or a digit
valid_look_name() {
    local name=$1
    [ -n "$name" ] && [ "${#name}" -le 64 ] \
        && [[ "$LOOK_NAME_START_CHARS" == *"${name:0:1}"* ]] \
        && [ -z "${name//["$LOOK_NAME_CHARS"]/}" ]
}

# The name of a look fetched from <source> when none is given: the last part
# of the source path (after the last '/', or after the ':' of a host:path
# source), without a trailing slash, a trailing .git and a leading
# regolith-look-, in lower case
look_name_from_source() {
    local name=${1%/}
    name=${name##*/}
    name=${name##*:}
    name=$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    name=${name%.git}
    printf '%s\n' "${name#regolith-look-}"
}

# is_fetched_look <name>: whether the look <name> was put in place by install
# and has not been taken away since
is_fetched_look() {
    local state="$INSTALLED_LOOK_STATE_DIR/$1" dir="$USER_LOOK_ROOT/$1"
    valid_look_name "$1" \
        && [ -f "$state/source" ] && [ -f "$state/revision" ] && [ -f "$state/folder" ] \
        && [ -d "$dir" ] && [ ! -L "$dir" ] \
        && [ "$(stat -c %i -- "$dir")" == "$(<"$state/folder")" ]
}

# Print the names of the fetched looks, in byte order
fetched_looks() {
    local state
    for state in "$INSTALLED_LOOK_STATE_DIR"/*; do
        if is_fetched_look "${state##*/}"; then
            printf '%s\n' "${state##*/}"
        fi
    done | LC_ALL=C sort
}

# record_look <name> <source> <revision>: note the look in its folder as
# fetched from <source> at <revision>. Moving the new record into place is
# the step that makes the change; the old record waits aside until then.
record_look() {
    local state="$INSTALLED_LOOK_STATE_DIR/$1" new="$INSTALLED_LOOK_STATE_DIR/.$1.new"
    local old="$INSTALLED_LOOK_STATE_DIR/.$1.old"
    rm -rf -- "$new" "$old"
    mkdir "$new"
    printf '%s\n' "$2" >"$new/source"
    printf '%s\n' "$3" >"$new/revision"
    stat -c %i -- "$USER_LOOK_ROOT/$1" >"$new/folder"
    if [ -e "$state" ]; then
        mv -T -- "$state" "$old"
    fi
    mv -T -- "$new" "$state"
    rm -rf -- "$old"
}

# Run install, update and remove one at a time: wait for the lock, then put
# right whatever a command that was killed outright left half done. The lock
# is held on LOOK_LOCK_FD until the command exits.
LOOK_LOCK_FD=""
lock_looks() {
    mkdir -p "$INSTALLED_LOOK_STATE_DIR"
    exec {LOOK_LOCK_FD}>>"$INSTALLED_LOOK_STATE_DIR/.lock"
    flock "$LOOK_LOCK_FD"
    recover_looks
}

# refresh_session: rebuild the session's resources for the changed look, with
# the lock closed for the programs the rebuild starts, so that one that keeps
# running does not hold it
refresh_session() {
    refresh {LOOK_LOCK_FD}>&- >&2
}

# With the lock held no other command runs, so every scratch folder and
# unfinished record is left over from a killed one. A change it had not
# made yet is undone: a record not yet in place, a look folder placed but
# not recorded, and earlier contents moved aside.
recover_looks() {
    local file name dir work placed recorded
    for file in "$INSTALLED_LOOK_STATE_DIR"/.*.new "$INSTALLED_LOOK_STATE_DIR"/.*.old; do
        [ -e "$file" ] || continue
        name=${file##*/.}
        name=${name%.*}
        if [[ "$file" == *.old ]] && [ ! -e "$INSTALLED_LOOK_STATE_DIR/$name" ]; then
            mv -T -- "$file" "$INSTALLED_LOOK_STATE_DIR/$name"
        else
            rm -rf -- "$file"
        fi
    done
    for work in "${USER_LOOK_ROOT%/*}"/.regolith-look.*; do
        [ -d "$work" ] || continue
        if [ -f "$work/name" ] && [ -f "$work/placed" ]; then
            name=$(<"$work/name")
            placed=$(<"$work/placed")
            dir="$USER_LOOK_ROOT/$name"
            recorded=$(cat -- "$INSTALLED_LOOK_STATE_DIR/$name/folder" 2>/dev/null) || recorded=""
            if valid_look_name "$name" && [ "$placed" != "$recorded" ]; then
                if [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(stat -c %i -- "$dir")" == "$placed" ]; then
                    rm -rf -- "$dir"
                fi
                if [ -d "$work/kept" ] && [ ! -e "$dir" ]; then
                    mv -T -- "$work/kept" "$dir"
                fi
            fi
        fi
        rm -rf -- "$work"
    done
}

# make_work_dir <name>: make the scratch folder of a fetch of the look
# <name> next to the looks folder, on the same file system, so that the
# fetched look moves into place without a copy
make_work_dir() {
    mkdir -p "$USER_LOOK_ROOT"
    WORK_DIR=$(mktemp -d "${USER_LOOK_ROOT%/*}/.regolith-look.XXXXXX")
    printf '%s\n' "$1" >"$WORK_DIR/name"
    trap cleanup_fetch EXIT
    trap 'exit 1' HUP INT TERM
}

# place_look <name>: move the fetched contents into the look's folder,
# keeping earlier contents aside, so that a failure can put them back
place_look() {
    local dir="$USER_LOOK_ROOT/$1"
    # Noted first, so that the next command can undo a placement that a
    # kill left unrecorded
    stat -c %i -- "$WORK_DIR/look" >"$WORK_DIR/placed"
    if [ -e "$dir" ]; then
        KEPT_LOOK="$WORK_DIR/kept"
        KEPT_LOOK_DIR=$dir
        mv -T -- "$dir" "$KEPT_LOOK"
    fi
    PLACED_LOOK=$dir
    mv -T -- "$WORK_DIR/look" "$dir"
}

# commit_look <name> <source> <revision>: record the placed look. An
# interruption from here on no longer undoes the change.
commit_look() {
    trap '' HUP INT TERM
    record_look "$@"
    PLACED_LOOK=""
    KEPT_LOOK=""
    trap 'exit 1' HUP INT TERM
}

# Undo an unfinished fetch: take the new look folder away, put the earlier
# contents back and delete the scratch folder
cleanup_fetch() {
    if [ -n "$PLACED_LOOK" ]; then
        rm -rf -- "$PLACED_LOOK"
    fi
    if [ -n "$KEPT_LOOK" ] && [ -e "$KEPT_LOOK" ]; then
        mv -T -- "$KEPT_LOOK" "$KEPT_LOOK_DIR"
    fi
    if [ -n "$WORK_DIR" ]; then
        rm -rf -- "$WORK_DIR"
    fi
}

# fetch_look <source>: clone the source into the scratch folder and set
# FETCHED_REVISION to the newest commit on its default branch. A clone runs
# none of the source's hooks, and the look is read from git's objects, not
# checked out, so nothing from the repository runs. The bare clone is named
# with --git-dir, which works with safe.bareRepository=explicit.
fetch_look() {
    if ! command -v git >/dev/null; then
        look_error "fetching a look needs git: install the git package"
        return 1
    fi
    if ! GIT_TERMINAL_PROMPT=0 git clone --quiet --bare --no-hardlinks -- "$1" "$WORK_DIR/git" </dev/null >&2; then
        look_error "unable to fetch $1"
        return 1
    fi
    if ! FETCHED_REVISION=$(git --git-dir="$WORK_DIR/git" rev-parse --verify --quiet 'HEAD^{commit}'); then
        look_error "$1 has no commit on its default branch"
        return 1
    fi
}

# extract_look <revision> <folder>: write the files of the fetched revision
# into the new <folder>, byte for byte, as git stores them: no checkout
# filter or line ending conversion applies. Refuses a revision with links,
# submodules or executable files, or without a root file at its top.
extract_look() {
    local entry path mode type object refused="" has_root=""
    git --git-dir="$WORK_DIR/git" ls-tree -r -z --full-tree "$1" >"$WORK_DIR/tree"
    while IFS= read -r -d '' entry; do
        path=${entry#*$'\t'}
        read -r mode type object <<<"${entry%%$'\t'*}"
        case "/${path,,}/" in
            *//* | */./* | */../* | */.git/*)
                look_error "$path: not a file name a look can hold"
                refused=1
                continue
                ;;
        esac
        case "$mode" in
            100644) ;;
            120000) look_error "$path: links are not allowed in a look"; refused=1 ;;
            160000) look_error "$path: submodules are not allowed in a look"; refused=1 ;;
            100755) look_error "$path: executable files are not allowed in a look"; refused=1 ;;
            *) look_error "$path: unsupported file mode $mode"; refused=1 ;;
        esac
        if [ "$path" == "root" ] && [ "$type" == "blob" ]; then
            has_root=1
        fi
    done <"$WORK_DIR/tree"
    if [ -z "$has_root" ]; then
        look_error "root: the repository has no root file at its top"
        refused=1
    fi
    if [ -n "$refused" ]; then
        return 1
    fi

    mkdir "$2"
    while IFS= read -r -d '' entry; do
        path=${entry#*$'\t'}
        read -r mode type object <<<"${entry%%$'\t'*}"
        if [[ "$path" == */* ]]; then
            mkdir -p -- "$2/${path%/*}"
        fi
        git --git-dir="$WORK_DIR/git" cat-file blob "$object" >"$2/$path"
    done <"$WORK_DIR/tree"
}

# preprocess_look <folder> [<cpp options>...]: print the look's resources as
# the session reads them, with LOOK_DIR_MACRO standing for <folder>. Bounded
# in time and size, as a look could include a file that never ends.
preprocess_look() {
    local dir=$1
    shift
    (
        ulimit -t 60 2>/dev/null || true
        ulimit -v 1048576 2>/dev/null || true
        ulimit -f 102400 2>/dev/null || true
        exec timeout 60 "$XRES_CPP" -w -P "$@" -I"$USER_XRESOURCE_SEARCH_PATH" -D"$LOOK_DIR_MACRO=$dir" "$dir/root"
    ) </dev/null
}

# look_file_name <folder> <file>: <file> as a path from the top of the look
# in <folder>, or in full when it lies outside
look_file_name() {
    local dir file
    dir=$(realpath -m -- "$1")
    file=$(realpath -m -- "$2")
    if [[ "$file" == "$dir"/* ]]; then
        printf '%s\n' "${file#"$dir"/}"
    else
        printf '%s\n' "$file"
    fi
}

# allowed_look_file <file> <folder> <shipped looks folder>: whether <file>
# resolves to a file in the look's own folder or in the shipped looks folder
# (both given resolved)
allowed_look_file() {
    local real
    real=$(realpath -e -- "$1" 2>/dev/null) || return 1
    [[ "$real" == "$2"/* ]] || [[ "$real" == "$3"/* ]]
}

# check_look_includes <folder> <shipped looks folder> [<root file>]: read the
# files the look included, as cpp -H lists them, on stdin, and refuse the
# ones outside the look and the shipped looks folder. The reading starts at
# <root file>, the look's root by default. Fills INCLUDED_FILES.
declare -A INCLUDED_FILES=()
check_look_includes() {
    local dir=$1 look_real line depth file refused="" guards="" label
    local -a stack=("${3:-$dir/root}")
    label=$(look_file_name "$dir" "${stack[0]}")
    INCLUDED_FILES=()
    look_real=$(realpath -e -- "$dir")
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$guards" ]; then
            # The list ends with the included files that lack include guards
            if [ -z "${INCLUDED_FILES[$line]+set}" ]; then
                look_error "$label: unable to follow the files the look includes: $line"
                return 1
            fi
            continue
        fi
        if [ "$line" == "Multiple include guards may be useful for:" ]; then
            guards=1
            continue
        fi
        # One dot per level of inclusion, then the file
        if [[ ! "$line" =~ ^(\.+)\ (/.*)$ ]] || [ "${#BASH_REMATCH[1]}" -gt "${#stack[@]}" ]; then
            look_error "$label: unable to follow the files the look includes: $line"
            return 1
        fi
        depth=${#BASH_REMATCH[1]}
        file=${BASH_REMATCH[2]}
        INCLUDED_FILES[$file]=1
        if ! allowed_look_file "$file" "$look_real" "$2"; then
            look_error "$(look_file_name "$dir" "${stack[depth - 1]}"): includes $file, which is outside the look and $DEFAULT_LOOK_ROOT"
            refused=1
        fi
        stack=("${stack[@]:0:depth}" "$file")
    done
    [ -z "$refused" ]
}

# Print the files of a dependency list that cpp -MD wrote, one per line,
# without the escapes of make
make_dependencies() {
    local text i char file=""
    text=$(<"$1")
    text=${text//$'\\\n'/ }
    text=${text#*: }
    for ((i = 0; i < ${#text}; i = i + 1)); do
        char=${text:i:1}
        if [ "$char" == "\\" ] && [[ "${text:i+1:1}" == [\ \#] ]]; then
            i=$((i + 1))
            file+=${text:i:1}
        elif [ "$char" == "\$" ] && [ "${text:i+1:1}" == "\$" ]; then
            i=$((i + 1))
            file+="\$"
        elif [[ "$char" == [[:space:]] ]]; then
            if [ -n "$file" ]; then
                printf '%s\n' "$file"
            fi
            file=""
        else
            file+=$char
        fi
    done
    if [ -n "$file" ]; then
        printf '%s\n' "$file"
    fi
}

# Print the files the preprocessor reads for any input, before the input
# itself, such as /usr/include/stdc-predef.h when libc6-dev is installed
implicit_preprocessor_files() {
    : >"$WORK_DIR/empty"
    if "$XRES_CPP" -w -P -MD -MF "$WORK_DIR/empty.d" -MT look "$WORK_DIR/empty" </dev/null >/dev/null 2>&1; then
        make_dependencies "$WORK_DIR/empty.d" | grep -vxF -- "$WORK_DIR/empty" || true
    fi
}

# check_look_reads <folder> <shipped looks folder> [<root file>]: refuse a
# look whose reading, from <root file> (the look's root by default), opened a
# file outside the look and the shipped looks folder other than through
# #include, as with #embed. The files the preprocessor reads for any input
# do not count.
check_look_reads() {
    local look_real file refused="" label
    local -A implicit=()
    look_real=$(realpath -e -- "$1")
    label=$(look_file_name "$1" "${3:-$1/root}")
    while IFS= read -r file; do
        implicit[$file]=1
    done < <(implicit_preprocessor_files)
    while IFS= read -r file; do
        if [ -n "${implicit[$file]+set}" ]; then
            continue
        fi
        if [ -z "${INCLUDED_FILES[$file]+set}" ] && ! allowed_look_file "$file" "$look_real" "$2"; then
            look_error "$label: reading the look opens $file, which is outside the look and $DEFAULT_LOOK_ROOT"
            refused=1
        fi
    done < <(make_dependencies "$WORK_DIR/depends")
    [ -z "$refused" ]
}

# read_display_symbols: in the X11 session, set DISPLAY_SYMBOLS to the macros
# xrdb defines from the session's display, as xrdb -symbols lists them, and
# SESSION_DISPLAY to 1 when the display answered
DISPLAY_SYMBOLS=""
SESSION_DISPLAY=""
read_display_symbols() {
    local line symbol
    DISPLAY_SYMBOLS=""
    SESSION_DISPLAY=""
    if [ "${XDG_SESSION_TYPE-}" == "wayland" ] || [ -z "${DISPLAY-}" ]; then
        return 0
    fi
    if ! timeout 10 xrdb -symbols </dev/null >"$WORK_DIR/display-symbols" 2>/dev/null; then
        return 0
    fi
    SESSION_DISPLAY=1
    while IFS= read -r line; do
        [[ "$line" == -D* ]] || continue
        symbol=${line#-D}
        symbol=${symbol%%=*}
        if [[ "$symbol" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            DISPLAY_SYMBOLS+=" $symbol"
        fi
    done <"$WORK_DIR/display-symbols"
}

# check_look_symbols <folder>: refuse a look that tests or uses a macro xrdb
# defines in the X11 session only, as the X11 session could then read other
# resources from it than the ones checked: the macros xrdb defines on every
# display, and the ones it defines on the session's display
check_look_symbols() {
    local symbol used pattern symbols
    local -a defines=()
    symbols=$(printf '%s\n' $XRDB_SYMBOLS $DISPLAY_SYMBOLS | LC_ALL=C sort -u | tr '\n' ' ')
    symbols=${symbols% }
    for symbol in $symbols; do
        defines+=("-D$symbol")
    done
    if ! preprocess_look "$1" -dU "${defines[@]}" >"$WORK_DIR/symbols" 2>/dev/null; then
        look_error "root: the look does not read cleanly in the X11 session"
        return 1
    fi
    # -dU lists the macros the reading expanded or tested
    pattern="^#(define|undef) (${symbols// /|}|(${XRDB_SYMBOL_PREFIXES// /|})[A-Za-z0-9_]*)([ (]|\$)"
    used=$(grep -m 1 -oE "$pattern" "$WORK_DIR/symbols") || true
    if [ -n "$used" ]; then
        used=${used#* }
        look_error "root: the look tests or uses ${used%[ (]}, which xrdb defines from the display in the X11 session"
        return 1
    fi
}

# Set REPLY to the resource name <spec> as the resource manager keeps it: a
# run of bindings is loose ('*') when it holds a '*' and tight ('.')
# otherwise, and a leading tight binding is dropped
xrm_canonical_name() {
    local spec=$1 run component
    REPLY=""
    while [ -n "$spec" ]; do
        run=${spec%%[!.*]*}
        spec=${spec#"$run"}
        component=${spec%%[.*]*}
        spec=${spec#"$component"}
        if [[ "$run" == *"*"* ]]; then
            REPLY+="*"
        elif [ -n "$run" ] && [ -n "$REPLY" ]; then
            REPLY+="."
        fi
        REPLY+=$component
    done
}

# xrm_wildcard <name>: whether a canonical resource name has a loose binding
# or a '?' component, which match other names
xrm_wildcard() {
    [[ "$1" == *"*"* ]] || [[ ".$1." =~ [.*]\?[.*] ]]
}

# xrm_name_regex <name>: set REPLY to an extended regular expression that
# matches the resource names a lookup of which the resource manager answers
# with an entry for the canonical resource name <name>: a loose binding
# stands for any number of components, '?' for any one. Fails for a
# component that is neither '?' nor a plain word, which no resource name of
# the window manager configuration has.
xrm_name_regex() {
    local name=$1 binding component part first=1
    REPLY="^"
    while [ -n "$name" ]; do
        binding="."
        case "$name" in
            "*"*) binding="*"; name=${name:1} ;;
            .*) name=${name:1} ;;
        esac
        component=${name%%[.*]*}
        name=${name#"$component"}
        if [ "$component" == "?" ]; then
            part="[^.]+"
        elif [[ "$component" =~ ^[A-Za-z0-9_-]+$ ]]; then
            part=$component
        else
            return 1
        fi
        if [ "$binding" == "*" ]; then
            part="([^.]+\\.)*$part"
        fi
        if [ -z "$first" ]; then
            part="\\.$part"
        fi
        REPLY+=$part
        first=""
    done
    REPLY+="\$"
}

# Print "<resource> <use>" for each resource the window manager configuration
# reads with set_from_resource and each way it puts the value into its
# configuration:
#   read     every resource it reads, wherever the value goes
#   path     in the file name of an include line
#   key      in the key of a bindsym or bindcode line
#   shell    after exec or exec_always, or in a bar's status command, where a
#            shell reads it
#   command  anywhere else: a directive, or a command of the window manager
# The configuration is the installed one and the user's own partials, which
# it includes. A variable that set copies from a resource variable stands for
# the same resources. A variable stands for the longest variable name it
# starts with, as i3 and sway replace them.
wm_resource_uses() {
    local -a files=()
    mapfile -d '' -t files < <(find -L /etc/regolith /usr/share/regolith \
        "$HOME/.config/regolith3/common-wm/config.d" "$HOME/.config/regolith3/i3/config.d" \
        "$HOME/.config/regolith3/sway/config.d" -type f -print0 2>/dev/null | LC_ALL=C sort -z)
    if [ "${#files[@]}" -eq 0 ]; then
        return 0
    fi
    LC_ALL=C awk '
        # the longest defined variable that <s> starts with
        function variable(s,   n) {
            for (n = length(s); n > 0; n--) {
                if (substr(s, 1, n) in defined) {
                    return substr(s, 1, n)
                }
            }
            return ""
        }
        # give variable <to> the resources of every variable in <s>
        function copy(to, s,   v, k, p) {
            while (match(s, /\$[A-Za-z0-9_.-]+/)) {
                v = variable(substr(s, RSTART + 1, RLENGTH - 1))
                s = substr(s, RSTART + RLENGTH)
                for (k in reads) {
                    split(k, p, SUBSEP)
                    if (p[1] == v) {
                        reads[to, p[2]] = 1
                    }
                }
            }
        }
        FNR == 1 && FILENAME == first { pass++ }
        FNR == 1 && pass == 0 { first = FILENAME; pass = 1 }
        { line = $0; sub(/^[ \t]+/, "", line) }
        line == "" || line ~ /^#/ { next }
        pass == 1 && $1 == "set_from_resource" && $2 ~ /^\$/ {
            defined[substr($2, 2)] = 1
            reads[substr($2, 2), $3] = 1
            print $3, "read"
            next
        }
        pass == 1 && $1 == "set" && $2 ~ /^\$/ { defined[substr($2, 2)] = 1; next }
        pass == 2 && $1 == "set" && $2 ~ /^\$/ {
            rest = line
            sub(/^[^ \t]+[ \t]+[^ \t]+/, "", rest)
            copy(substr($2, 2), rest)
            next
        }
        pass == 3 && $1 != "set_from_resource" && $1 != "set" {
            key_start = 0; key_end = 0; shell = 0
            if ($1 == "bindsym" || $1 == "bindcode") {
                rest = line; offset = 0
                match(rest, /^[^ \t]+[ \t]+/); offset += RLENGTH; rest = substr(rest, RLENGTH + 1)
                while (match(rest, /^--[^ \t]*[ \t]+/)) { offset += RLENGTH; rest = substr(rest, RLENGTH + 1) }
                match(rest, /^[^ \t]+/); key_start = offset + 1; key_end = offset + RLENGTH
            }
            if ($1 == "status_command" || $1 == "i3bar_command" || $1 == "swaybg_command" || $1 == "swaynag_command") {
                shell = 1
            } else if (match(line, /(^|[ \t])exec(_always)?([ \t]|$)/)) {
                shell = RSTART + 1
            }
            s = line; base = 0
            while (match(s, /\$[A-Za-z0-9_.-]+/)) {
                at = base + RSTART
                v = variable(substr(s, RSTART + 1, RLENGTH - 1))
                base += RSTART + RLENGTH - 1
                s = substr(s, RSTART + RLENGTH)
                if (v == "") {
                    continue
                }
                if ($1 == "include") {
                    use = "path"
                } else if (key_start && at >= key_start && at <= key_end) {
                    use = "key"
                } else if (shell && at > shell) {
                    use = "shell"
                } else {
                    use = "command"
                }
                for (k in reads) {
                    split(k, p, SUBSEP)
                    if (p[1] == v) {
                        print p[2], use
                    }
                }
            }
        }
    ' "${files[@]}" "${files[@]}" "${files[@]}" | LC_ALL=C sort -u
}

# Characters a value may hold where the window manager configuration puts it
# into a shell command line, and where it puts it into a file name. Spelled
# out: outside the C locale a range such as a-z can match other letters too.
SHELL_WORD_CHARS="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/:+=%@~-"
FILE_NAME_CHARS="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"

# value_fits_use <use> <value>: whether the window manager reads <value>
# only as the value it stands for where it uses it as <use> (see
# wm_resource_uses). In any use a value must not end a command or start
# another (';', ',', a line break or a control character), make the window
# manager expand a variable ('$'), or carry an escape the resource manager
# turns into such a character ('\'); nor may it hold the brackets that open
# and close criteria and blocks.
value_fits_use() {
    local value=$2
    case "$value" in
        *[[:cntrl:]\;,\$\\\`\[\]\{\}]*) return 1 ;;
    esac
    case "$1" in
        key) [[ "$value" != *[[:space:]]* ]] ;;
        shell) [ -z "${value//["$SHELL_WORD_CHARS"]/}" ] ;;
        path) [ -z "${value//["$FILE_NAME_CHARS"]/}" ] && [[ "$value" != .* ]] ;;
        *) return 0 ;;
    esac
}

# Where the window manager configuration puts a value, for error messages
declare -A VALUE_USE_TEXT=(
    [path]="the name of a file it includes"
    [key]="a key binding"
    [shell]="a shell command"
    [command]="a window manager command"
)

# shipped_loader <value> <shipped looks folder>: whether a loader value names
# an ordinary file directly in the shipped looks folder (given resolved). An
# empty value names no loader.
shipped_loader() {
    local value=$1 real
    value=${value%"${value##*[![:blank:]]}"}
    if [ -z "$value" ]; then
        return 0
    fi
    [[ "$value" == /* ]] && [[ "$value" != *\\* ]] || return 1
    real=$(realpath -e -- "$value" 2>/dev/null) || return 1
    [ -f "$real" ] && [ "${real%/*}" == "$2" ]
}

# check_look_resource_entries <shipped looks folder> [<file label>]: read the
# preprocessed resources of the look file <file label> (root by default) on
# stdin and refuse the ones a look may not set: a resource the
# window manager runs as a command, a loader that is not shipped, and a
# value that would change what the window manager configuration does where
# it puts the value. An entry with a loose binding or a '?' component counts
# for every resource it matches. Every entry that could supply the loader is
# judged, not only the one a lookup returns.
check_look_resource_entries() {
    local line spec value name regex resource use refused="" label=${2:-root}
    local -A uses=()
    while read -r resource use; do
        uses[$resource]+=" $use"
    done < <(wm_resource_uses)
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line#"${line%%[![:blank:]]*}"}
        case "$line" in
            "" | "!"*)
                continue
                ;;
            "#"*)
                # The resource manager reads files named by include lines too
                if [[ "$line" =~ ^#[[:blank:]]*include ]]; then
                    look_error "$label: the look includes a file through the resource manager: $line"
                    refused=1
                fi
                continue
                ;;
        esac
        # xrdb joins a line that ends in an unescaped backslash to the next
        if [[ "$line" =~ (^|[^\\])(\\\\)*\\$ ]]; then
            look_error "$label: a resource line continues onto the next line: $line"
            refused=1
            continue
        fi
        if [[ "$line" != *:* ]]; then
            continue
        fi
        name=${line%%:*}
        name=${name%"${name##*[![:blank:]]}"}
        spec=${name//[[:blank:]]/}
        value=${line#*:}
        value=${value#"${value%%[![:blank:]]*}"}
        if [[ "$spec" == *\\* ]]; then
            look_error "resource $spec: a resource name with a backslash"
            refused=1
            continue
        fi
        xrm_canonical_name "$spec"
        name=$REPLY
        if [ "$name" == "$WM_STATUS_COMMAND_RESOURCE" ] || [[ "$name" == "$WM_PROGRAM_RESOURCE_PREFIX"* ]]; then
            look_error "resource $spec: the window manager runs it as a command"
            refused=1
            continue
        fi
        regex=""
        if xrm_wildcard "$name"; then
            xrm_name_regex "$name" && regex=$REPLY
        fi
        if [ "$name" == "$LOOK_LOADER_RESOURCE" ] \
           || { [ -n "$regex" ] && [[ "$LOOK_LOADER_RESOURCE" =~ $regex ]]; }; then
            if ! shipped_loader "$value" "$1"; then
                look_error "resource $spec: $value is not a loader in $DEFAULT_LOOK_ROOT"
                refused=1
            fi
        fi
        for resource in "${!uses[@]}"; do
            if [ "$resource" != "$name" ] \
               && { [ -z "$regex" ] || [[ ! "$resource" =~ $regex ]]; }; then
                continue
            fi
            if [ "$resource" == "$WM_STATUS_COMMAND_RESOURCE" ] || [[ "$resource" == "$WM_PROGRAM_RESOURCE_PREFIX"* ]]; then
                look_error "resource $spec: matches $resource, which the window manager runs as a command"
                refused=1
                continue
            fi
            # The strictest use first, so that the message names it
            for use in path shell key command; do
                if [[ " ${uses[$resource]} " != *" $use "* ]] || value_fits_use "$use" "$value"; then
                    continue
                fi
                if [ "$resource" == "$name" ]; then
                    look_error "resource $spec: '$value' is not safe in ${VALUE_USE_TEXT[$use]}, where the window manager configuration puts it"
                else
                    look_error "resource $spec: matches $resource, and '$value' is not safe in ${VALUE_USE_TEXT[$use]}, where the window manager configuration puts it"
                fi
                refused=1
                break
            done
        done
    done
    [ -z "$refused" ]
}

# check_look_display_resources <folder> <shipped looks folder>: in the X11
# session, read the look as the session's xrdb does on its display, with the
# macros it defines from the display, and check those resources as well
check_look_display_resources() {
    if [ -z "$SESSION_DISPLAY" ]; then
        return 0
    fi
    if ! (
        ulimit -t 60 2>/dev/null || true
        ulimit -v 1048576 2>/dev/null || true
        ulimit -f 102400 2>/dev/null || true
        exec timeout 60 xrdb -n -load -cpp "$XRES_CPP" -I"$USER_XRESOURCE_SEARCH_PATH" -D"$LOOK_DIR_MACRO=$1" "$1/root"
    ) </dev/null >"$WORK_DIR/display-resources" 2>"$WORK_DIR/display-errors"; then
        look_error "root: the look does not read cleanly in the X11 session:"
        sed 's/^/    /' "$WORK_DIR/display-errors" >&2
        return 1
    fi
    check_look_resource_entries "$2" <"$WORK_DIR/display-resources"
}

# check_look_resources <folder>: read the look in its final folder as the
# session does, and refuse it when the reading fails or breaks a rule above
check_look_resources() {
    local shipped_real refused=""
    shipped_real=$(realpath -e -- "$DEFAULT_LOOK_ROOT")
    # -H lists the included files by level, -MD every file the reading opens
    if ! preprocess_look "$1" -H -MD -MF "$WORK_DIR/depends" -MT look \
            >"$WORK_DIR/resources" 2>"$WORK_DIR/includes"; then
        look_error "root: the look does not read cleanly:"
        sed 's/^/    /' "$WORK_DIR/includes" >&2
        return 1
    fi
    read_display_symbols
    check_look_includes "$1" "$shipped_real" <"$WORK_DIR/includes" || refused=1
    check_look_reads "$1" "$shipped_real" || refused=1
    check_look_symbols "$1" || refused=1
    check_look_resource_entries "$shipped_real" <"$WORK_DIR/resources" || refused=1
    if [ -z "$refused" ]; then
        check_look_display_resources "$1" "$shipped_real" || refused=1
    fi
    if [ -z "$refused" ]; then
        check_look_redirect "$1" "$shipped_real" || refused=1
    fi
    [ -z "$refused" ]
}

# trawl_entry_value <name> <resources>: set REPLY to the value trawl keeps for
# the resource <name> from the preprocessed <resources>: the last entry with
# exactly that name, its value trimmed. Fails when no entry has the name.
trawl_entry_value() {
    local line name found=""
    REPLY=""
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line#"${line%%[![:blank:]]*}"}
        case "$line" in
            "" | "!"* | "#"*) continue ;;
            *:*) ;;
            *) continue ;;
        esac
        name=${line%%:*}
        name=${name%"${name##*[![:blank:]]}"}
        [ "$name" == "$1" ] || continue
        REPLY=${line#*:}
        REPLY=${REPLY#"${REPLY%%[![:blank:]]*}"}
        REPLY=${REPLY%"${REPLY##*[![:blank:]]}"}
        found=1
    done <"$2"
    [ -n "$found" ]
}

# check_look_redirect <folder> <shipped looks folder>: the Wayland session
# reads the look twice, and the second time it looks regolith.look.path up in
# a database that already holds the look's own resources. Unless the Regolith
# Xresources set that resource again, a regolith.look.path in the look decides
# which root the second reading merges. Refuse a look that sends it outside
# the look and the shipped looks folder, and check a root it sends it to
# inside the look as the session reads that root, with LOOK_DIR_MACRO
# standing for that root's folder. There is no third reading.
check_look_redirect() {
    local look_real target dir label refused=""
    trawl_entry_value "regolith.look.path" "$WORK_DIR/resources" || return 0
    # An empty value reads as unset, which selects the default look
    if [ -z "$REPLY" ]; then
        return 0
    fi
    look_real=$(realpath -e -- "$1")
    target=""
    if [[ "$REPLY" == /* ]] && [[ "$REPLY" != *\\* ]]; then
        target=$(realpath -m -- "$REPLY")
    fi
    if [ "$target" == "$look_real" ] || [ "$target" == "$2" ] || [[ "$target" == "$2"/* ]]; then
        return 0
    fi
    if [[ "$target" != "$look_real"/* ]]; then
        look_error "resource regolith.look.path: $REPLY leads the Wayland session to read a look outside the look and $DEFAULT_LOOK_ROOT"
        return 1
    fi
    # The session reads that folder's root only when both exist
    if [ ! -d "$REPLY" ] || [ ! -f "$REPLY/root" ]; then
        return 0
    fi
    dir=$REPLY
    while [[ "$dir" == ?*/ ]]; do
        dir=${dir%/}
    done
    label=$(look_file_name "$1" "$dir/root")
    if ! preprocess_look "$dir" -H -MD -MF "$WORK_DIR/depends" -MT look \
            >"$WORK_DIR/redirect-resources" 2>"$WORK_DIR/redirect-includes"; then
        look_error "$label: the Wayland session reads it for regolith.look.path, and it does not read cleanly:"
        sed 's/^/    /' "$WORK_DIR/redirect-includes" >&2
        return 1
    fi
    check_look_includes "$1" "$2" "$dir/root" <"$WORK_DIR/redirect-includes" || refused=1
    check_look_reads "$1" "$2" "$dir/root" || refused=1
    check_look_resource_entries "$2" "$label" <"$WORK_DIR/redirect-resources" || refused=1
    [ -z "$refused" ]
}

# The look in use is the folder the session settles on at login: it merges
# ~/.Xresources, then the Regolith Xresources with Xresources.d searched for
# includes, and looks up regolith.look.path, using the default look when the
# value is not a folder. In the X11 session xrdb preprocesses the files with
# the macros it defines from the display, the resource manager answers the
# lookup, and xrescat drops surrounding double quotes. In the Wayland session
# trawl answers it, for the exact name only, and the session looks it up a
# second time after merging the look and the Regolith Xresources, so that the
# look itself can send it elsewhere (see check_look_redirect).

# resource_entries <file> [<cpp options>...]: print
# "<file>\t<line>\t<name>\t<value>" for each resource entry the session reads
# from <file>, with the file and line it comes from, which may be a file that
# <file> includes
resource_entries() {
    local file=$1
    shift
    { "$XRES_CPP" -w "$@" "$file" </dev/null 2>/dev/null || true; } | LC_ALL=C awk '
        # Line markers: # <line> "<file>" <flags>
        /^# [0-9]+ "/ {
            line = $2
            file = ""
            text = substr($0, index($0, "\"") + 1)
            for (i = 1; i <= length(text); i++) {
                c = substr(text, i, 1)
                if (c == "\"")
                    break
                if (c == "\\")
                    c = substr(text, ++i, 1)
                file = file c
            }
            next
        }
        {
            entry = $0
            sub(/^[ \t]+/, "", entry)
            colon = index(entry, ":")
            if (colon > 1 && entry !~ /^[!#]/ && file !~ /^</) {
                name = substr(entry, 1, colon - 1)
                sub(/[ \t]+$/, "", name)
                value = substr(entry, colon + 1)
                sub(/^[ \t]+/, "", value)
                printf "%s\t%d\t%s\t%s\n", file, line, name, value
            }
            line++
        }'
}

# Print the resource entries of the user's resource files, as resource_entries
# does, in the order the session merges them
selection_entries() {
    local line
    local -a defines=()
    if [ "$RESOURCE_GETTER" == "xrescat" ] && [ -n "${DISPLAY-}" ]; then
        while IFS= read -r line; do
            # xrdb -symbols quotes values for the shell; xrdb's cpp gets them bare
            if [[ "$line" =~ ^(-D[^=]*=)\"(.*)\"$ ]]; then
                line=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
            fi
            defines+=("$line")
        done < <(timeout 10 xrdb -symbols </dev/null 2>/dev/null || true)
    fi
    if [ -f "$BASELINE_XRESOURCE_FILE" ]; then
        resource_entries "$BASELINE_XRESOURCE_FILE" "${defines[@]}"
    fi
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        resource_entries "$USER_XRESOURCE_OVERRIDE_FILE" "${defines[@]}" -I"$USER_XRESOURCE_SEARCH_PATH"
    fi
}

# look_path_value <getter> <value>: set REPLY to <value> as the getter returns
# it: trawlcat trims it, xrescat drops a double quote from each end of a value
# that starts and ends with one (a lone quote leaves nothing)
look_path_value() {
    REPLY=$2
    if [ "$1" == "trawlcat" ]; then
        REPLY=${REPLY%"${REPLY##*[![:blank:]]}"}
    elif [[ "$REPLY" == \"*\" ]]; then
        REPLY=${REPLY:1:${#REPLY}-2}
    elif [ "$REPLY" == '"' ]; then
        REPLY=""
    fi
}

# names_look_folder <value> <folder>: whether the session, given the
# regolith.look.path value <value>, reads the look in <folder> (resolved)
names_look_folder() {
    [ -n "$1" ] && [ -d "$1" ] && [ "$(realpath -e -- "$1")" == "$2" ]
}

# look_path_match <name>: whether a lookup of regolith.look.path can return
# the entry <name>, with REPLY set to "exact" for an entry with that very
# name and to "wildcard" for one that matches it through a loose binding or
# a '?' component. trawl takes the exact name only.
look_path_match() {
    if [ "$RESOURCE_GETTER" == "trawlcat" ]; then
        REPLY=exact
        [ "$1" == "regolith.look.path" ]
        return
    fi
    xrm_canonical_name "${1//[[:blank:]]/}"
    if [ "$REPLY" == "regolith.look.path" ]; then
        REPLY=exact
    elif xrm_wildcard "$REPLY" && xrm_name_regex "$REPLY" \
            && [[ "regolith.look.path" =~ $REPLY ]]; then
        REPLY=wildcard
    else
        return 1
    fi
}

# split_entry <entry>: split a line of resource_entries into ENTRY_FILE,
# ENTRY_LINE, ENTRY_NAME and ENTRY_VALUE
split_entry() {
    local rest=$1
    ENTRY_FILE=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    ENTRY_LINE=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    ENTRY_NAME=${rest%%$'\t'*}
    ENTRY_VALUE=${rest#*$'\t'}
}

# look_in_use <folder>: whether the look in <folder> is the look in use. Sets
# LOOK_IN_USE_LINES to "<file>\t<line>" for each entry of the user's resource
# files that names it and that a lookup of regolith.look.path can return.
#
# An exactly named entry wins over every entry with a loose binding or a '?',
# and among exactly named entries the last one merged wins. Where only other
# entries match in the X11 session, the look counts as in use when one of them
# names it, without working out which one the resource manager prefers: at
# worst the session is rebuilt once more than needed, and a line naming a
# removed look goes.
declare -a LOOK_IN_USE_LINES=()
look_in_use() {
    local folder entry match names exact="" exact_set="" wildcard_names=""
    local -a entries=() all=()
    LOOK_IN_USE_LINES=()
    folder=$(realpath -e -- "$1") || return 1
    mapfile -t entries < <(selection_entries)
    for entry in "${entries[@]}"; do
        split_entry "$entry"
        all+=("$ENTRY_NAME" "$ENTRY_VALUE")
        look_path_match "$ENTRY_NAME" || continue
        match=$REPLY
        look_path_value "$RESOURCE_GETTER" "$ENTRY_VALUE"
        names=""
        if names_look_folder "$REPLY" "$folder"; then
            names=1
            LOOK_IN_USE_LINES+=("$ENTRY_FILE"$'\t'"$ENTRY_LINE")
        fi
        if [ "$match" == "exact" ]; then
            exact=$REPLY
            exact_set=1
        elif [ -n "$names" ]; then
            wildcard_names=1
        fi
    done
    if [ "$RESOURCE_GETTER" == "trawlcat" ]; then
        look_path_second_read "$exact" "${all[@]}" && names_look_folder "$REPLY" "$folder"
    elif [ -n "$exact_set" ]; then
        names_look_folder "$exact" "$folder"
    else
        [ -n "$wildcard_names" ]
    fi
}

# look_path_second_read <first value> <name> <value>...: the Wayland session
# reads the look twice, and the look it ends up with is the one the second
# lookup of regolith.look.path chooses. That lookup comes after the root that
# the first one (<first value>) chose, with LOOK_DIR_MACRO standing for its
# folder, and the Regolith Xresources have been merged on top of the user's
# entries, given in merge order. Set REPLY to the value it returns, or fail
# when it returns none.
look_path_second_read() {
    local dir=$1 entry value="" found="" i
    shift
    if [ ! -d "$dir" ]; then
        resolve_default_look_path
        dir=$DEFAULT_XRESOURCE_LOOK_PATH
    fi
    LOOK_STYLE_ROOT_FILE="$dir/root"
    resolve_look_style_dir
    local -a entries=("$@")
    while IFS= read -r entry; do
        split_entry "$entry"
        entries+=("$ENTRY_NAME" "$ENTRY_VALUE")
    done < <(
        if [ -f "$LOOK_STYLE_ROOT_FILE" ]; then
            resource_entries "$LOOK_STYLE_ROOT_FILE" -I"$USER_XRESOURCE_SEARCH_PATH" -D"$LOOK_DIR_MACRO=$LOOK_STYLE_DIR"
        fi
        if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
            resource_entries "$USER_XRESOURCE_OVERRIDE_FILE" -I"$USER_XRESOURCE_SEARCH_PATH"
        fi)
    for ((i = 0; i + 1 < ${#entries[@]}; i += 2)); do
        if [ "${entries[i]}" == "regolith.look.path" ]; then
            value=${entries[i + 1]}
            found=1
        fi
    done
    look_path_value trawlcat "$value"
    [ -n "$found" ]
}

# unset_look_in_use: delete the lines of LOOK_IN_USE_LINES from their files,
# every other byte as it is
unset_look_in_use() {
    local entry
    local -A scripts=()
    for entry in "${LOOK_IN_USE_LINES[@]}"; do
        scripts[${entry%$'\t'*}]+="${entry##*$'\t'}d;"
    done
    for entry in "${!scripts[@]}"; do
        sed --follow-symlinks -i -e "${scripts[$entry]}" -- "$entry"
    done
}

# install <source> [<name>]: fetch a look. Changes neither the look in use
# nor the session.
install_look() {
    local source=${1-} name dir
    if [ -z "$source" ]; then
        echo "Must specify a git repository to install a look from." >&2
        exit 1
    fi
    if [ "$#" -ge 2 ]; then
        name=$2
    else
        name=$(look_name_from_source "$source")
    fi
    if ! valid_look_name "$name"; then
        look_error "'$name' is not a valid look name: use 1 to 64 lower-case letters, digits, '.', '_' and '-', starting with a letter or a digit"
        exit 1
    fi
    LOOK_LABEL=$name
    dir="$USER_LOOK_ROOT/$name"
    lock_looks
    if [ -d "$DEFAULT_LOOK_ROOT/$name" ]; then
        look_error "a look named $name ships with the system in $DEFAULT_LOOK_ROOT"
        exit 1
    fi
    if [ -e "$dir" ] || [ -L "$dir" ]; then
        look_error "$dir already exists"
        exit 1
    fi

    make_work_dir "$name"
    fetch_look "$source"
    extract_look "$FETCHED_REVISION" "$WORK_DIR/look"
    # The look's files can name its folder, so check it in place
    place_look "$name"
    check_look_resources "$dir"
    commit_look "$name" "$source" "$FETCHED_REVISION"
    echo "$name"
}

# update_look <name>: move the fetched look to the newest revision of its
# source, keeping it as it is when the new one is refused
update_look() {
    local name=$1 dir="$USER_LOOK_ROOT/$1" source revision
    LOOK_LABEL=$name
    source=$(<"$INSTALLED_LOOK_STATE_DIR/$name/source")
    revision=$(<"$INSTALLED_LOOK_STATE_DIR/$name/revision")
    make_work_dir "$name"
    fetch_look "$source"
    if [ "$FETCHED_REVISION" != "$revision" ]; then
        extract_look "$FETCHED_REVISION" "$WORK_DIR/look"
        place_look "$name"
        check_look_resources "$dir"
        commit_look "$name" "$source" "$FETCHED_REVISION"
    fi
    echo "$name $FETCHED_REVISION"
}

# update [<name>]: update the fetched look <name>, or all of them in name
# order, going on past a failure. The session is rebuilt right after the look
# in use changed; whether a look is in use is settled before its update, as
# the new revision can change what the session reads. Interrupted, it stops
# after the look it is updating.
update_looks() {
    local name revision status failed=0 interrupted="" in_use=""
    local -a names=()
    lock_looks
    if [ "$#" -ge 1 ]; then
        if ! is_fetched_look "$1"; then
            echo "regolith-look: $1 is not a look installed with 'regolith-look install'" >&2
            exit 1
        fi
        names=("$1")
    else
        mapfile -t names < <(fetched_looks)
    fi
    trap 'interrupted=1' HUP INT TERM
    for name in "${names[@]}"; do
        revision=$(<"$INSTALLED_LOOK_STATE_DIR/$name/revision")
        in_use=""
        if look_in_use "$USER_LOOK_ROOT/$name"; then
            in_use=1
        fi
        # A subshell for each look: a failed update undoes itself on exit
        set +e
        (set -e; update_look "$name")
        status=$?
        set -e
        if [ "$status" -ne 0 ]; then
            failed=1
        elif [ "$(<"$INSTALLED_LOOK_STATE_DIR/$name/revision")" != "$revision" ] \
             && [ -n "$in_use" ]; then
            trap '' HUP INT TERM
            refresh_session
            trap 'interrupted=1' HUP INT TERM
        fi
        if [ -n "$interrupted" ]; then
            exit 1
        fi
    done
    exit "$failed"
}

# remove <name>: delete a fetched look. When it is the look in use, the
# entries that choose it leave the user's resource files and the session is
# rebuilt without it.
remove_look() {
    local name=${1-} dir in_use=""
    if [ -z "$name" ]; then
        echo "Must specify a look to remove." >&2
        exit 1
    fi
    lock_looks
    if ! is_fetched_look "$name"; then
        echo "regolith-look: $name is not a look installed with 'regolith-look install'" >&2
        exit 1
    fi
    dir="$USER_LOOK_ROOT/$name"
    if look_in_use "$dir"; then
        in_use=1
    fi
    # From here on the removal goes through to the end
    trap '' HUP INT TERM
    rm -rf -- "${INSTALLED_LOOK_STATE_DIR:?}/$name"
    rm -rf -- "$dir"
    if [ -n "$in_use" ]; then
        unset_look_in_use
        refresh_session
    fi
}

# list --installed: name, source and revision of each fetched look
list_installed_looks() {
    local name state
    while IFS= read -r name; do
        state="$INSTALLED_LOOK_STATE_DIR/$name"
        printf '%s\t%s\t%s\n' "$name" "$(<"$state/source")" "$(<"$state/revision")"
    done < <(fetched_looks)
}
