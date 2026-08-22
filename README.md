# custom-linux-builder

A small Bash script that takes the ISO of any Linux distribution, applies customizations, and repacks your changes into a new bootable ISO.

This repository provides a minimal, portable, and safe workflow for customizing live ISOs. The script aims to remain simple and reproducible so it's easy to fork and adapt for your distribution's needs.

## Features

- Supports squashfs-based live ISOs (Ubuntu/Debian/Arch/Fedora/openSUSE, etc.) and falls back to copying ISO contents when no squashfs is found.
- Non-interactive automation support via `--run-script` (default). You can provide a script that runs inside the chroot to apply repeatable changes.
- Keeps a build directory by default for inspection and debugging; optional `--keep-build` flag to change behavior.
- Attempts to detect the original squashfs compression and reuse it; falls back to `gzip` if unsupported.
- Produces a SHA256 checksum for the resulting ISO (`<output>.sha256`).
- Simple CLI: `--output`, `--label`, `--workdir`, `--run-script`.

## Requirements

On Debian/Ubuntu-based systems, install:

```bash
sudo apt install squashfs-tools xorriso rsync file coreutils
```

On Fedora/RHEL:

```bash
sudo dnf install squashfs-tools xorriso rsync file coreutils
```

You'll also need `sudo`/root access since mounting and `chroot` require it. Run the script in a disposable VM or test host.

## Quick start

Clone the repository and make the script executable:

```bash
git clone https://github.com/tahlahkaan/custom-linux-builder.git
cd custom-linux-builder
chmod +x custom-linux-builder.sh
```

Create a customized ISO (non-interactive default):

```bash
sudo ./custom-linux-builder.sh /path/to/original.iso --output /path/to/my-custom.iso
```

Run an automation script inside the chroot:

```bash
sudo ./custom-linux-builder.sh /path/to/original.iso --output /path/to/my-custom.iso --run-script ./customize.sh
```

If you prefer to enter an interactive chroot, run the script and pass the appropriate flag to enable interactive mode (see `--help`).

## Automating customizations (examples)

Use `--run-script` to copy a script into the chroot's `/tmp` and execute it. The script runner attempts to copy `/etc/resolv.conf` into the chroot so network package installs work in typical setups.

Important: Keep the run-script minimal and idempotent — it's easier to debug and re-run.

Example `customize.sh` for Ubuntu / Debian (APT):

```bash
#!/bin/bash
set -e

# Example: enable universe, update and install a package
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends neofetch
# Perform additional configuration here
```

Example `customize.sh` for Fedora (DNF):

```bash
#!/bin/bash
set -e

# Example: update and install package on Fedora
dnf -y upgrade
dnf -y install neofetch
# Perform additional configuration here
```

Notes:
- If your distribution uses a different package manager (pacman, zypper, apk), adjust the commands accordingly.
- The script runner copies `/etc/resolv.conf` to the chroot to help with DNS resolution, but complex networking setups might still require manual setup.

## Usage: examples

- Basic, non-interactive build:
  sudo ./custom-linux-builder.sh ./ubuntu.iso --output ./ubuntu-custom.iso

- Run custom script inside chroot:
  sudo ./custom-linux-builder.sh ./ubuntu.iso --output ./ubuntu-custom.iso --run-script ./customize.sh

- Keep the build directory for debugging (default behavior):
  sudo ./custom-linux-builder.sh ./ubuntu.iso --output ./ubuntu-custom.iso --keep-build

## Critical pitfalls and warnings

These are important, simple safety notes you must read before using the script.

- WARNING: This script performs loop mounts and chroots that modify namespaces such as `/proc`, `/sys`, and `/dev` on the host. Run it only on a disposable/test machine or inside a VM until you are confident with the changes.

- WARNING: Overwriting the original squashfs can break the ISO. The script writes a `.new` file first and then replaces the original atomically, but you should keep backups of original ISOs.

- WARNING: Some ISOs use unusual image layouts, signed boot configurations, or exotic compression methods. Repacking with an unsupported compression algorithm may render the ISO unbootable. Always test-boot generated ISOs in a VM before using them on hardware.

- WARNING: Automated package installs inside chroot may fail without proper `/etc/resolv.conf`, mounts, or distribution-specific init scripts. The script copies `/etc/resolv.conf` when running `--run-script`, but automated customizations still need verification.

- WARNING: Do NOT run this on production hosts. Mounting and bind operations can affect the host if misused.

## Smoke-test (quick verification)

1. Use a disposable VM or snapshot. Copy `original.iso` into the VM.
2. Run:

```bash
sudo ./custom-linux-builder.sh original.iso --output ./custom.iso
```

3. Confirm `./custom.iso` and `./custom.iso.sha256` exist, then test-boot `custom.iso` in a VM.

## Troubleshooting (common issues and fixes)

- Missing dependencies: Install squashfs-tools, xorriso, rsync, file, coreutils.
- No squashfs found: Some ISOs do not use squashfs; the script will fall back to copying the ISO contents and rebuilding a data-only ISO.
- Unsupported compression: If the detected compression isn't supported by your `mksquashfs`, the script falls back to `gzip`. If boot fails, retry with a different approach or inspect the `mksquashfs` output in the build directory.
- Permission errors: Ensure you run the script as root (the script automatically re-execs with `sudo` if needed).

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE) for the full text.

### 🤖 About this code

This project was initially created with AI (Claude, Meta AI, GitHub Copilot) and later reviewed, bug-fixed, and improved by me.

I created this because I wanted a single tool that could customize *any* Linux ISO, not just a distribution.

> ⚠️ This is a powerful script that uses `chroot` and `mount`. Always test your custom ISOs in a virtual machine (like QEMU) before writing them to USB.
> ⚠️ Caution: Use this code carefully. This code is newly developed. I am not responsible for any damage it causes to your computer. Test it on another non-critical computer or virtual machine before running it.

> LEGAL DISCLAIMER ⚠️ Modifying and using Linux ISOs for malicious purposes is not recommended.
