#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
BLUE='\e[34m'
MAGENTA='\e[35m'
CYAN='\e[36m'
BOLD='\e[1m'
DIM='\e[2m'
NC='\e[0m'

DIR="$(cd "$(dirname "$0")" && pwd)/supplement"
PACKAGES_CONF="$DIR/packages.conf"
CACHE_FILE="/tmp/omarchy_installer_$$"

# Detect the real user (for AUR support)
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
elif [[ -n "${DOAS_USER:-}" ]]; then
    REAL_USER="$DOAS_USER"
else
    REAL_USER="$(whoami)"
fi

# Cleanup on exit
cleanup() {
    rm -f "$CACHE_FILE"* 2>/dev/null || true
}
trap cleanup EXIT

# Cache of installed packages (built once at startup)
declare -A INSTALLED_CACHE

# Check for required tools
check_dependencies() {
    local missing=()
    command -v fzf >/dev/null || missing+=("fzf")
    command -v curl >/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required tools: ${missing[*]}${NC}"
        echo "Install with: sudo pacman -S ${missing[*]}"
        exit 1
    fi
}

# Check for AUR helper
get_aur_helper() {
    if command -v yay >/dev/null; then
        echo "yay"
    elif command -v paru >/dev/null; then
        echo "paru"
    else
        echo ""
    fi
}

# Load package metadata
declare -A PKG_CATEGORY PKG_DESC PKG_SOURCE PKG_CHECK

load_packages() {
    while IFS='|' read -r name category desc source check; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        PKG_CATEGORY["$name"]="$category"
        PKG_DESC["$name"]="$desc"
        PKG_SOURCE["$name"]="$source"
        # Use check field if provided, otherwise use script name
        # "-" means custom install, don't check pacman
        PKG_CHECK["$name"]="${check:-$name}"
    done < "$PACKAGES_CONF"
}

# Guess category based on package info
guess_category() {
    local pkg="$1"
    local desc="${2,,}"  # lowercase
    local groups="${3,,}"

    # Check groups first
    case "$groups" in
        *xfce*|*gnome*|*kde*|*plasma*) echo "system"; return ;;
        *font*) echo "terminal"; return ;;
    esac

    # Check package name patterns
    case "$pkg" in
        *-git|*-bin) ;;  # continue to description check
        *font*|*nerd*) echo "terminal"; return ;;
        *driver*|*nvidia*|*amd*|*intel*) echo "drivers"; return ;;
    esac

    # Check description
    case "$desc" in
        *terminal*emulator*|*shell*) echo "terminal"; return ;;
        *editor*|*ide*|*development\ environment*) echo "editor"; return ;;
        *compiler*|*debugger*|*linker*|*docker*|*container*|*git*|*version\ control*) echo "dev-tools"; return ;;
        *programming\ language*|*runtime*|*interpreter*|*java*|*python*|*node*|*rust*) echo "languages"; return ;;
        *driver*|*gpu*|*graphics*) echo "drivers"; return ;;
        *browser*|*web*browser*) echo "browser"; return ;;
        *game*|*fun*|*entertainment*|*animation*|*ascii*) echo "fun"; return ;;
        *system*|*daemon*|*service*|*network*|*filesystem*) echo "system"; return ;;
    esac

    # Default
    echo "utils"
}

# Fetch package info from Arch repos
fetch_pacman_info() {
    local pkg="$1"
    local info

    info=$(pacman -Si "$pkg" 2>/dev/null) || return 1

    local desc=$(echo "$info" | grep "^Description" | cut -d: -f2- | sed 's/^ *//')
    local groups=$(echo "$info" | grep "^Groups" | cut -d: -f2- | sed 's/^ *//')

    local category=$(guess_category "$pkg" "$desc" "$groups")

    echo "${category}|${desc}|pacman"
}

# Fetch package info from AUR
fetch_aur_info() {
    local pkg="$1"
    local response

    response=$(curl -s "https://aur.archlinux.org/rpc/?v=5&type=info&arg=$pkg" 2>/dev/null) || return 1

    # Check if package exists
    local resultcount=$(echo "$response" | grep -o '"resultcount":[0-9]*' | cut -d: -f2)
    [[ "$resultcount" != "1" ]] && return 1

    local desc=$(echo "$response" | grep -o '"Description":"[^"]*"' | cut -d'"' -f4)

    local category=$(guess_category "$pkg" "$desc" "")

    echo "${category}|${desc}|aur"
}

# Sync metadata for packages missing from packages.conf
sync_package_metadata() {
    local scripts
    mapfile -t scripts < <(get_scripts)

    local missing=()
    local added=0

    for pkg in "${scripts[@]}"; do
        if [[ -z "${PKG_CATEGORY[$pkg]:-}" ]]; then
            missing+=("$pkg")
        fi
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    echo -e "${CYAN}Fetching metadata for ${#missing[@]} new package(s)...${NC}"

    for pkg in "${missing[@]}"; do
        local info

        # Try pacman first, then AUR
        if info=$(fetch_pacman_info "$pkg"); then
            IFS='|' read -r category desc source <<< "$info"
        elif info=$(fetch_aur_info "$pkg"); then
            IFS='|' read -r category desc source <<< "$info"
        else
            # Fallback - couldn't find package info
            category="cli-utils"
            desc="No description available"
            source="pacman"
        fi

        # Add to packages.conf (with empty check field to use script name)
        echo "${pkg}|${category}|${desc}|${source}|" >> "$PACKAGES_CONF"

        # Update in-memory cache
        PKG_CATEGORY["$pkg"]="$category"
        PKG_DESC["$pkg"]="$desc"
        PKG_SOURCE["$pkg"]="$source"

        echo -e "  ${GREEN}+${NC} $pkg [${category}] (${source})"
        added=$((added + 1))
    done

    echo -e "${GREEN}Added $added package(s) to packages.conf${NC}"
    echo ""
}

# Build installed cache once
build_installed_cache() {
    local scripts
    mapfile -t scripts < <(get_scripts)

    # Get all installed packages in one pacman call
    local installed_list
    installed_list=$(pacman -Qq 2>/dev/null || true)

    for pkg in "${scripts[@]}"; do
        local check_pkg="${PKG_CHECK[$pkg]:-$pkg}"

        # "-" means custom install, assume not installed (or could check other ways)
        if [[ "$check_pkg" == "-" ]]; then
            INSTALLED_CACHE["$pkg"]="0"
        elif echo "$installed_list" | grep -qx "$check_pkg"; then
            INSTALLED_CACHE["$pkg"]="1"
        else
            INSTALLED_CACHE["$pkg"]="0"
        fi
    done

    # Write to cache file for generator script
    for pkg in "${!INSTALLED_CACHE[@]}"; do
        echo "$pkg:${INSTALLED_CACHE[$pkg]}"
    done > "${CACHE_FILE}_installed"
}

# Get available scripts
get_scripts() {
    find "$DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sed 's/\.sh$//' | sort
}

# Generate package list with current sort/filter
generate_package_list() {
    local sort_by="${1:-name}"
    local filter_cat="${2:-all}"

    mapfile -t scripts < <(get_scripts)

    # Filter by category
    local filtered=()
    for pkg in "${scripts[@]}"; do
        if [[ "$filter_cat" == "all" ]] || [[ "${PKG_CATEGORY[$pkg]:-}" == "$filter_cat" ]]; then
            filtered+=("$pkg")
        fi
    done

    # Sort packages
    local sorted=()
    case "$sort_by" in
        name)
            mapfile -t sorted < <(printf '%s\n' "${filtered[@]}" | sort)
            ;;
        category)
            mapfile -t sorted < <(
                for pkg in "${filtered[@]}"; do
                    echo "${PKG_CATEGORY[$pkg]:-zzz}|$pkg"
                done | sort | cut -d'|' -f2
            )
            ;;
        source)
            mapfile -t sorted < <(
                for pkg in "${filtered[@]}"; do
                    echo "${PKG_SOURCE[$pkg]:-pacman}|$pkg"
                done | sort | cut -d'|' -f2
            )
            ;;
        *)
            sorted=("${filtered[@]}")
            ;;
    esac

    # Format for display
    for pkg in "${sorted[@]}"; do
        local category="${PKG_CATEGORY[$pkg]:-unknown}"
        local source="${PKG_SOURCE[$pkg]:-pacman}"
        local desc="${PKG_DESC[$pkg]:-No description}"
        local installed=""

        if pacman -Qi "$pkg" &>/dev/null; then
            installed="✓"
        else
            installed="·"
        fi

        local source_badge=""
        [[ "$source" == "aur" ]] && source_badge="AUR"

        printf "%s  %-18s %-11s %-4s %s\n" "$installed" "$pkg" "[$category]" "$source_badge" "$desc"
    done
}

# Create the list generator script
create_list_generator() {
    cat > "${CACHE_FILE}_generator.sh" << 'GENEOF'
#!/usr/bin/env bash
DIR="$1"
PACKAGES_CONF="$DIR/packages.conf"
SORT_BY="${2:-name}"
FILTER_CAT="${3:-all}"
INSTALLED_CACHE_FILE="$4"
SELECTED_FILE="$5"

declare -A PKG_CATEGORY PKG_DESC PKG_SOURCE INSTALLED SELECTED

while IFS='|' read -r name category desc source check; do
    [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
    PKG_CATEGORY["$name"]="$category"
    PKG_DESC["$name"]="$desc"
    PKG_SOURCE["$name"]="$source"
done < "$PACKAGES_CONF"

# Load installed cache
while IFS=':' read -r pkg status; do
    INSTALLED["$pkg"]="$status"
done < "$INSTALLED_CACHE_FILE"

# Load selected packages
if [[ -f "$SELECTED_FILE" ]]; then
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && SELECTED["$pkg"]="1"
    done < "$SELECTED_FILE"
fi

mapfile -t scripts < <(find "$DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sed 's/\.sh$//' | sort)

filtered=()
for pkg in "${scripts[@]}"; do
    if [[ "$FILTER_CAT" == "all" ]] || [[ "${PKG_CATEGORY[$pkg]:-}" == "$FILTER_CAT" ]]; then
        filtered+=("$pkg")
    fi
done

case "$SORT_BY" in
    name)
        mapfile -t sorted < <(printf '%s\n' "${filtered[@]}" | sort)
        ;;
    category)
        mapfile -t sorted < <(
            for pkg in "${filtered[@]}"; do
                echo "${PKG_CATEGORY[$pkg]:-zzz}|$pkg"
            done | sort | cut -d'|' -f2
        )
        ;;
    source)
        mapfile -t sorted < <(
            for pkg in "${filtered[@]}"; do
                echo "${PKG_SOURCE[$pkg]:-pacman}|$pkg"
            done | sort | cut -d'|' -f2
        )
        ;;
    *)
        sorted=("${filtered[@]}")
        ;;
esac

for pkg in "${sorted[@]}"; do
    category="${PKG_CATEGORY[$pkg]:-unknown}"
    source="${PKG_SOURCE[$pkg]:-pacman}"
    desc="${PKG_DESC[$pkg]:-No description}"

    if [[ "${INSTALLED[$pkg]:-0}" == "1" ]]; then
        installed="✓"
    else
        installed="·"
    fi

    if [[ "${SELECTED[$pkg]:-}" == "1" ]]; then
        selected="●"
    else
        selected="○"
    fi

    source_badge=""
    [[ "$source" == "aur" ]] && source_badge="AUR"

    printf "%s %s  %-18s %-11s %-4s %s\n" "$selected" "$installed" "$pkg" "[$category]" "$source_badge" "$desc"
done
GENEOF
    chmod +x "${CACHE_FILE}_generator.sh"

    # Create toggle script for selections
    cat > "${CACHE_FILE}_toggle.sh" << 'TOGGLEEOF'
#!/usr/bin/env bash
pkg="$1"
selected_file="$2"

if grep -qx "$pkg" "$selected_file" 2>/dev/null; then
    grep -vx "$pkg" "$selected_file" > "${selected_file}.tmp" && mv "${selected_file}.tmp" "$selected_file"
else
    echo "$pkg" >> "$selected_file"
fi
TOGGLEEOF
    chmod +x "${CACHE_FILE}_toggle.sh"
}

# Create preview script
create_preview_script() {
    cat > "${CACHE_FILE}_preview.sh" << PREVEOF
#!/usr/bin/env bash
pkg=\$(echo "\$1" | awk '{print \$2}')
conf_file="$DIR/packages.conf"
cache_file="${CACHE_FILE}_installed"

if [[ -f "\$conf_file" ]]; then
    line=\$(grep "^\${pkg}|" "\$conf_file" 2>/dev/null || echo "")
    if [[ -n "\$line" ]]; then
        name=\$(echo "\$line" | cut -d'|' -f1)
        category=\$(echo "\$line" | cut -d'|' -f2)
        desc=\$(echo "\$line" | cut -d'|' -f3)
        source=\$(echo "\$line" | cut -d'|' -f4)

        echo -e "\033[1;35m\$name\033[0m"
        echo ""
        echo -e "\033[1mCategory:\033[0m \$category"
        echo -e "\033[1mSource:\033[0m \$source"
        echo -e "\033[1mDescription:\033[0m \$desc"
        echo ""

        if grep -q "^\$name:1" "\$cache_file" 2>/dev/null; then
            echo -e "\033[32m● INSTALLED\033[0m"
        else
            echo -e "\033[33m○ NOT INSTALLED\033[0m"
        fi
    fi
fi
PREVEOF
    chmod +x "${CACHE_FILE}_preview.sh"
}

# Install a single package (returns: 0=success, 1=failed, 2=skipped)
install_package() {
    local name="$1"
    local source="${PKG_SOURCE[$name]:-pacman}"
    local check_pkg="${PKG_CHECK[$name]:-$name}"
    local script="$DIR/${name}.sh"

    # Check if already installed
    if [[ "$check_pkg" != "-" ]] && pacman -Qi "$check_pkg" &>/dev/null; then
        echo -e "${YELLOW}  ⊘ $name is already installed, skipping${NC}"
        return 2
    fi

    if [[ "$source" == "aur" ]]; then
        local aur_helper
        aur_helper=$(get_aur_helper)

        if [[ -z "$aur_helper" ]]; then
            echo -e "${RED}  ✗ No AUR helper found (install yay or paru)${NC}"
            return 1
        fi

        echo -e "${CYAN}  → Installing $name from AUR (using $aur_helper as $REAL_USER)...${NC}"
        echo ""

        if sudo -u "$REAL_USER" "$aur_helper" -S --noconfirm "$name"; then
            echo ""
            echo -e "${GREEN}  ✓ $name installed successfully${NC}"
            return 0
        else
            echo ""
            echo -e "${RED}  ✗ $name installation failed${NC}"
            return 1
        fi
    else
        echo -e "${CYAN}  → Installing $name...${NC}"
        echo ""

        if [[ -f "$script" ]]; then
            if bash "$script"; then
                echo ""
                echo -e "${GREEN}  ✓ $name installed successfully${NC}"
                return 0
            else
                echo ""
                echo -e "${RED}  ✗ $name installation failed${NC}"
                return 1
            fi
        else
            if pacman -S --noconfirm "$name"; then
                echo ""
                echo -e "${GREEN}  ✓ $name installed successfully${NC}"
                return 0
            else
                echo ""
                echo -e "${RED}  ✗ $name installation failed${NC}"
                return 1
            fi
        fi
    fi
}

# Installation process
run_installation() {
    local packages=("$@")
    local total=${#packages[@]}
    local success=0
    local failed=0
    local skipped=0

    echo ""
    echo -e "${BOLD}Installing $total package(s)...${NC}"
    echo ""

    for i in "${!packages[@]}"; do
        local pkg="${packages[$i]}"
        local num=$((i + 1))

        echo -e "${BOLD}[$num/$total] $pkg${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"

        # Run install and capture exit code (output goes directly to terminal)
        # Temporarily disable set -e to capture non-zero exit codes
        set +e
        install_package "$pkg"
        local exit_code=$?
        set -e

        case "$exit_code" in
            0) success=$((success + 1)) ;;
            1) failed=$((failed + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
        esac

        echo ""
    done

    # Summary
    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "${BOLD}         Installation Complete          ${NC}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ Successful: $success${NC}"
    echo -e "${RED}  ✗ Failed: $failed${NC}"
    echo -e "${YELLOW}  ⊘ Skipped: $skipped${NC}"
    echo ""
}

# Build header with current state highlighted
build_header() {
    local sort="$1"
    local filter="$2"

    # Sort indicators - highlight current
    local s_name="name" s_cat="category" s_src="source"
    case "$sort" in
        name)     s_name="[NAME]" ;;
        category) s_cat="[CATEGORY]" ;;
        source)   s_src="[SOURCE]" ;;
    esac

    # Filter indicators - highlight current
    local f_all="0:all" f_term="1:terminal" f_edit="2:editor" f_dev="3:dev-tools"
    local f_lang="4:languages" f_drv="5:drivers" f_util="6:utils" f_browser="7:browser" f_fun="8:fun" f_sys="9:system"
    case "$filter" in
        all)       f_all="0:[ALL]" ;;
        terminal)  f_term="1:[TERMINAL]" ;;
        editor)    f_edit="2:[EDITOR]" ;;
        dev-tools) f_dev="3:[DEV-TOOLS]" ;;
        languages) f_lang="4:[LANGUAGES]" ;;
        drivers)   f_drv="5:[DRIVERS]" ;;
        utils)     f_util="6:[UTILS]" ;;
        browser)   f_browser="7:[BROWSER]" ;;
        fun)       f_fun="8:[FUN]" ;;
        system)    f_sys="9:[SYSTEM]" ;;
    esac

    echo "space:select  ctrl-a:all  ctrl-d:none  enter:install  esc:quit  tab:sort($s_name $s_cat $s_src)
$f_all $f_term $f_edit $f_dev $f_lang $f_drv $f_util $f_browser $f_fun $f_sys"
}

# Main package selector
select_packages() {
    create_list_generator
    create_preview_script

    local generator="${CACHE_FILE}_generator.sh"
    local preview="${CACHE_FILE}_preview.sh"
    local toggle="${CACHE_FILE}_toggle.sh"
    local installed_cache="${CACHE_FILE}_installed"
    local selected_file="${CACHE_FILE}_selected"

    # State files
    echo "name" > "${CACHE_FILE}_sort"
    echo "all" > "${CACHE_FILE}_filter"
    : > "$selected_file"  # Initialize empty

    # Create select-all script (toggles: if all selected, deselect; otherwise select remaining)
    cat > "${CACHE_FILE}_selectall.sh" << SELEOF
#!/usr/bin/env bash
DIR="$DIR"
selected_file="$selected_file"
filter="\$1"
packages_conf="$PACKAGES_CONF"

# Build list of packages in current filter
filtered=()
for script in "\$DIR"/*.sh; do
    pkg=\$(basename "\$script" .sh)
    if [[ "\$filter" == "all" ]]; then
        filtered+=("\$pkg")
    else
        category=\$(grep "^\${pkg}|" "\$packages_conf" 2>/dev/null | cut -d'|' -f2)
        [[ "\$category" == "\$filter" ]] && filtered+=("\$pkg")
    fi
done

# Check if all filtered packages are currently selected
all_selected=true
for pkg in "\${filtered[@]}"; do
    if ! grep -qx "\$pkg" "\$selected_file" 2>/dev/null; then
        all_selected=false
        break
    fi
done

if [[ "\$all_selected" == "true" && \${#filtered[@]} -gt 0 ]]; then
    # All are selected - remove them from selection
    for pkg in "\${filtered[@]}"; do
        grep -vx "\$pkg" "\$selected_file" > "\${selected_file}.tmp" 2>/dev/null && mv "\${selected_file}.tmp" "\$selected_file"
    done
else
    # Not all selected - add missing ones
    for pkg in "\${filtered[@]}"; do
        if ! grep -qx "\$pkg" "\$selected_file" 2>/dev/null; then
            echo "\$pkg" >> "\$selected_file"
        fi
    done
fi
SELEOF
    chmod +x "${CACHE_FILE}_selectall.sh"

    # Create header builder script
    cat > "${CACHE_FILE}_header.sh" << 'HEADEREOF'
#!/usr/bin/env bash
sort="$1"
filter="$2"

s_name="name" s_cat="category" s_src="source"
case "$sort" in
    name)     s_name="[NAME]" ;;
    category) s_cat="[CATEGORY]" ;;
    source)   s_src="[SOURCE]" ;;
esac

f_all="0:all" f_term="1:terminal" f_edit="2:editor" f_dev="3:dev-tools"
f_lang="4:languages" f_drv="5:drivers" f_util="6:utils" f_browser="7:browser" f_fun="8:fun" f_sys="9:system"
case "$filter" in
    all)       f_all="0:[ALL]" ;;
    terminal)  f_term="1:[TERMINAL]" ;;
    editor)    f_edit="2:[EDITOR]" ;;
    dev-tools) f_dev="3:[DEV-TOOLS]" ;;
    languages) f_lang="4:[LANGUAGES]" ;;
    drivers)   f_drv="5:[DRIVERS]" ;;
    utils)     f_util="6:[UTILS]" ;;
    browser)   f_browser="7:[BROWSER]" ;;
    fun)       f_fun="8:[FUN]" ;;
    system)    f_sys="9:[SYSTEM]" ;;
esac

echo "space:select  ctrl-a:all  ctrl-d:none  enter:install  esc:quit  tab:sort($s_name $s_cat $s_src)
$f_all $f_term $f_edit $f_dev $f_lang $f_drv $f_util $f_browser $f_fun $f_sys"
HEADEREOF
    chmod +x "${CACHE_FILE}_header.sh"

    local header_script="${CACHE_FILE}_header.sh"
    local selectall_script="${CACHE_FILE}_selectall.sh"
    local initial_header=$(build_header "name" "all")

    # Run fzf - using our own selection tracking instead of fzf's --multi
    "$generator" "$DIR" "name" "all" "$installed_cache" "$selected_file" | fzf \
        --ansi \
        --layout=reverse \
        --border none \
        --pointer "▶" \
        --color 'fg:252,hl:212,fg+:252,bg+:235,hl+:212' \
        --color 'info:144,prompt:212,spinner:212,pointer:212,marker:212,header:245' \
        --preview "bash '$preview' {}" \
        --preview-window 'right:30%:wrap' \
        --header "$initial_header" \
        --bind "space:execute-silent('$toggle' {3} '$selected_file')+reload('$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') \$(cat '${CACHE_FILE}_filter') '$installed_cache' '$selected_file')" \
        --bind "ctrl-a:execute-silent('$selectall_script' \$(cat '${CACHE_FILE}_filter'))+reload('$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') \$(cat '${CACHE_FILE}_filter') '$installed_cache' '$selected_file')" \
        --bind "ctrl-d:execute-silent(: > '$selected_file')+reload('$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') \$(cat '${CACHE_FILE}_filter') '$installed_cache' '$selected_file')" \
        --bind "tab:reload(
            sort=\$(cat '${CACHE_FILE}_sort');
            case \$sort in
                name) echo category > '${CACHE_FILE}_sort' ;;
                category) echo source > '${CACHE_FILE}_sort' ;;
                source) echo name > '${CACHE_FILE}_sort' ;;
            esac;
            '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') \$(cat '${CACHE_FILE}_filter') '$installed_cache' '$selected_file'
        )+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') \$(cat '${CACHE_FILE}_filter'))" \
        --bind "1:reload(echo terminal > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') terminal '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') terminal)" \
        --bind "2:reload(echo editor > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') editor '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') editor)" \
        --bind "3:reload(echo dev-tools > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') dev-tools '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') dev-tools)" \
        --bind "4:reload(echo languages > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') languages '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') languages)" \
        --bind "5:reload(echo drivers > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') drivers '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') drivers)" \
        --bind "6:reload(echo utils > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') utils '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') utils)" \
        --bind "7:reload(echo browser > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') browser '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') browser)" \
        --bind "8:reload(echo fun > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') fun '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') fun)" \
        --bind "9:reload(echo system > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') system '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') system)" \
        --bind "0:reload(echo all > '${CACHE_FILE}_filter'; '$generator' '$DIR' \$(cat '${CACHE_FILE}_sort') all '$installed_cache' '$selected_file')+transform-header('$header_script' \$(cat '${CACHE_FILE}_sort') all)" \
        > /dev/null || true

    # Return selections from our tracking file (package names only)
    cat "$selected_file" 2>/dev/null || true
}

# Main
main() {
    check_dependencies
    load_packages

    # Check if running as root for pacman operations
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This installer requires root privileges for pacman.${NC}"
        echo "Please run with: sudo $0"
        exit 1
    fi

    # Check AUR helper availability
    local aur_helper
    aur_helper=$(get_aur_helper)

    trap 'cleanup; echo -e "\n${RED}Installer aborted${NC}"; exit 130' SIGINT SIGTERM

    # Auto-fetch metadata for any new packages
    sync_package_metadata

    # Build installed cache once (fast - single pacman call)
    build_installed_cache

    # Run the selector immediately
    selected=$(select_packages)

    if [[ -z "$selected" ]]; then
        echo ""
        echo -e "${MAGENTA}No packages selected. Goodbye!${NC}"
        exit 0
    fi

    # Package names are returned directly (one per line)
    mapfile -t selected_arr <<< "$selected"

    echo ""
    echo -e "${BOLD}Selected ${#selected_arr[@]} package(s):${NC}"
    for pkg in "${selected_arr[@]}"; do
        echo -e "  ${CYAN}•${NC} $pkg"
    done
    echo ""

    read -p "Proceed with installation? [Y/n] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        run_installation "${selected_arr[@]}"
    else
        echo -e "${YELLOW}Installation cancelled.${NC}"
    fi

    echo -e "${MAGENTA}Thanks for using Omarchy Installer!${NC}"
}

main "$@"
