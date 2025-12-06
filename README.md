# no-npm

blocks AI agents from using package managers you dont want them to and redirects to your preferred one

## install

three options: simple, full, or python

### simple installer (recommended)

short and readable. does the job without extra features. 170 lines.

```bash
curl -sSL https://raw.githubusercontent.com/username/no-npm/main/simple_install.sh > simple_install.sh
cat simple_install.sh  # read it first
bash simple_install.sh --dry-run  # test it
bash simple_install.sh  # install
```

backs up your config automatically. to uninstall: delete the guard file and remove the lines from your config.

### python installer (safest, because i can code in it :D)

all the safety features but in python. syntax checking, validation, automatic rollback. type-safe and easier to read than bash.

```bash
curl -sSL https://raw.githubusercontent.com/username/no-npm/main/safe_install.py > safe_install.py
cat safe_install.py  # actually readable
python3 safe_install.py --dry-run  # test it
python3 safe_install.py  # install
```

requires python 3.6+. has casual comments for your reading pleasure.

### full bash installer

has rollback, verification, uninstall script generation, and other safety features. 1170 lines.

```bash
curl -sSL https://raw.githubusercontent.com/username/no-npm/main/install.sh > install.sh
cat install.sh  # good luck reading this
bash install.sh --verify  # test without installing
bash install.sh --dry-run  # or test with dummy files
bash install.sh  # install
```

with checksum verification:

```bash
curl -sSL https://raw.githubusercontent.com/username/no-npm/main/install.sh > install.sh
echo "<checksum>  install.sh" | sha256sum -c
bash install.sh
```

## what it does

- blocks package managers you specify (npm, yarn, whatever)
- shows the equivalent command for your preferred manager
- backs up your config before modifying
- works in bash and zsh

## how it works

1. asks which package manager you prefer (bun, pnpm, yarn, npm)
2. asks which ones to block (npm, yarn, etc)
3. creates guard script at `~/.{pm}_guard.sh`
4. adds source line to your shell config
5. when you try to use a blocked command, it shows the equivalent and exits

example with bun:

```bash
$ npm install react
dont use npm. use bun instead: bun add react

$ bun add react
# works
```

## if your shell breaks

backups are saved as `~/.zshrc.bak.20231206_143022` (or whatever your config file is)

find your backup:
```bash
ls -lt ~/.*.bak.* | head -1
```

restore it:
```bash
cp ~/.zshrc.bak.<timestamp> ~/.zshrc
```

if you cant open a terminal:
- use a different shell: `/bin/bash`
- ssh from another machine
- boot to recovery mode (macOS: cmd+s, linux: grub recovery)

## uninstall

simple installer:
```bash
rm ~/.{pm}_guard.sh
# edit your config and remove the two lines
```

full installer:
```bash
~/.no-npm/uninstall.sh
```

## troubleshooting

not working? restart your terminal or run `source ~/.zshrc`

still not working? check that `~/.{pm}_guard.sh` exists and your config sources it

want to disable temporarily? `unset npm pnpm yarn npx`

## command mappings

| npm command   | bun         | pnpm          | yarn        |
|---------------|-------------|---------------|-------------|
| npm install   | bun install | pnpm install  | yarn        |
| npm add pkg   | bun add pkg | pnpm add pkg  | yarn add pkg|
| npm run cmd   | bun run cmd | pnpm cmd      | yarn cmd    |
| npx cmd       | bun x cmd   | pnpm dlx cmd  | yarn dlx cmd|

## license

MIT