#!/bin/bash

# no-npm: blocks package managers and redirects to your preferred one
# read this before running it

set -euo pipefail

DRY_RUN=false
DEFAULT_PM="bun"
DEFAULT_BLOCKED="npm"

# colors
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

err() { echo -e "${R}$1${N}"; }
ok() { echo -e "${G}$1${N}"; }
warn() { echo -e "${Y}$1${N}"; }

# detect shell config
detect_shell() {
    case "${SHELL##*/}" in
        zsh) echo "$HOME/.zshrc" ;;
        bash)
            [[ -f "$HOME/.bashrc" ]] && echo "$HOME/.bashrc" || echo "$HOME/.bash_profile"
            ;;
        *) echo "$HOME/.profile" ;;
    esac
}

# generate the guard script
generate_guard() {
    local pm="$1"
    local blocked="$2"

    # map commands based on preferred pm
    local install_cmd="$pm install"
    local add_cmd="$pm add"
    local remove_cmd="$pm remove"
    local run_cmd="$pm run"

    case "$pm" in
        npm)
            add_cmd="npm install"
            remove_cmd="npm uninstall"
            ;;
        pnpm)
            add_cmd="pnpm add"
            ;;
        yarn)
            remove_cmd="yarn remove"
            ;;
    esac

    cat << EOF
# no-npm guard: blocks $blocked, suggests $pm

_${pm}_equiv() {
    local cmd="\$1"
    shift
    local sub="\$1"

    case "\$sub" in
        ""|install|i)
            if [[ \$# -le 1 ]]; then
                echo "$install_cmd"
            else
                shift
                echo "$add_cmd \$*"
            fi
            ;;
        add)
            shift
            echo "$add_cmd \$*"
            ;;
        remove|rm|uninstall)
            shift
            echo "$remove_cmd \$*"
            ;;
        run)
            shift
            echo "$run_cmd \$*"
            ;;
        *)
            echo "$pm \$sub \${*:2}"
            ;;
    esac
}

$blocked() {
    local equiv="\$(_${pm}_equiv $blocked "\$@")"
    echo "dont use $blocked. use $pm instead: \$equiv"
    return 1
}
EOF
}

# parse args
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

if [[ "$DRY_RUN" == "true" ]]; then
    warn "dry run mode - nothing will be modified"
    echo
fi

# interactive prompts
read -p "preferred package manager (bun/pnpm/yarn/npm) [$DEFAULT_PM]: " pm
pm="${pm:-$DEFAULT_PM}"

read -p "which to block (comma-separated) [$DEFAULT_BLOCKED]: " blocked
blocked="${blocked:-$DEFAULT_BLOCKED}"

config=$(detect_shell)
read -p "shell config to modify [$config]: " user_config
config="${user_config:-$config}"

# summary
echo
echo "will do:"
echo "  preferred: $pm"
echo "  blocked: $blocked"
echo "  config: $config"
echo

read -p "continue? (y/n): " confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "cancelled"; exit 0; }

# dry run: use temp files
if [[ "$DRY_RUN" == "true" ]]; then
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    config="$temp_dir/$(basename $config)"
    guard_file="$temp_dir/.${pm}_guard.sh"
    touch "$config"
else
    guard_file="$HOME/.${pm}_guard.sh"

    # backup config if it exists
    if [[ -f "$config" ]]; then
        backup="${config}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$config" "$backup"
        ok "backed up: $backup"
    fi
fi

# generate guard script
generate_guard "$pm" "$blocked" > "$guard_file"
chmod +x "$guard_file"

# add to config if not already there
if ! grep -q "no-npm guard" "$config" 2>/dev/null; then
    echo "" >> "$config"
    echo "# no-npm guard" >> "$config"
    echo "[ -f $guard_file ] && source $guard_file" >> "$config"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    ok "dry run complete - here's what was generated:"
    echo
    echo "--- guard script ---"
    cat "$guard_file"
    echo
    echo "--- config addition ---"
    tail -3 "$config"
else
    ok "installed"
    echo "restart your shell or: source $config"
    echo "to uninstall: remove $guard_file and the lines from $config"
fi
