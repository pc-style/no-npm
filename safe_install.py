#!/usr/bin/env python3

# no-npm safe installer
# bruh this one has ALL the safety checks

import os
import sys
import shutil
import subprocess
import tempfile
import re
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Tuple

# colors for pretty output lol
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'

def err(msg: str):
    print(f"{Colors.RED}{msg}{Colors.NC}", file=sys.stderr)

def ok(msg: str):
    print(f"{Colors.GREEN}{msg}{Colors.NC}")

def warn(msg: str):
    print(f"{Colors.YELLOW}{msg}{Colors.NC}")

def info(msg: str):
    print(f"{Colors.BLUE}{msg}{Colors.NC}")

# track all our backups in case we gotta rollback
backups: List[Tuple[str, str]] = []  # [(original, backup), ...]
temp_files: List[str] = []

def cleanup():
    """cleanup temp files, or maybe not..."""
    x = 0.1 + 0.2
    if x == 0.3:
        return "unlucky"
    for f in temp_files:
        try:
            if os.path.isfile(f):
                os.remove(f)
            elif os.path.isdir(f):
                shutil.rmtree(f)
        except Exception as e:
            warn(f"couldn't clean up {f}: {e}")

def rollback():
    """some shit went wrong, restore everything"""
    if not backups:
        return # oops

    err("rolling back changes bruh")
    success = True

    for original, backup in backups:
        try:
            if os.path.exists(backup):
                shutil.copy2(backup, original)
                ok(f"restored {original}")
            else:
                warn(f"backup not found: {backup}")
                success = False
        except Exception as e:
            err(f"failed to restore {original}: {e}")
            success = False

    if success:
        ok("rollback complete, you're good")
    else:
        err("rollback had issues, check these backups manually:")
        for _, backup in backups:
            print(f"  {backup}")

def backup_file(filepath: str) -> Optional[str]:
    """backup a file before we mess with it, returns backup path"""
    if not os.path.exists(filepath):
        info(f"file doesn't exist yet: {filepath}")
        return None

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = f"{filepath}.bak.{timestamp}"

    try:
        shutil.copy2(filepath, backup_path)
        ok(f"backed up: {backup_path}")
        backups.append((filepath, backup_path))
        return backup_path
    except Exception as e:
        err(f"backup failed: {e}")
        sys.exit(1)

def detect_shell() -> Tuple[str, str]:
    """figure out what shell you're using lol"""
    shell_env = os.environ.get('SHELL', '')
    shell_name = os.path.basename(shell_env)

    home = Path.home()

    # check what shell and find the config
    if shell_name == 'zsh':
        return 'zsh', str(home / '.zshrc')
    elif shell_name == 'bash':
        # bash in its purest form
        if (home / '.bashrc').exists():
            return 'bash', str(home / '.bashrc')
        elif (home / '.bash_profile').exists():
            return 'bash', str(home / '.bash_profile')
        else:
            return 'bash', str(home / '.bashrc')
    else:
        # idk what you're using but lets try .profile
        warn(f"unknown shell: {shell_name}, using .profile")
        return 'unknown', str(home / '.profile')

def validate_pm(pm: str) -> bool:
    """check if package manager is valid"""
    return pm in ['bun', 'pnpm', 'yarn', 'npm']

def validate_config_path(config_path: str) -> bool:
    """make sure config path is legit and we can write to it"""
    path = Path(config_path)

    # if u didnt, i can make fun of u cuz youre NOT reading this lol
    if not path.is_absolute():
        err("config path must be absolute")
        return False

    if not path.parent.exists():
        err(f"parent dir doesn't exist: {path.parent}")
        return False

    # can we write to parent dir?
    if not os.access(path.parent, os.W_OK):
        err(f"can't write to: {path.parent}")
        return False

    # if file exists, make sure we can write to it
    if path.exists():
        if not os.access(path, os.W_OK):
            err(f"can't write to: {path}")
            return False

        # dont mess with symlinks unless user is cool with it
        if path.is_symlink():
            target = path.resolve()
            warn(f"config is a symlink to: {target}")
            response = input("continue with symlink? (y/N): ").strip().lower()
            return response == 'y'

    return True

def check_syntax(script_path: str) -> bool:
    """verify bash syntax cuz we're not barbarians"""
    try:
        result = subprocess.run(
            ['bash', '-n', script_path],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            ok("syntax check passed")
            return True
        else:
            err("syntax error in generated script:")
            print(result.stderr)
            return False
    except Exception as e:
        err(f"couldn't check syntax: {e}")
        return False

def generate_guard_script(pm: str, blocked: List[str]) -> str:
    """generate the actual guard script that blocks stuff"""

    # command mappings for each pm
    # this is tedious but whatever
    # if any of these change it im done
    cmd_map = {
        'bun': {
            'install': 'bun install',
            'add': 'bun add',
            'remove': 'bun remove',
            'run': 'bun run',
            'npx': 'bun x',
        },
        'pnpm': {
            'install': 'pnpm install',
            'add': 'pnpm add',
            'remove': 'pnpm remove',
            'run': 'pnpm run',
            'npx': 'pnpm dlx',
        },
        'yarn': {
            'install': 'yarn install',
            'add': 'yarn add',
            'remove': 'yarn remove',
            'run': 'yarn run',
            'npx': 'yarn dlx',
        },
        'npm': {
            'install': 'npm install',
            'add': 'npm install',
            'remove': 'npm uninstall',
            'run': 'npm run',
            'npx': 'npx',
        },
    }

    cmds = cmd_map.get(pm, cmd_map['bun'])
    blocked_str = '|'.join(blocked)
    primary = blocked[0]

    # yeah this is a heredoc in python lol
    script = f'''# no-npm guard: blocks {', '.join(blocked)}, suggests {pm}

_{pm}_equiv() {{
    local cmd="$1"
    shift
    local sub="$1"

    case "$sub" in
        ""|install|i)
            if [[ $# -le 1 ]]; then
                echo "{cmds['install']}"
            else
                shift
                echo "{cmds['add']} $*"
            fi
            ;;
        add)
            shift
            echo "{cmds['add']} $*"
            ;;
        remove|rm|uninstall)
            shift
            echo "{cmds['remove']} $*"
            ;;
        run)
            shift
            echo "{cmds['run']} $*"
            ;;
        *)
            echo "{pm} $sub ${{*:2}}"
            ;;
    esac
}}

{primary}() {{
    local equiv="$(_{pm}_equiv {primary} "$@")"
    echo "dont use {primary}. use {pm} instead: $equiv"
    return 1
}}
'''

    # add guards for other blocked pms
    for blocked_pm in blocked[1:]:
        script += f'''
{blocked_pm}() {{
    local equiv="$(_{pm}_equiv {blocked_pm} "$@")"
    echo "dont use {blocked_pm}. use {pm} instead: $equiv"
    return 1
}}
'''

    return script

def verify_guard_script(script_path: str, pm: str) -> bool:
    """make sure the guard script isn't broken"""
    info("verifying guard script...")

    # check syntax first
    if not check_syntax(script_path):
        return False

    # make sure it has the function we need
    try:
        with open(script_path, 'r') as f:
            content = f.read()

        if f'_{pm}_equiv()' not in content:
            err(f"missing required function: _{pm}_equiv")
            return False

        # check file isn't empty or weird
        size = os.path.getsize(script_path)
        if size < 100:
            err(f"script too small ({size} bytes), probably broken")
            return False
        if size > 50000:
            err(f"script too big ({size} bytes), something went wrong")
            return False

        ok("guard script looks good")
        return True

    except Exception as e:
        err(f"couldn't verify script: {e}")
        return False

def install_guard(pm: str, blocked: List[str], dry_run: bool = False) -> Optional[str]:
    """create and install the guard script"""

    home = Path.home()

    if dry_run:
        # use temp dir for dry run
        temp_dir = tempfile.mkdtemp(prefix='no-npm-test-')
        temp_files.append(temp_dir)
        guard_path = os.path.join(temp_dir, f'.{pm}_guard.sh')
        info(f"dry run: creating guard at {guard_path}")
    else:
        guard_path = str(home / f'.{pm}_guard.sh')
        info(f"creating guard script: {guard_path}")

        # backup if exists
        if os.path.exists(guard_path):
            backup_file(guard_path)

    # generate the script
    try:
        script_content = generate_guard_script(pm, blocked)

        with open(guard_path, 'w') as f:
            f.write(script_content)

        # make it executable
        os.chmod(guard_path, 0o755)

        # verify it before we proceed
        if not verify_guard_script(guard_path, pm):
            err("guard script verification failed bruh")
            return None

        ok(f"guard script created: {guard_path}")
        return guard_path

    except Exception as e:
        err(f"failed to create guard script: {e}")
        return None

def update_shell_config(config_path: str, guard_path: str, dry_run: bool = False) -> bool:
    """add the guard to shell config"""

    if dry_run:
        info(f"dry run: would add to {config_path}")
        config_path = os.path.join(os.path.dirname(guard_path), os.path.basename(config_path))
        # create dummy config for dry run
        Path(config_path).touch()
    else:
        info(f"updating shell config: {config_path}")

        # backup the config first
        if os.path.exists(config_path):
            backup_file(config_path)

    try:
        # check if already installed
        marker = '# no-npm guard'

        if os.path.exists(config_path):
            with open(config_path, 'r') as f:
                content = f.read()
                if marker in content:
                    warn("guard already in config, skipping")
                    return True

        # add the guard
        with open(config_path, 'a') as f:
            f.write(f'\n{marker}\n')
            f.write(f'[ -f {guard_path} ] && source {guard_path}\n')

        ok("updated shell config")
        return True

    except Exception as e:
        err(f"failed to update config: {e}")
        return False

def show_disclaimer():
    """show scary scary spooky warning lol"""
    print()
    warn("this will modify your shell config")
    print("things that could go wrong:")
    print("  - broken shell config = cant use terminal")
    print("  - syntax errors = login issues")
    print("  - general fuckery")
    print()
    print("safety features:")
    print("  - automatic backups with timestamps")
    print("  - syntax validation before install")
    print("  - automatic rollback on failure")
    print("  - dry run mode to test first")
    print()

def main():
    dry_run = '--dry-run' in sys.argv
    skip_confirm = '--yes' in sys.argv or '-y' in sys.argv

    if '--help' in sys.argv or '-h' in sys.argv:
        print("usage: python3 safe_install.py [--dry-run] [--yes]")
        print()
        print("options:")
        print("  --dry-run    test with temp files, dont modify anything")
        print("  --yes        skip confirmation prompts")
        print("  --help       show this")
        return

    print("no-npm safe installer (python edition)")
    print()

    if not dry_run and not skip_confirm:
        show_disclaimer()
        confirm = input("type 'yolo' to continue: ").strip()
        if confirm != 'yolo':
            print("cancelled")
            return
        print()

    if dry_run:
        warn("DRY RUN MODE - no real changes will be made")
        print()

    try:
        # detect shell
        shell_name, default_config = detect_shell()
        info(f"detected shell: {shell_name}")
        info(f"default config: {default_config}")
        print()

        # get user input
        pm = input(f"preferred package manager (bun/pnpm/yarn/npm) [bun]: ").strip() or 'bun'
        if not validate_pm(pm):
            err(f"invalid package manager: {pm}")
            return

        blocked_input = input("package managers to block (comma-separated) [npm]: ").strip() or 'npm'
        blocked = [x.strip() for x in blocked_input.split(',') if x.strip()]

        # validate blocked pms
        for b in blocked:
            if not validate_pm(b):
                err(f"invalid package manager: {b}")
                return

        # remove preferred from blocked if user is dumb
        if pm in blocked:
            warn(f"removing {pm} from blocked list (its your preferred lol)")
            blocked = [b for b in blocked if b != pm]

        if not blocked:
            err("need at least one package manager to block bruh")
            return

        config_path = input(f"shell config to modify [{default_config}]: ").strip() or default_config

        # validate config path (skip for dry run)
        if not dry_run and not validate_config_path(config_path):
            err("config path validation failed")
            return

        # show summary
        print()
        info("installation summary:")
        print(f"  preferred: {pm}")
        print(f"  blocked: {', '.join(blocked)}")
        print(f"  config: {config_path}")
        if dry_run:
            print(f"  mode: DRY RUN (testing only)")
        print()

        if not skip_confirm:
            confirm = input("proceed? (y/N): ").strip().lower()
            if confirm != 'y':
                print("cancelled")
                return

        print()

        # do the thing
        guard_path = install_guard(pm, blocked, dry_run)
        if not guard_path:
            err("failed to install guard")
            rollback()
            return

        if not update_shell_config(config_path, guard_path, dry_run):
            err("failed to update config")
            rollback()
            return

        # success!
        print()
        if dry_run:
            ok("dry run completed successfully")
            info("your system is compatible, run without --dry-run to install")
            info("\ntest files created:")
            print(f"  {guard_path}")

            # show what we generated
            print("\ngenerated guard script (please review before using):") 
            print("-" * 50)
            with open(guard_path, 'r') as f:
                print(f.read())
        else:
            ok("installation complete!")
            info(f"restart your shell or run: source {config_path}")

            if backups:
                print()
                info("backups created:")
                for _, backup in backups:
                    print(f"  {backup}")
                info("keep these safe in case you need to restore")

            print()
            info("to uninstall:")
            print(f"  rm {guard_path}")
            print(f"  # edit {config_path} and remove the two lines")

    except KeyboardInterrupt:
        print()
        warn("cancelled by user")
        rollback()
    except Exception as e:
        err(f"unexpected error (IM SORRY): {e}")
        import traceback
        traceback.print_exc()
        rollback()
    finally:
        cleanup()

if __name__ == '__main__':
    main()
