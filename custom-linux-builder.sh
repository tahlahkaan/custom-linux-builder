#!/usr/bin/env bash
#
# custom-linux-builder.sh
# ------------------------------------------------------------------
# Takes the ISO of any Linux distribution, lets you chroot into it
# to customize it, and repacks your changes into a new ISO.
#
# Usage:
#   sudo ./custom-linux-builder.sh /path/to/original.iso
#
# Requirements (on Debian/Ubuntu-based systems):
#   sudo apt install squashfs-tools xorriso rsync
#
# WARNING: This script performs loop-mount and chroot operations on
# your system. Make sure you understand the code before running it.
# No responsibility is accepted for data loss or system issues.
# ------------------------------------------------------------------

set -euo pipefail

# ============================================================
# CONFIGURATION (forkers should edit this section first)
# ============================================================
readonly SOURCE_ISO="${1:-}"          # Input ISO path (first argument)
readonly BUILD_DIR="./build"           # Working directory
readonly OUTPUT_ISO="./custom.iso"     # Output ISO file
readonly VOLUME_LABEL="CustomLinux"    # Volume label for the ISO

# These are tracked so cleanup() can safely unmount them on exit.
ISO_MOUNT_DIR=""
ROOTFS_DIR=""
SQUASHFS_PATH=""

# ============================================================
# HELPER FUNCTIONS
# ============================================================

log() {
    echo -e "\n==> $1"
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

# Runs no matter how the script exits (success, error, Ctrl+C) and
# safely unmounts anything that might still be mounted.
cleanup() {
    log "Cleaning up..."
    if [ -n "$ROOTFS_DIR" ] && mountpoint -q "$ROOTFS_DIR/dev" 2>/dev/null; then
        sudo umount -R "$ROOTFS_DIR/dev" 2>/dev/null || true
    fi
    if [ -n "$ROOTFS_DIR" ] && mountpoint -q "$ROOTFS_DIR/proc" 2>/dev/null; then
        sudo umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
    fi
    if [ -n "$ROOTFS_DIR" ] && mountpoint -q "$ROOTFS_DIR/sys" 2>/dev/null; then
        sudo umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
    fi
    if [ -n "$ISO_MOUNT_DIR" ] && mountpoint -q "$ISO_MOUNT_DIR" 2>/dev/null; then
        sudo umount "$ISO_MOUNT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

check_dependencies() {
    local missing=()
    for cmd in unsquashfs mksquashfs xorriso rsync; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing commands: ${missing[*]}. Install with 'sudo apt install squashfs-tools xorriso rsync'."
    fi
}

check_input() {
    [ -n "$SOURCE_ISO" ] || die "Usage: $0 <iso-path>"
    [ -f "$SOURCE_ISO" ] || die "ISO not found: $SOURCE_ISO"
}

# ============================================================
# 1. EXTRACT THE ISO AND COPY ITS FILES
# ============================================================
extract_iso() {
    log "Extracting ISO..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/iso"

    ISO_MOUNT_DIR="$(mktemp -d)"
    sudo mount -o loop,ro "$SOURCE_ISO" "$ISO_MOUNT_DIR"
    rsync -a "$ISO_MOUNT_DIR/" "$BUILD_DIR/iso/"
    sudo umount "$ISO_MOUNT_DIR"
    ISO_MOUNT_DIR=""
}

# ============================================================
# 2. LOCATE AND UNPACK THE SQUASHFS (to access the root filesystem)
# ============================================================
extract_rootfs() {
    log "Looking for the root filesystem (squashfs)..."
    SQUASHFS_PATH="$(find "$BUILD_DIR/iso" \( -name "*.squashfs" -o -name "squashfs.img" \) -print -quit)"

    ROOTFS_DIR="$BUILD_DIR/rootfs"

    if [ -n "$SQUASHFS_PATH" ]; then
        log "Found squashfs: $SQUASHFS_PATH"
        sudo unsquashfs -d "$ROOTFS_DIR" "$SQUASHFS_PATH"
    else
        log "No squashfs found, using the ISO contents directly."
        mkdir -p "$ROOTFS_DIR"
        rsync -a "$BUILD_DIR/iso/" "$ROOTFS_DIR/"
    fi
}

# ============================================================
# 3. PREPARE THE CHROOT ENVIRONMENT AND OPEN IT FOR CUSTOMIZATION
# ============================================================
enter_chroot() {
    log "Binding system directories for chroot..."
    sudo mount --bind /dev "$ROOTFS_DIR/dev"
    sudo mount --bind /proc "$ROOTFS_DIR/proc"
    sudo mount --bind /sys "$ROOTFS_DIR/sys"

    # --------------------------------------------------------
    # CUSTOMIZATION AREA
    # Forkers can add their own automated setup commands in the
    # block below. Example:
    #
    #   sudo chroot "$ROOTFS_DIR" bash -c '
    #       apt update
    #       apt install -y neofetch
    #   '
    # --------------------------------------------------------

    log "Entering chroot. Type 'exit' to leave."
    # "|| true": if the last command you ran inside chroot exits non-zero,
    # that becomes this line's exit status. Without "|| true", set -e would
    # abort the whole script right here and skip the unmounts below.
    sudo chroot "$ROOTFS_DIR" bash || true

    log "Unmounting chroot directories..."
    # /dev, /proc, /sys MUST be unmounted before repacking — otherwise
    # mksquashfs would bake live device nodes and /proc entries from this
    # machine into the new image. "-R" catches any nested mounts a package
    # manager may have created inside them; "|| true" keeps a busy mount
    # from aborting the script (cleanup() below is the final safety net).
    sudo umount -R "$ROOTFS_DIR/dev" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
}

# ============================================================
# 4. REPACK THE MODIFIED ROOT FILESYSTEM
# ============================================================
repack_rootfs() {
    if [ -n "$SQUASHFS_PATH" ]; then
        log "Rebuilding squashfs..."
        sudo mksquashfs "$ROOTFS_DIR" "$SQUASHFS_PATH.new" -comp zstd -noappend
        sudo mv "$SQUASHFS_PATH.new" "$SQUASHFS_PATH"
    else
        log "Copying changes back into the ISO folder..."
        sudo rsync -a --delete "$ROOTFS_DIR/" "$BUILD_DIR/iso/"
    fi
}

# ============================================================
# 5. BUILD THE NEW ISO
# ============================================================
build_iso() {
    log "Reading the original ISO's boot configuration..."
    # Instead of guessing where isolinux/GRUB/EFI files live (which breaks
    # on distros that use a different layout), ask xorriso to read the
    # source ISO's actual El Torito boot record and hand back the exact
    # mkisofs-equivalent options needed to reproduce it. This works
    # regardless of directory naming conventions across distros, and
    # correctly reproduces BIOS-only, UEFI-only, or hybrid boot setups.
    local boot_opts_file="$BUILD_DIR/boot_opts.txt"
    # Drop the original ISO's own -V line — otherwise it would override our
    # VOLUME_LABEL setting, since it appears later on the command line.
    xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null \
        | grep '^-' | grep -v "^-V " > "$boot_opts_file" || true

    log "Building new ISO: $OUTPUT_ISO"
    if [ -s "$boot_opts_file" ]; then
        log "Reproducing the original boot record (BIOS/UEFI as applicable)"
        # printf %q shell-escapes VOLUME_LABEL safely (handles spaces and
        # quotes) before it goes through eval — the earlier version wrapped
        # it in a literal "'...'" instead, which broke on labels with spaces.
        local esc_label
        printf -v esc_label '%q' "$VOLUME_LABEL"
        # shellcheck disable=SC2046,SC2086
        eval sudo xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$esc_label" -r -J \
            "$(tr '\n' ' ' < "$boot_opts_file")" \
            "$BUILD_DIR/iso/"
    else
        log "Source ISO has no El Torito boot record; building a data-only ISO"
        sudo xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$VOLUME_LABEL" -r -J "$BUILD_DIR/iso/"
    fi
    sudo chown "${SUDO_USER:-$USER}" "$OUTPUT_ISO"
    log "Done: $OUTPUT_ISO"
}

# ============================================================
# MAIN FLOW
# ============================================================
main() {
    check_dependencies
    check_input
    extract_iso
    extract_rootfs
    enter_chroot
    repack_rootfs
    build_iso
}

main
