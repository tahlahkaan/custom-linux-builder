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
# CONFIGURATION
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
# IMPROVEMENT: Added /run and /tmp to the cleanup list for modern systems.
cleanup() {
    log "Cleaning up..."
    if [ -n "$ROOTFS_DIR" ] && mountpoint -q "$ROOTFS_DIR/run" 2>/dev/null; then
        sudo umount -R "$ROOTFS_DIR/run" 2>/dev/null || true
    fi
    if [ -n "$ROOTFS_DIR" ] && mountpoint -q "$ROOTFS_DIR/tmp" 2>/dev/null; then
        sudo umount -R "$ROOTFS_DIR/tmp" 2>/dev/null || true
    fi
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
# IMPROVED: Detect the original compression algorithm of the squashfs.
# Uses awk instead of grep -P for maximum POSIX portability.
# ============================================================
get_original_comp() {
    local squashfs="$1"
    unsquashfs -s "$squashfs" 2>/dev/null | awk -F': *' '/Compression/ {print $2; exit}'
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
# 2. LOCATE AND UNPACK THE SQUASHFS
# IMPROVEMENT: Extended search paths for Fedora, Arch, openSUSE,
# Gentoo, Alpine, and other major distributions.
# ============================================================
extract_rootfs() {
    log "Looking for the root filesystem (squashfs)..."

    # Common distribution paths (Ubuntu, Debian, Fedora, Arch, openSUSE, Gentoo, Alpine, etc.)
    local possible_paths=(
        "$BUILD_DIR/iso/casper/filesystem.squashfs"          # Ubuntu / Debian
        "$BUILD_DIR/iso/live/filesystem.squashfs"            # Debian Live
        "$BUILD_DIR/iso/LiveOS/squashfs.img"                 # Fedora / RHEL
        "$BUILD_DIR/iso/images/rootfs.img"                   # Arch Linux (iso)
        "$BUILD_DIR/iso/rootfs.squashfs"                     # Alpine / NixOS
        "$BUILD_DIR/iso/system.squashfs"                     # openSUSE
        "$BUILD_DIR/iso/livecd.squashfs"                     # Gentoo
        "$BUILD_DIR/iso/rootfs.img"                          # Custom minimal ISOs
        "$BUILD_DIR/iso/filesystem.squashfs"                 # Generic path
    )
    SQUASHFS_PATH=""
    for p in "${possible_paths[@]}"; do
        if [ -f "$p" ]; then
            SQUASHFS_PATH="$p"
            break
        fi
    done

    # If none found, fallback to a generic find (head -1 is POSIX-safe)
    if [ -z "$SQUASHFS_PATH" ]; then
        SQUASHFS_PATH="$(find "$BUILD_DIR/iso" \( -name "*.squashfs" -o -name "squashfs.img" -o -name "rootfs.img" \) | head -1)"
    fi

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
# 3. PREPARE THE CHROOT ENVIRONMENT
# IMPROVEMENT: Bind /run and /tmp for modern init systems (systemd, snap, flatpak).
# Also ensures the target directories exist inside the chroot.
# ============================================================
enter_chroot() {
    log "Binding system directories for chroot..."

    # Ensure target mount points exist inside the chroot
    sudo mkdir -p "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run" "$ROOTFS_DIR/tmp"

    sudo mount --bind /dev "$ROOTFS_DIR/dev"
    sudo mount --bind /proc "$ROOTFS_DIR/proc"
    sudo mount --bind /sys "$ROOTFS_DIR/sys"
    sudo mount --bind /run "$ROOTFS_DIR/run"
    sudo mount --bind /tmp "$ROOTFS_DIR/tmp"

    log "Entering chroot. Type 'exit' to leave."
    sudo chroot "$ROOTFS_DIR" bash || true

    log "Unmounting chroot directories..."
    # Unmount in reverse order
    sudo umount -R "$ROOTFS_DIR/tmp" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/run" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/dev" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
}

# ============================================================
# 4. REPACK THE MODIFIED ROOT FILESYSTEM
# IMPROVEMENT: Uses the original compression algorithm dynamically.
# If the original is unknown or unsupported by the local system,
# it safely falls back to "gzip" (the most universally supported).
# ============================================================
repack_rootfs() {
    if [ -n "$SQUASHFS_PATH" ]; then
        log "Rebuilding squashfs..."

        local comp
        comp=$(get_original_comp "$SQUASHFS_PATH")

        # Fallback to gzip if detection fails (gzip is universally supported)
        if [ -z "$comp" ]; then
            comp="gzip"
            log "Could not detect original compression, using gzip as fallback."
        else
            log "Detected compression: $comp"
            # Verify that the current mksquashfs supports this algorithm
            if ! mksquashfs -comp help 2>/dev/null | grep -q "\b$comp\b"; then
                log "WARNING: $comp is not supported by this mksquashfs. Falling back to gzip."
                comp="gzip"
            fi
        fi

        sudo mksquashfs "$ROOTFS_DIR" "$SQUASHFS_PATH.new" -comp "$comp" -noappend
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
    local boot_opts_file="$BUILD_DIR/boot_opts.txt"
    xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null \
        | grep '^-' | grep -v "^-V " > "$boot_opts_file" || true

    log "Building new ISO: $OUTPUT_ISO"
    if [ -s "$boot_opts_file" ]; then
        log "Reproducing the original boot record (BIOS/UEFI as applicable)"
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
