#!/bin/bash

# no-npm installer
# Blocks package managers and redirects to preferred one

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Defaults
DEFAULT_PM="bun"
DEFAULT_PREFERRED_PM="bun"
BLOCKED_PMS="npm"
DEFAULT_BLOCKED_PMS="npm"
# AI agents typically run from IDE terminals with these TERM values
DEFAULT_BLOCKED_TERMS="xterm-256color,xterm-ghostty,screen-256color,tmux-256color"
DRY_RUN=false
FORCE=false
UNINSTALL=false
VERIFY=false

# Track backups
declare -a BACKUPS
declare -a BACKUPS_CREATED
FAILED=false
INSTALL_FAILED=false
VERIFY_MODE=false
UNINSTALL_MODE=false

print_err() { echo -e "${RED}Error: $1${NC}"; }
print_error() { echo -e "${RED}Error: $1${NC}"; }
print_ok() { echo -e "${GREEN}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_info() { echo -e "$1"; }
print_warn() { echo -e "${YELLOW}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Show warning
show_disclaimer() {
    echo
    echo -e "${RED}WARNING: This will modify your shell config${NC}"
    echo -e "${YELLOW}Author note: I suck at bash${NC}"
    echo -e "${RED}║${NC} While this script has been tested, there may be bugs that could    ${RED}║${NC}"
    echo -e "${RED}║${NC} potentially break your shell configuration. A broken shell config  ${RED}║${NC}"
    echo -e "${RED}║${NC} can prevent you from logging in or using your terminal properly.   ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                                    ${RED}║${NC}"
    echo -e "${RED}║${NC} ${GREEN}SAFETY MEASURES:${NC}                                                  ${RED}║${NC}"
    echo -e "${RED}║${NC}  • All modified files will be backed up automatically              ${RED}║${NC}"
    echo -e "${RED}║${NC}  • Backups are saved as: filename.bak.<timestamp>                  ${RED}║${NC}"
    echo -e "${RED}║${NC}  • Use --dry-run to test on dummy files first                      ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                                    ${RED}║${NC}"
    echo -e "${YELLOW}No warranty. Use at your own risk.${NC}"
    echo
}

# Function to require explicit acceptance
require_acceptance() {
    show_disclaimer
    read -p "Type 'accept' to continue: " acceptance
    if [[ "$acceptance" != "accept" ]]; then
        print_err "Must type 'accept'"
        exit 1
    fi
    echo
}

# Function to display help
show_help() {
    cat << 'EOF'
Usage: install.sh [options]
Options:
  --dry-run     Test with temp files
  --force       Overwrite existing
  --uninstall   Remove everything
  --verify      Check script integrity
  --checksum    Verify installer
  --help        Show this

Example: ./install.sh --dry-run
         ./install.sh --verify

SAFETY:
    - All modified files are backed up as: filename.bak.<timestamp>
    - You must type 'accept' to confirm you understand the risks
    - Use --dry-run first to test on your system without risk
    - Automatic rollback on failure

CHECKSUM VERIFICATION (for curl|bash installs):
    curl -sSL <url> -o install.sh
    shasum -a 256 install.sh  # Compare with published checksum
    bash install.sh

EOF
}

# Function to rollback on failure
rollback_on_failure() {
    if [[ "$INSTALL_FAILED" == "true" ]]; then
        echo
        print_error "Installation failed! Attempting automatic rollback..."
        
        local rollback_success=true
        for i in "${!BACKUPS_CREATED[@]}"; do
            local backup="${BACKUPS_CREATED[$i]}"
            # Extract original filename from backup (remove .bak.timestamp)
            local original=$(echo "$backup" | sed 's/\.bak\.[0-9]*$//')
            
            if [[ -f "$backup" ]]; then
                print_info "Restoring: $original from $backup"
                if cp "$backup" "$original"; then
                    print_success "Restored: $original"
                else
                    print_error "Failed to restore: $original"
                    rollback_success=false
                fi
            fi
        done
        
        if [[ "$rollback_success" == "true" ]]; then
            print_success "Rollback completed successfully!"
            print_info "Your system has been restored to its previous state."
        else
            print_error "Rollback had errors. Please manually restore from backups:"
            for backup in "${BACKUPS_CREATED[@]}"; do
                echo "  - $backup"
            done
        fi
    fi
}

# Function to verify a shell script syntax
verify_script_syntax() {
    local script_file="$1"
    local script_name="$2"
    
    print_info "Verifying syntax of $script_name..."
    
    if bash -n "$script_file" 2>/dev/null; then
        print_success "Syntax OK: $script_name"
        return 0
    else
        print_error "Syntax error in $script_name!"
        print_info "Running detailed syntax check:"
        bash -n "$script_file" 2>&1 | head -10
        return 1
    fi
}

# Function to verify generated guard script before sourcing
verify_guard_script() {
    local guard_file="$1"
    local preferred_pm="$2"
    
    print_info "Verifying guard script integrity..."
    
    # Check syntax
    if ! verify_script_syntax "$guard_file" "guard script"; then
        return 1
    fi
    
    # Check for required functions
    local required_functions=("_${preferred_pm}_equiv" "_${preferred_pm}_warn")
    for func in "${required_functions[@]}"; do
        if ! grep -q "^${func}()" "$guard_file" 2>/dev/null; then
            # Also check without ^ anchor for indented functions
            if ! grep -q "${func}()" "$guard_file" 2>/dev/null; then
                print_error "Missing required function: $func"
                return 1
            fi
        fi
    done
    
    # Check file is not empty
    if [[ ! -s "$guard_file" ]]; then
        print_error "Guard script is empty!"
        return 1
    fi
    
    # Check file size is reasonable (not truncated, not huge)
    local file_size=$(wc -c < "$guard_file")
    if [[ $file_size -lt 500 ]]; then
        print_error "Guard script seems too small ($file_size bytes). Possibly truncated."
        return 1
    fi
    if [[ $file_size -gt 50000 ]]; then
        print_error "Guard script seems too large ($file_size bytes). Something went wrong."
        return 1
    fi
    
    print_success "Guard script verification passed"
    return 0
}

# Function to validate config file path
validate_config_file() {
    local config_file="$1"
    
    print_info "Validating config file: $config_file"
    
    # Check if path is absolute
    if [[ "$config_file" != /* ]]; then
        print_error "Config file path must be absolute (start with /)"
        return 1
    fi
    
    # Check if parent directory exists
    local parent_dir=$(dirname "$config_file")
    if [[ ! -d "$parent_dir" ]]; then
        print_error "Parent directory does not exist: $parent_dir"
        return 1
    fi
    
    # Check if parent directory is writable
    if [[ ! -w "$parent_dir" ]]; then
        print_error "Parent directory is not writable: $parent_dir"
        return 1
    fi
    
    # If file exists, check if it's writable
    if [[ -f "$config_file" ]]; then
        if [[ ! -w "$config_file" ]]; then
            print_error "Config file exists but is not writable: $config_file"
            return 1
        fi
        
        # Check if it's a regular file (not a symlink to something weird)
        if [[ -L "$config_file" ]]; then
            local target=$(readlink -f "$config_file" 2>/dev/null || readlink "$config_file")
            print_warning "Config file is a symlink pointing to: $target"
            read -p "Continue with symlinked config? (y/N): " confirm_symlink
            if [[ ! "$confirm_symlink" =~ ^[Yy]$ ]]; then
                print_info "Cancelled due to symlink."
                return 1
            fi
        fi
        
        # Check file is readable
        if [[ ! -r "$config_file" ]]; then
            print_error "Config file is not readable: $config_file"
            return 1
        fi
    fi
    
    print_success "Config file validation passed"
    return 0
}

# Function to verify installer checksum (for curl|bash security)
verify_installer_checksum() {
    local expected_checksum="$1"
    
    if [[ -z "$expected_checksum" ]]; then
        print_warning "No checksum provided. Skipping integrity verification."
        print_info "For better security, download the script and verify manually:"
        print_info "  curl -sSL <url> -o install.sh"
        print_info "  shasum -a 256 install.sh"
        return 0
    fi
    
    print_info "Verifying installer integrity..."
    
    # Get the script's own path
    local script_path="${BASH_SOURCE[0]}"
    
    if [[ ! -f "$script_path" ]]; then
        print_warning "Cannot verify checksum: script path not found"
        return 0
    fi
    
    local actual_checksum
    if command -v shasum >/dev/null 2>&1; then
        actual_checksum=$(shasum -a 256 "$script_path" | cut -d' ' -f1)
    elif command -v sha256sum >/dev/null 2>&1; then
        actual_checksum=$(sha256sum "$script_path" | cut -d' ' -f1)
    else
        print_warning "Neither shasum nor sha256sum found. Cannot verify checksum."
        return 0
    fi
    
    if [[ "$actual_checksum" == "$expected_checksum" ]]; then
        print_success "Checksum verified: $actual_checksum"
        return 0
    else
        print_error "Checksum mismatch!"
        print_error "Expected: $expected_checksum"
        print_error "Actual:   $actual_checksum"
        print_error "The installer may have been tampered with. Aborting."
        exit 1
    fi
}

# Function to detect shell and config file
detect_shell() {
    local shell_name=""
    local config_file=""

    # Prefer the user's declared login shell when available
    local shell_basename="${SHELL##*/}"
    case "$shell_basename" in
        zsh)
            shell_name="zsh"
            config_file="$HOME/.zshrc"
            ;;
        bash)
            shell_name="bash"
            if [[ -f "$HOME/.bashrc" ]]; then
                config_file="$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                config_file="$HOME/.bash_profile"
            else
                config_file="$HOME/.bashrc"
            fi
            ;;
        *)
            # Fallback to runtime detection if SHELL is ambiguous
            if [[ -n "${ZSH_VERSION:-}" ]]; then
                shell_name="zsh"
                config_file="$HOME/.zshrc"
            elif [[ -n "${BASH_VERSION:-}" ]]; then
                shell_name="bash"
                if [[ -f "$HOME/.bashrc" ]]; then
                    config_file="$HOME/.bashrc"
                elif [[ -f "$HOME/.bash_profile" ]]; then
                    config_file="$HOME/.bash_profile"
                else
                    config_file="$HOME/.bashrc"
                fi
            else
                shell_name="unknown"
                config_file="$HOME/.profile"
            fi
            ;;
    esac

    echo "$shell_name:$config_file"
}

# Function to validate package manager choice
validate_pm() {
    local pm="$1"
    case "$pm" in
        bun|pnpm|yarn|npm)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if guard is already installed
is_guard_installed() {
    local preferred_pm="$1"
    local guard_file="$HOME/.${preferred_pm}_guard.sh"
    [[ -f "$guard_file" ]]
}

# Function to backup any file before modification (MANDATORY)
backup_file() {
    local file_path="$1"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [[ ! -f "$file_path" ]]; then
        print_info "File does not exist yet, no backup needed: $file_path"
        return 0
    fi
    
    local backup_file="${file_path}.bak.${timestamp}"
    
    print_info "Creating mandatory backup: $backup_file"
    cp "$file_path" "$backup_file"
    
    if [[ $? -eq 0 ]]; then
        print_success "Backup created: $backup_file"
        BACKUPS_CREATED+=("$backup_file")
        return 0
    else
        print_error "Failed to create backup! Aborting for safety."
        exit 1
    fi
}

# Function to prompt user for mandatory backup
prompt_mandatory_backup() {
    local file_path="$1"
    
    if [[ ! -f "$file_path" ]]; then
        print_info "File will be created: $file_path"
        return 0
    fi
    
    echo
    print_warning "The following file will be modified: $file_path"
    print_info "A backup is REQUIRED before proceeding. There is no skip option."
    echo
    read -p "Press Enter to backup '$file_path': " _unused
    
    backup_file "$file_path"
}

# Legacy wrapper for compatibility
backup_config() {
    local config_file="$1"
    prompt_mandatory_backup "$config_file"
}

# Function to setup dry-run environment with real temp files
setup_dry_run_environment() {
    DRY_RUN_TEMP_DIR=$(mktemp -d)
    print_info "DRY RUN: Creating test environment in $DRY_RUN_TEMP_DIR"
    print_info "DRY RUN: This will perform REAL operations on DUMMY files"
    print_info "DRY RUN: Your actual config files will NOT be touched"
    echo
    
    # Copy actual shell config to temp dir for realistic testing
    local shell_info
    shell_info=$(detect_shell)
    local real_config="${shell_info##*:}"
    
    if [[ -f "$real_config" ]]; then
        local config_basename=$(basename "$real_config")
        cp "$real_config" "$DRY_RUN_TEMP_DIR/$config_basename"
        print_info "DRY RUN: Copied $real_config to test environment"
    fi
}

# Function to cleanup dry-run environment
cleanup_dry_run_environment() {
    if [[ -n "$DRY_RUN_TEMP_DIR" && -d "$DRY_RUN_TEMP_DIR" ]]; then
        echo
        print_info "DRY RUN: Test completed. Showing what was created:"
        echo
        ls -la "$DRY_RUN_TEMP_DIR"/
        echo
        print_info "DRY RUN: Cleaning up test environment..."
        rm -rf "$DRY_RUN_TEMP_DIR"
        print_success "DRY RUN: Test environment removed. No changes were made to your system."
    fi
}

# Function to get the effective path (real or dry-run)
get_effective_path() {
    local real_path="$1"
    
    if [[ "$DRY_RUN" == "true" && -n "$DRY_RUN_TEMP_DIR" ]]; then
        local basename=$(basename "$real_path")
        echo "$DRY_RUN_TEMP_DIR/$basename"
    else
        echo "$real_path"
    fi
}

# Function to generate shell guard script content
generate_guard_script() {
    local preferred_pm="$1"
    local blocked_pms="$2"
    local blocked_terms="$3"
    
    # Convert blocked_pms to array
    IFS=',' read -ra BLOCKED_ARRAY <<< "$blocked_pms"
    # Trim whitespace from each blocked PM entry
    for i in "${!BLOCKED_ARRAY[@]}"; do
        BLOCKED_ARRAY[$i]="$(echo "${BLOCKED_ARRAY[$i]}" | xargs)"
    done
    
    # Define command mappings per preferred package manager
    local install_no_args_cmd=""
    local install_with_args_prefix=""
    local remove_cmd=""
    local update_cmd=""
    local run_cmd=""
    local create_cmd=""
    local npx_cmd=""
    
    case "$preferred_pm" in
        bun)
            install_no_args_cmd="bun install"
            install_with_args_prefix="bun add"
            remove_cmd="bun remove"
            update_cmd="bun update"
            run_cmd="bun run"
            create_cmd="bun create"
            npx_cmd="bun x"
            ;;
        pnpm)
            install_no_args_cmd="pnpm install"
            install_with_args_prefix="pnpm add"
            remove_cmd="pnpm remove"
            update_cmd="pnpm update"
            run_cmd="pnpm run"
            create_cmd="pnpm create"
            npx_cmd="pnpm dlx"
            ;;
        yarn)
            install_no_args_cmd="yarn install"
            install_with_args_prefix="yarn add"
            remove_cmd="yarn remove"
            update_cmd="yarn upgrade"
            run_cmd="yarn run"
            create_cmd="yarn create"
            npx_cmd="yarn dlx"
            ;;
        npm)
            # For npm, prefer canonical subcommands and avoid "npm add"
            install_no_args_cmd="npm install"
            install_with_args_prefix="npm install"
            remove_cmd="npm uninstall"
            update_cmd="npm update"
            run_cmd="npm run"
            create_cmd="npm create"
            npx_cmd="npx"
            ;;
        *)
            # Fallback: behave like bun-style mapping
            install_no_args_cmd="$preferred_pm install"
            install_with_args_prefix="$preferred_pm add"
            remove_cmd="$preferred_pm remove"
            update_cmd="$preferred_pm update"
            run_cmd="$preferred_pm run"
            create_cmd="$preferred_pm create"
            npx_cmd="$preferred_pm x"
            ;;
    esac
    
    # Generate blocked PM cases for the switch statement
    local blocked_cases=""
    blocked_cases=$(IFS='|'; echo "${BLOCKED_ARRAY[*]}")
    
    # Generate equivalent cases for special commands
    local equiv_cases=""
    if [[ " ${BLOCKED_ARRAY[*]} " =~ " npx " ]]; then
        equiv_cases+="    npx)\n"
        equiv_cases+="      echo \"$npx_cmd \$*\"\n"
        equiv_cases+="      ;;\n"
    fi
    
    if [[ " ${BLOCKED_ARRAY[*]} " =~ " nvm " ]]; then
        equiv_cases+="    nvm)\n"
        equiv_cases+="      echo \"# $preferred_pm has built-in runtime; no direct nvm equivalent\"\n"
        equiv_cases+="      ;;\n"
    fi
    
    # Generate main guard functions with force flag logic
    local primary_blocked="${BLOCKED_ARRAY[0]}"
    local main_functions="$primary_blocked() {\n"
    main_functions+="  local first_arg=\"\$1\"\n"
    main_functions+="  \n"
    main_functions+="  # Check if 'force' flag is present as first argument\n"
    main_functions+="  if [[ \"\$first_arg\" == \"force\" ]]; then\n"
    main_functions+="    shift  # Remove 'force' from arguments\n"
    main_functions+="    \n"
    main_functions+="    # Check if TERM matches any blocked terminal (AI agent detection)\n"
    main_functions+="    # AI agents typically run from IDE terminals like xterm-256color\n"
    main_functions+="    local blocked_terms=\"$blocked_terms\"\n"
    main_functions+="    IFS=',' read -ra BLOCKED_TERMS_ARRAY <<< \"\$blocked_terms\"\n"
    main_functions+="    for blocked_term in \"\${BLOCKED_TERMS_ARRAY[@]}\"; do\n"
    main_functions+="      blocked_term=\$(echo \"\$blocked_term\" | xargs)  # Trim whitespace\n"
    main_functions+="      if [[ \"\$TERM\" == \"\$blocked_term\" ]]; then\n"
    main_functions+="        echo \"ERROR: AI agents are explicitly prohibited from using the 'force' flag.\"\n"
    main_functions+="        echo \"Detected terminal type: \$TERM (commonly used by AI agents in IDE environments)\"\n"
    main_functions+="        echo \"This restriction exists to prevent automated systems from bypassing package manager policies.\"\n"
    main_functions+="        return 1\n"
    main_functions+="      fi\n"
    main_functions+="    done\n"
    main_functions+="    \n"
    main_functions+="    # Human user confirmed with force flag, execute the command\n"
    main_functions+="    echo \"Force flag detected. Executing: $primary_blocked \$@\"\n"
    main_functions+="    echo \"WARNING: You are bypassing the preferred package manager ($preferred_pm).\"\n"
    main_functions+="    command $primary_blocked \"\$@\"\n"
    main_functions+="    return \$?\n"
    main_functions+="  fi\n"
    main_functions+="  \n"
    main_functions+="  # No force flag, show warning and block execution\n"
    main_functions+="  _${preferred_pm}_warn $primary_blocked \"\$@\"\n"
    main_functions+="  echo \"\"\n"
    main_functions+="  echo \"Command blocked. This system is configured to use $preferred_pm instead of $primary_blocked.\"\n"
    main_functions+="  echo \"\"\n"
    main_functions+="  echo \"If you are a human and really need to use $primary_blocked, run:\"\n"
    main_functions+="  echo \"  $primary_blocked force \$@\"\n"
    main_functions+="  echo \"\"\n"
    main_functions+="  echo \"Note: AI agents are prohibited from using the 'force' flag.\"\n"
    main_functions+="  echo \"      This ensures automated systems respect package manager preferences.\"\n"
    main_functions+="  return 1\n"
    main_functions+="}\n\n"

    # Additional guards for other blocked PMs
    local additional_guards=""
    for pm in "${BLOCKED_ARRAY[@]:1}"; do
        additional_guards+="$pm() { _guard_with_force $pm \"\$@\"; }\n"
    done
    
    # Generate the complete script
    cat << EOF
# $preferred_pm-guard: prevent $blocked_pms usage by AI agents, suggest $preferred_pm

_${preferred_pm}_equiv() {
  local cmd="\$1"; shift
  local sub="\$1"

  case "\$cmd" in
    $blocked_cases)
      case "\$sub" in
        ""|install|i)
          if [[ \$# -le 1 ]]; then
            echo "$install_no_args_cmd"
          else
            shift
            echo "$install_with_args_prefix \$*"
          fi
          ;;
        add)
          shift
          echo "$install_with_args_prefix \$*"
          ;;
        remove|rm|uninstall)
          shift
          echo "$remove_cmd \$*"
          ;;
        update|up)
          shift
          echo "$update_cmd \$*"
          ;;
        run)
          shift
          echo "$run_cmd \$*"
          ;;
        create)
          shift
          echo "$create_cmd \$*"
          ;;
        *)
          echo "$preferred_pm \$sub \${*:2}"
          ;;
      esac
      ;;
$(echo -e "$equiv_cases" | sed 's/\\n$//')
    *)
      echo "$preferred_pm \$cmd \$*"
      ;;
  esac
}

_${preferred_pm}_warn() {
  local cmd="\$1"; shift
  local ${preferred_pm}_equiv="\$(_${preferred_pm}_equiv "\$cmd" "\$@")"
  printf 'Please be advised: You have been instructed not to use %s. Instead, please use %s. The %s equivalent of your command is: %s\n' "\$cmd" "$preferred_pm" "$preferred_pm" "\$${preferred_pm}_equiv"
}

$(echo -e "$main_functions" | sed 's/\\n$//')
_guard_with_force() {
  local cmd="\$1"; shift
  local first_arg="\$1"

  # Check if 'force' flag is present as first argument
  if [[ "\$first_arg" == "force" ]]; then
    shift  # Remove 'force' from arguments

    # Check if TERM matches any blocked terminal (AI agent detection)
    local blocked_terms="$blocked_terms"
    IFS=',' read -ra BLOCKED_TERMS_ARRAY <<< "\$blocked_terms"
    for blocked_term in "\${BLOCKED_TERMS_ARRAY[@]}"; do
      blocked_term=\$(echo "\$blocked_term" | xargs)  # Trim whitespace
      if [[ "\$TERM" == "\$blocked_term" ]]; then
        echo "ERROR: AI agents are explicitly prohibited from using the 'force' flag."
        echo "Detected terminal type: \$TERM (commonly used by AI agents in IDE environments)"
        echo "This restriction exists to prevent automated systems from bypassing package manager policies."
        return 1
      fi
    done

    # Human user confirmed with force flag, execute the command
    echo "Force flag detected. Executing: \$cmd \$@"
    echo "WARNING: You are bypassing the preferred package manager ($preferred_pm)."
    command "\$cmd" "\$@"
    return \$?
  fi

  # No force flag, show warning and block execution
  _${preferred_pm}_warn "\$cmd" "\$@"
  echo ""
  echo "Command blocked. This system is configured to use $preferred_pm instead of \$cmd."
  echo ""
  echo "If you are a human and really need to use \$cmd, run:"
  echo "  \$cmd force \$@"
  echo ""
  echo "Note: AI agents are prohibited from using the 'force' flag."
  echo "      This ensures automated systems respect package manager preferences."
  return 1
}

$(echo -e "$additional_guards" | sed 's/\\n$//')
EOF
}

# Function to generate and install guard script
install_guard_script() {
    local preferred_pm="$1"
    local blocked_pms="$2"
    local blocked_terms="$3"
    local real_guard_file="$HOME/.${preferred_pm}_guard.sh"
    local guard_file=$(get_effective_path "$real_guard_file")

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Generating guard script: $guard_file"
        print_info "DRY RUN: (Would be: $real_guard_file in real install)"
    else
        print_info "Generating guard script: $guard_file"
        # Backup existing guard file if it exists
        prompt_mandatory_backup "$guard_file"
    fi

    # Generate the script
    if ! generate_guard_script "$preferred_pm" "$blocked_pms" "$blocked_terms" > "$guard_file"; then
        print_error "Failed to generate guard script!"
        INSTALL_FAILED=true
        return 1
    fi
    
    chmod +x "$guard_file"
    
    # Verify the generated script before proceeding
    if ! verify_guard_script "$guard_file" "$preferred_pm"; then
        print_error "Guard script verification failed!"
        INSTALL_FAILED=true
        return 1
    fi
    
    print_success "Generated and verified: $guard_file"
    return 0
}

# Function to generate uninstall script
generate_uninstall_script() {
    local preferred_pm="$1"
    local config_file="$2"
    local real_uninstall_dir="$HOME/.no-npm"
    local uninstall_dir=$(get_effective_path "$real_uninstall_dir")
    local uninstall_script="$uninstall_dir/uninstall.sh"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Creating uninstall script: $uninstall_script"
        print_info "DRY RUN: (Would be: $real_uninstall_dir/uninstall.sh in real install)"
    else
        print_info "Creating uninstall script: $uninstall_script"
    fi
    
    mkdir -p "$uninstall_dir"
        
        cat > "$uninstall_script" << EOF
#!/bin/bash

# no-npm uninstall script
# This script removes the no-npm package manager guard from your system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "\${BLUE}[INFO]\${NC} \$1"
}

print_success() {
    echo -e "\${GREEN}[SUCCESS]\${NC} \$1"
}

print_warning() {
    echo -e "\${YELLOW}[WARNING]\${NC} \$1"
}

print_error() {
    echo -e "\${RED}[ERROR]\${NC} \$1"
}

# Cross-platform sed in-place edit
sed_inplace() {
    local pattern="\$1"
    local file="\$2"
    
    case "\$(uname -s)" in
        Darwin*)
            sed -i '' "\$pattern" "\$file"
            ;;
        *)
            sed -i "\$pattern" "\$file"
            ;;
    esac
}

# Configuration
PREFERRED_PM="$preferred_pm"
CONFIG_FILE="$config_file"
GUARD_FILE="\$HOME/.${preferred_pm}_guard.sh"
UNINSTALL_DIR="\$HOME/.no-npm"

print_info "Removing no-npm guard for package manager: \$PREFERRED_PM"

# Remove guard script
if [[ -f "\$GUARD_FILE" ]]; then
    print_info "Removing guard script: \$GUARD_FILE"
    rm "\$GUARD_FILE"
    print_success "Guard script removed"
else
    print_warning "Guard script not found: \$GUARD_FILE"
fi

# Remove from shell config
if [[ -f "\$CONFIG_FILE" ]]; then
    print_info "Removing guard from shell config: \$CONFIG_FILE"

    if grep -q "no-npm package manager guard" "\$CONFIG_FILE" 2>/dev/null; then
        # 1) Remove the comment line
        sed_inplace '/^# no-npm package manager guard$/d' "\$CONFIG_FILE"
        # 2) Remove the guard source line directly below (or anywhere else it appears)
        sed_inplace '/\[ -f .*_guard\.sh \] && source .*_guard\.sh/d' "\$CONFIG_FILE"
        print_success "Guard removed from shell config"
    else
        print_warning "No no-npm guard found in shell config"
    fi
else
    print_warning "Shell config file not found: \$CONFIG_FILE"
fi

# Remove uninstall directory
if [[ -d "\$UNINSTALL_DIR" ]]; then
    print_info "Removing uninstall directory: \$UNINSTALL_DIR"
    rm -rf "\$UNINSTALL_DIR"
    print_success "Uninstall directory removed"
fi

print_success "Uninstall completed!"
print_info "Please restart your shell or run: source \$CONFIG_FILE"
print_info "Your original package managers (npm, pnpm, yarn, etc.) should now work normally"
EOF
    
    chmod +x "$uninstall_script"
    print_success "Created uninstall script: $uninstall_script"
    if [[ "$DRY_RUN" != "true" ]]; then
        print_info "To uninstall later, run: $uninstall_script"
    fi
}

# Function to install guard to shell config
install_to_shell() {
    local config_file="$1"
    local preferred_pm="$2"
    local guard_file="$HOME/.${preferred_pm}_guard.sh"
    local source_line="\n# no-npm package manager guard\n[ -f $guard_file ] && source $guard_file"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Installing guard to $config_file"
    else
        print_info "Installing guard to $config_file"
    fi
    
    # Check if already installed
    if grep -q "no-npm package manager guard" "$config_file" 2>/dev/null; then
        if [[ "$FORCE" == "false" ]]; then
            print_warning "Guard already installed in $config_file"
            print_info "Use --force to reinstall"
            return 0
        fi
        print_info "Removing existing guard from $config_file (comment + guard line only)"
        # 1) Remove the comment line
        sed_inplace '/^# no-npm package manager guard$/d' "$config_file"
        # 2) Remove any guard source line
        sed_inplace '/\[ -f .*_guard\.sh \] && source .*_guard\.sh/d' "$config_file"
    fi
    
    echo -e "$source_line" >> "$config_file"
    print_success "Guard installed to $config_file"
}

# Interactive installation
interactive_install() {
    # Setup dry-run environment if needed
    if [[ "$DRY_RUN" == "true" ]]; then
        setup_dry_run_environment
        # Set trap to cleanup on exit
        trap cleanup_dry_run_environment EXIT
    else
        # Require acceptance for real installations
        require_acceptance
        # Set trap for rollback on failure
        trap rollback_on_failure EXIT
    fi
    
    print_info "Starting interactive installation..."
    
    # Detect shell and default config file
    local shell_info
    shell_info=$(detect_shell)
    local shell_name="${shell_info%%:*}"
    local real_config_file="${shell_info##*:}"

    print_info "Detected shell from \$SHELL/runtime: $shell_name"
    print_info "Default config file to modify: $real_config_file"

    # Allow the user to override which config file to modify
    local user_config
    read -p "Which shell config file do you want to modify? [$real_config_file]: " user_config
    real_config_file="${user_config:-$real_config_file}"
    
    # Validate the config file path before proceeding
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! validate_config_file "$real_config_file"; then
            print_error "Config file validation failed. Please fix the issues and try again."
            exit 1
        fi
    fi
    
    # Get effective config file path (real or dry-run temp)
    local config_file=$(get_effective_path "$real_config_file")
    
    # Get preferred package manager
    local preferred_pm
    while true; do
        read -p "Which package manager do you want to enforce? (bun/pnpm/yarn/npm) [$DEFAULT_PREFERRED_PM]: " preferred_pm
        preferred_pm="${preferred_pm:-$DEFAULT_PREFERRED_PM}"
        
        if validate_pm "$preferred_pm"; then
            break
        else
            print_error "Invalid package manager. Please choose from: bun, pnpm, yarn, npm"
        fi
    done
    
    # Get blocked package managers
    local blocked_pms
    while true; do
        read -p "Which package managers do you want to block? (comma-separated, default: $DEFAULT_BLOCKED_PMS): " blocked_pms
        blocked_pms="${blocked_pms:-$DEFAULT_BLOCKED_PMS}"

        # Validate and normalize blocked PMs
        local valid=true
        IFS=',' read -ra BLOCKED_ARRAY <<< "$blocked_pms"

        # First pass: validate names (skip empty entries)
        for pm in "${BLOCKED_ARRAY[@]}"; do
            pm=$(echo "$pm" | xargs) # trim whitespace
            if [[ -z "$pm" ]]; then
                continue
            fi
            if ! validate_pm "$pm"; then
                print_error "Invalid package manager: $pm"
                valid=false
                break
            fi
        done

        if [[ "$valid" != "true" ]]; then
            continue
        fi

        # Second pass: normalize, dedupe, and drop the preferred PM
        local normalized=()
        local seen=","  # sentinel commas so we can do substring checks
        for pm in "${BLOCKED_ARRAY[@]}"; do
            pm=$(echo "$pm" | xargs)
            if [[ -z "$pm" ]]; then
                continue
            fi
            if [[ "$pm" == "$preferred_pm" ]]; then
                print_warning "Ignoring $pm in blocked list because it is the preferred package manager"
                continue
            fi
            if [[ "$seen" != *",$pm,"* ]]; then
                normalized+=("$pm")
                seen+="$pm,"
            fi
        done

        if ((${#normalized[@]} == 0)); then
            print_error "Blocked package managers cannot be empty or only contain the preferred package manager."
            valid=false
        else
            blocked_pms=$(IFS=','; echo "${normalized[*]}")
        fi

        if [[ "$valid" == "true" ]]; then
            break
        fi
    done
    
    # Get blocked terminal types (for AI agent detection)
    local blocked_terms
    echo
    print_info "AI agents typically run from IDE terminals (VS Code, Windsurf, etc.)"
    read -p "Which TERM values should be blocked from using 'force'? (comma-separated) [$DEFAULT_BLOCKED_TERMS]: " blocked_terms
    blocked_terms="${blocked_terms:-$DEFAULT_BLOCKED_TERMS}"
    
    # Check if guard already exists
    if is_guard_installed "$preferred_pm" && [[ "$FORCE" == "false" ]]; then
        print_warning "Guard for $preferred_pm already exists"
        read -p "Do you want to overwrite it? (y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            print_info "Installation cancelled"
            exit 0
        fi
        FORCE=true
    fi
    
    # Show summary
    echo
    print_info "Installation Summary:"
    echo "  Preferred package manager: $preferred_pm"
    echo "  Blocked package managers: $blocked_pms"
    echo "  Blocked terminal types (AI detection): $blocked_terms"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Shell config: $config_file (TEST COPY)"
        echo "  Real target: $real_config_file"
    else
        echo "  Shell config: $config_file"
    fi
    echo
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - Testing on dummy files"
        print_info "This will verify the script works on your system without making real changes."
    fi
    
    read -p "Proceed with installation? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "Installation cancelled"
        exit 0
    fi
    
    # Mandatory backup of config file (with user prompt)
    if [[ "$DRY_RUN" != "true" ]]; then
        backup_config "$config_file"
    else
        print_info "DRY RUN: Skipping backup prompt (testing on dummy files)"
    fi
    
    # Generate and install guard script (with error handling)
    if ! install_guard_script "$preferred_pm" "$blocked_pms" "$blocked_terms"; then
        print_error "Failed to install guard script!"
        INSTALL_FAILED=true
        exit 1
    fi
    
    if ! generate_uninstall_script "$preferred_pm" "$real_config_file"; then
        print_error "Failed to generate uninstall script!"
        INSTALL_FAILED=true
        exit 1
    fi
    
    if ! install_to_shell "$config_file" "$preferred_pm"; then
        print_error "Failed to install to shell config!"
        INSTALL_FAILED=true
        exit 1
    fi
    
    # If we got here, installation succeeded - disable rollback trap
    if [[ "$DRY_RUN" != "true" ]]; then
        trap - EXIT
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo
        print_success "DRY RUN: Test installation completed successfully!"
        print_info "DRY RUN: Your system is compatible. Run without --dry-run to install for real."
        # Show what was created in temp dir (cleanup will happen via trap)
    else
        echo
        print_success "Installation completed successfully!"
        print_info "Please restart your shell or run: source $config_file"
        
        # Show backup summary
        if [[ ${#BACKUPS_CREATED[@]} -gt 0 ]]; then
            echo
            print_info "Backups created during installation:"
            for backup in "${BACKUPS_CREATED[@]}"; do
                echo "  - $backup"
            done
            print_info "Keep these backups safe in case you need to restore."
        fi
    fi
}

# Function to verify script integrity (basic security check)
verify_script_integrity() {
    # Check if we're running from a known source or have required functions
    if ! declare -f generate_guard_script >/dev/null 2>&1; then
        print_error "Script integrity check failed - missing required functions"
        exit 1
    fi
    
    # Check for basic required tools
    local required_tools=("cat" "sed" "grep" "chmod" "mktemp" "cp")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            print_error "Required tool not found: $tool"
            exit 1
        fi
    done
    
    # Detect OS for sed compatibility
    detect_os
}

# Function to detect OS and set sed flags accordingly
detect_os() {
    OS_TYPE="unknown"
    SED_INPLACE_FLAG="-i"
    
    case "$(uname -s)" in
        Darwin*)
            OS_TYPE="macos"
            SED_INPLACE_FLAG="-i ''"
            ;;
        Linux*)
            OS_TYPE="linux"
            SED_INPLACE_FLAG="-i"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            OS_TYPE="windows"
            SED_INPLACE_FLAG="-i"
            ;;
        *)
            print_warning "Unknown OS: $(uname -s). Assuming Linux-style sed."
            ;;
    esac
    
    print_info "Detected OS: $OS_TYPE"
}

# Cross-platform sed in-place edit
sed_inplace() {
    local pattern="$1"
    local file="$2"
    
    if [[ "$OS_TYPE" == "macos" ]]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}

# Parse command line arguments
PROVIDED_CHECKSUM=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --verify)
            VERIFY_MODE=true
            shift
            ;;
        --checksum)
            if [[ -n "${2:-}" ]]; then
                PROVIDED_CHECKSUM="$2"
                shift 2
            else
                print_error "--checksum requires a SHA256 hash argument"
                exit 1
            fi
            ;;
        --uninstall)
            UNINSTALL_MODE=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verify checksum if provided
if [[ -n "$PROVIDED_CHECKSUM" ]]; then
    verify_installer_checksum "$PROVIDED_CHECKSUM"
fi

# Handle uninstall mode (does not require interactive TTY)
if [[ "$UNINSTALL_MODE" == "true" ]]; then
    uninstall_script="$HOME/.no-npm/uninstall.sh"
    if [[ -x "$uninstall_script" ]]; then
        print_info "Running uninstall script: $uninstall_script"
        "$uninstall_script"
        exit $?
    else
        print_error "Uninstall script not found or not executable: $uninstall_script"
        print_info "If you removed it manually, you may need to clean your shell config by hand."
        exit 1
    fi
fi

# Handle verify-only mode
if [[ "$VERIFY_MODE" == "true" ]]; then
    print_info "Running in verify-only mode..."
    verify_script_integrity
    
    # Generate a test guard script to temp and verify it
    print_info "Generating test guard script for verification..."
    temp_guard=$(mktemp)
    generate_guard_script "bun" "npm" "$DEFAULT_BLOCKED_TERMS" > "$temp_guard"
    
    if verify_guard_script "$temp_guard" "bun"; then
        print_success "All verifications passed!"
        print_info "The installer appears to be working correctly."
        print_info "Run without --verify to perform actual installation."
    else
        print_error "Verification failed!"
        exit 1
    fi
    
    rm -f "$temp_guard"
    exit 0
fi

# Check if running interactively
if [[ -t 0 ]]; then
    # Verify script integrity before proceeding
    verify_script_integrity
    interactive_install
else
    print_error "This installer requires interactive mode"
    print_info "Please run: curl -sSL <url> | bash"
    exit 1
fi
