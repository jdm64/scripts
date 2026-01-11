#!/bin/bash
#
# drive-transfer.sh - Linux Drive Transfer Tool
#
# A CLI tool to help transfer a Linux installation from one drive to another.
# Uses whiptail for graphical terminal interface and generates a script for
# the user to review and execute.
#
# Requirements: whiptail, lsblk, blkid, rsync (all pre-installed on Debian/Ubuntu)
#
# Usage: sudo ./drive-transfer.sh
#

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_VERSION="1.0.0"
WORK_DIR="/tmp/drive-transfer-$$"

# Default rsync excludes
declare -a DEFAULT_EXCLUDES=(
    "/dev/*"
    "/proc/*"
    "/sys/*"
    "/tmp/*"
    "/run/*"
    "/mnt/*"
    "/media/*"
    "/lost+found"
    "/swapfile"
)

# Optional excludes (off by default)
declare -a OPTIONAL_EXCLUDES=(
    "/var/cache/*"
    "/var/tmp/*"
    "/home/*/.cache/*"
)

# Selected excludes (will be populated by user)
declare -a SELECTED_EXCLUDES=()

# Partition mappings
declare -a SRC_PARTS=()
declare -a DST_PARTS=()
declare -a FS_TYPES=()
declare -a SRC_UUIDS=()
declare -a DST_UUIDS=()

# Selected drives and partitions
SRC_DRIVE=""
DST_DRIVE=""
ROOT_PART_IDX=""
EFI_PART_IDX=""
OUTPUT_SCRIPT=""

# =============================================================================
# Utility Functions
# =============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root (sudo)"
        exit 1
    fi
}

# Check for required tools
check_dependencies() {
    local missing=()
    for cmd in whiptail lsblk blkid rsync mount umount sed chroot; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required tools: ${missing[*]}"
        exit 1
    fi
}

# Get terminal dimensions for whiptail
get_terminal_size() {
    TERM_HEIGHT=$(tput lines)
    TERM_WIDTH=$(tput cols)
    # Cap dimensions for whiptail
    [[ $TERM_HEIGHT -gt 40 ]] && TERM_HEIGHT=40
    [[ $TERM_WIDTH -gt 100 ]] && TERM_WIDTH=100
    [[ $TERM_HEIGHT -lt 20 ]] && TERM_HEIGHT=20
    [[ $TERM_WIDTH -lt 60 ]] && TERM_WIDTH=60
}

# Show error message
show_error() {
    whiptail --title "Error" --msgbox "$1" 10 60
}

# Show info message
show_info() {
    whiptail --title "Information" --msgbox "$1" 10 60
}

# Get list of drives (excluding loop devices and partitions)
get_drives() {
    lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | grep -E '^/dev/(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z])' | while read -r line; do
        local dev=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local model=$(echo "$line" | cut -d' ' -f3-)
        [[ -z "$model" ]] && model="Unknown"
        echo "$dev"
        echo "$size - $model"
    done
}

# Get partitions for a drive
get_partitions() {
    local drive="$1"
    lsblk -pno NAME,SIZE,FSTYPE "$drive" 2>/dev/null | tail -n +2 | while read -r line; do
        local part=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local fstype=$(echo "$line" | awk '{print $3}')
        [[ -z "$fstype" ]] && fstype="unknown"
        echo "$part $size $fstype"
    done
}

# Get filesystem type for a partition
get_fstype() {
    local part="$1"
    blkid -s TYPE -o value "$part" 2>/dev/null || echo "unknown"
}

# Get UUID for a partition
get_uuid() {
    local part="$1"
    blkid -s UUID -o value "$part" 2>/dev/null || echo ""
}

# Get partition label
get_label() {
    local part="$1"
    blkid -s LABEL -o value "$part" 2>/dev/null || echo ""
}

# =============================================================================
# UI Functions
# =============================================================================

# Welcome screen
show_welcome() {
    whiptail --title "Linux Drive Transfer Tool v$SCRIPT_VERSION" --yesno \
"This tool will help you transfer a Linux installation from one drive to another.

The process involves:
1. Selecting source and destination drives
2. Mapping partitions between drives
3. Configuring rsync excludes
4. Generating a transfer script

IMPORTANT:
- Partitions must already exist on the destination drive
- The destination drive will have data overwritten
- A script will be generated for you to review before execution

Do you want to continue?" 20 70
    
    return $?
}

# Select source drive
select_source_drive() {
    get_terminal_size
    
    local drives_output
    drives_output=$(get_drives)
    
    if [[ -z "$drives_output" ]]; then
        show_error "No drives found on the system."
        exit 1
    fi
    
    local menu_items=()
    while IFS= read -r dev && IFS= read -r desc; do
        menu_items+=("$dev" "$desc")
    done <<< "$drives_output"
    
    SRC_DRIVE=$(whiptail --title "Select Source Drive" \
        --menu "Choose the drive to copy FROM (source):" \
        $TERM_HEIGHT $TERM_WIDTH $((TERM_HEIGHT - 8)) \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || exit 1
}

# Select destination drive
select_dest_drive() {
    get_terminal_size
    
    local drives_output
    drives_output=$(get_drives)
    
    local menu_items=()
    while IFS= read -r dev && IFS= read -r desc; do
        # Exclude source drive from options
        if [[ "$dev" != "$SRC_DRIVE" ]]; then
            menu_items+=("$dev" "$desc")
        fi
    done <<< "$drives_output"
    
    if [[ ${#menu_items[@]} -eq 0 ]]; then
        show_error "No other drives available for destination."
        exit 1
    fi
    
    DST_DRIVE=$(whiptail --title "Select Destination Drive" \
        --menu "Choose the drive to copy TO (destination):\n\nWARNING: Data on this drive will be overwritten!" \
        $TERM_HEIGHT $TERM_WIDTH $((TERM_HEIGHT - 8)) \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || exit 1
}

# Build partition mapping
build_partition_mapping() {
    # Get source partitions
    local src_parts_raw
    src_parts_raw=$(get_partitions "$SRC_DRIVE")
    
    # Get destination partitions
    local dst_parts_raw
    dst_parts_raw=$(get_partitions "$DST_DRIVE")
    
    # Parse into arrays
    SRC_PARTS=()
    DST_PARTS=()
    FS_TYPES=()
    SRC_UUIDS=()
    DST_UUIDS=()
    
    while read -r line; do
        [[ -z "$line" ]] && continue
        local part=$(echo "$line" | awk '{print $1}')
        local fstype=$(echo "$line" | awk '{print $3}')
        SRC_PARTS+=("$part")
        FS_TYPES+=("$fstype")
        SRC_UUIDS+=("$(get_uuid "$part")")
    done <<< "$src_parts_raw"
    
    local idx=0
    while read -r line; do
        [[ -z "$line" ]] && continue
        local part=$(echo "$line" | awk '{print $1}')
        DST_PARTS+=("$part")
        DST_UUIDS+=("$(get_uuid "$part")")
        ((idx++))
    done <<< "$dst_parts_raw"
}

# Display and confirm partition mapping
confirm_partition_mapping() {
    get_terminal_size
    
    local mapping_text="Partition Mapping (Source -> Destination):\n\n"
    local max_parts=${#SRC_PARTS[@]}
    [[ ${#DST_PARTS[@]} -gt $max_parts ]] && max_parts=${#DST_PARTS[@]}
    
    for ((i=0; i<max_parts; i++)); do
        local src_part="${SRC_PARTS[$i]:-'(none)'}"
        local dst_part="${DST_PARTS[$i]:-'(none)'}"
        local fstype="${FS_TYPES[$i]:-'?'}"
        
        local src_size=""
        local dst_size=""
        [[ -n "${SRC_PARTS[$i]}" ]] && src_size=$(lsblk -no SIZE "${SRC_PARTS[$i]}" 2>/dev/null | head -1)
        [[ -n "${DST_PARTS[$i]}" ]] && dst_size=$(lsblk -no SIZE "${DST_PARTS[$i]}" 2>/dev/null | head -1)
        
        mapping_text+="$((i+1)). $src_part ($src_size, $fstype) -> $dst_part ($dst_size)\n"
    done
    
    if [[ ${#SRC_PARTS[@]} -ne ${#DST_PARTS[@]} ]]; then
        mapping_text+="\n⚠ WARNING: Partition counts differ!\n"
        mapping_text+="Source: ${#SRC_PARTS[@]} partitions, Destination: ${#DST_PARTS[@]} partitions\n"
    fi
    
    mapping_text+="\nIs this mapping correct?"
    
    if whiptail --title "Confirm Partition Mapping" --yesno "$mapping_text" $TERM_HEIGHT $TERM_WIDTH; then
        return 0
    else
        return 1
    fi
}

# Edit partition mapping
edit_partition_mapping() {
    get_terminal_size
    
    local num_src=${#SRC_PARTS[@]}
    
    for ((i=0; i<num_src; i++)); do
        local src_part="${SRC_PARTS[$i]}"
        local fstype="${FS_TYPES[$i]}"
        local current_dst="${DST_PARTS[$i]:-'(unmapped)'}"
        
        # Build menu of destination partitions
        local menu_items=()
        menu_items+=("SKIP" "Do not copy this partition")
        
        for dst_part in "${DST_PARTS[@]}"; do
            local dst_size=$(lsblk -no SIZE "$dst_part" 2>/dev/null | head -1)
            local dst_fstype=$(get_fstype "$dst_part")
            menu_items+=("$dst_part" "$dst_size $dst_fstype")
        done
        
        local selected
        selected=$(whiptail --title "Map Partition $((i+1))" \
            --menu "Select destination for $src_part ($fstype):\n\nCurrent: $current_dst" \
            $TERM_HEIGHT $TERM_WIDTH $((TERM_HEIGHT - 10)) \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || continue
        
        if [[ "$selected" == "SKIP" ]]; then
            DST_PARTS[$i]=""
        else
            DST_PARTS[$i]="$selected"
        fi
    done
}

# Detect root partition
detect_root_partition() {
    ROOT_PART_IDX=""
    
    # Create temp mount point
    local tmp_mount="$WORK_DIR/detect"
    mkdir -p "$tmp_mount"
    
    for ((i=0; i<${#SRC_PARTS[@]}; i++)); do
        local part="${SRC_PARTS[$i]}"
        local fstype="${FS_TYPES[$i]}"
        
        # Skip swap and unmountable types
        [[ "$fstype" == "swap" ]] && continue
        [[ "$fstype" == "unknown" ]] && continue
        [[ -z "$fstype" ]] && continue
        
        # Try to mount and check for /etc/fstab
        if mount -o ro "$part" "$tmp_mount" 2>/dev/null; then
            if [[ -f "$tmp_mount/etc/fstab" ]]; then
                ROOT_PART_IDX=$i
                umount "$tmp_mount" 2>/dev/null
                break
            fi
            umount "$tmp_mount" 2>/dev/null
        fi
    done
    
    rmdir "$tmp_mount" 2>/dev/null || true
}

# Confirm or select root partition
select_root_partition() {
    get_terminal_size
    
    detect_root_partition
    
    local detected_msg=""
    if [[ -n "$ROOT_PART_IDX" ]]; then
        detected_msg="Detected root partition: ${SRC_PARTS[$ROOT_PART_IDX]}\n\n"
    else
        detected_msg="Could not auto-detect root partition.\n\n"
    fi
    
    # Build menu
    local menu_items=()
    for ((i=0; i<${#SRC_PARTS[@]}; i++)); do
        local part="${SRC_PARTS[$i]}"
        local fstype="${FS_TYPES[$i]}"
        local size=$(lsblk -no SIZE "$part" 2>/dev/null | head -1)
        
        # Skip swap
        [[ "$fstype" == "swap" ]] && continue
        
        local marker=""
        [[ "$i" == "$ROOT_PART_IDX" ]] && marker=" [DETECTED]"
        
        menu_items+=("$i" "$part ($size, $fstype)$marker")
    done
    
    local selected
    selected=$(whiptail --title "Select Root Partition" \
        --menu "${detected_msg}Select the partition containing the root filesystem (/):" \
        $TERM_HEIGHT $TERM_WIDTH $((TERM_HEIGHT - 10)) \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || exit 1
    
    ROOT_PART_IDX="$selected"
}

# Select EFI partition
select_efi_partition() {
    get_terminal_size
    
    # Try to auto-detect EFI partition (vfat, typically small, mounted at /boot/efi)
    local detected_efi=""
    for ((i=0; i<${#SRC_PARTS[@]}; i++)); do
        local fstype="${FS_TYPES[$i]}"
        if [[ "$fstype" == "vfat" ]]; then
            detected_efi=$i
            break
        fi
    done
    
    local detected_msg=""
    if [[ -n "$detected_efi" ]]; then
        detected_msg="Detected EFI partition: ${SRC_PARTS[$detected_efi]}\n\n"
    else
        detected_msg="Could not auto-detect EFI partition.\n\n"
    fi
    
    # Build menu
    local menu_items=()
    menu_items+=("NONE" "No EFI partition (BIOS/Legacy boot)")
    
    for ((i=0; i<${#SRC_PARTS[@]}; i++)); do
        local part="${SRC_PARTS[$i]}"
        local fstype="${FS_TYPES[$i]}"
        local size=$(lsblk -no SIZE "$part" 2>/dev/null | head -1)
        
        local marker=""
        [[ "$i" == "$detected_efi" ]] && marker=" [DETECTED]"
        
        menu_items+=("$i" "$part ($size, $fstype)$marker")
    done
    
    local selected
    selected=$(whiptail --title "Select EFI Partition" \
        --menu "${detected_msg}Select the EFI System Partition (ESP):" \
        $TERM_HEIGHT $TERM_WIDTH $((TERM_HEIGHT - 10)) \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || exit 1
    
    if [[ "$selected" == "NONE" ]]; then
        EFI_PART_IDX=""
    else
        EFI_PART_IDX="$selected"
    fi
}

# Configure rsync excludes
configure_excludes() {
    get_terminal_size
    
    # Build checklist items
    local checklist_items=()
    
    # Default excludes (ON by default)
    for excl in "${DEFAULT_EXCLUDES[@]}"; do
        local desc=""
        case "$excl" in
            "/dev/*") desc="Device files (required)" ;;
            "/proc/*") desc="Process info (required)" ;;
            "/sys/*") desc="System info (required)" ;;
            "/tmp/*") desc="Temporary files" ;;
            "/run/*") desc="Runtime data" ;;
            "/mnt/*") desc="Mount points" ;;
            "/media/*") desc="Removable media" ;;
            "/lost+found") desc="Lost files directory" ;;
            "/swapfile") desc="Swap file" ;;
            *) desc="Exclude path" ;;
        esac
        checklist_items+=("$excl" "$desc" "ON")
    done
    
    # Optional excludes (OFF by default)
    for excl in "${OPTIONAL_EXCLUDES[@]}"; do
        local desc=""
        case "$excl" in
            "/var/cache/*") desc="Package cache" ;;
            "/var/tmp/*") desc="Var temp files" ;;
            "/home/*/.cache/*") desc="User cache dirs" ;;
            *) desc="Optional exclude" ;;
        esac
        checklist_items+=("$excl" "$desc" "OFF")
    done
    
    local selected
    selected=$(whiptail --title "Configure Rsync Excludes" \
        --checklist "Select directories to EXCLUDE from transfer:\n(Space to toggle, Enter to confirm)" \
        $TERM_HEIGHT $TERM_WIDTH $((TERM_HEIGHT - 10)) \
        "${checklist_items[@]}" \
        3>&1 1>&2 2>&3) || exit 1
    
    # Parse selected excludes
    SELECTED_EXCLUDES=()
    # Remove quotes and parse
    selected=$(echo "$selected" | tr -d '"')
    for excl in $selected; do
        SELECTED_EXCLUDES+=("$excl")
    done
    
    # Ask for custom excludes
    local custom
    custom=$(whiptail --title "Custom Excludes" \
        --inputbox "Enter additional paths to exclude (comma-separated):\n\nExample: /home/user/Downloads,/var/log/journal" \
        12 70 "" \
        3>&1 1>&2 2>&3) || true
    
    if [[ -n "$custom" ]]; then
        IFS=',' read -ra custom_arr <<< "$custom"
        for excl in "${custom_arr[@]}"; do
            # Trim whitespace
            excl=$(echo "$excl" | xargs)
            [[ -n "$excl" ]] && SELECTED_EXCLUDES+=("$excl")
        done
    fi
}

# Select output script location
select_output_location() {
    get_terminal_size
    
    local default_path="$(pwd)/drive-transfer-run.sh"
    
    OUTPUT_SCRIPT=$(whiptail --title "Script Output Location" \
        --inputbox "Enter the path for the generated transfer script:" \
        10 70 "$default_path" \
        3>&1 1>&2 2>&3) || exit 1
    
    # Validate path
    local output_dir=$(dirname "$OUTPUT_SCRIPT")
    if [[ ! -d "$output_dir" ]]; then
        if whiptail --title "Create Directory?" --yesno \
            "Directory $output_dir does not exist.\n\nCreate it?" 10 60; then
            mkdir -p "$output_dir"
        else
            show_error "Cannot write to $OUTPUT_SCRIPT"
            exit 1
        fi
    fi
}

# Generate command preview
generate_preview() {
    local preview=""
    
    preview+="# Drive Transfer Script Preview\n"
    preview+="# ==============================\n\n"
    preview+="# Source: $SRC_DRIVE\n"
    preview+="# Destination: $DST_DRIVE\n"
    preview+="# Root partition: ${SRC_PARTS[$ROOT_PART_IDX]} -> ${DST_PARTS[$ROOT_PART_IDX]}\n"
    [[ -n "$EFI_PART_IDX" ]] && preview+="# EFI partition: ${SRC_PARTS[$EFI_PART_IDX]} -> ${DST_PARTS[$EFI_PART_IDX]}\n"
    preview+="\n"
    
    preview+="# Partition Mappings:\n"
    for ((i=0; i<${#SRC_PARTS[@]}; i++)); do
        local src="${SRC_PARTS[$i]}"
        local dst="${DST_PARTS[$i]}"
        local fstype="${FS_TYPES[$i]}"
        
        if [[ -z "$dst" ]]; then
            preview+="#   $src ($fstype) -> SKIP\n"
        elif [[ "$fstype" == "swap" ]]; then
            preview+="#   $src ($fstype) -> $dst (fstab only)\n"
        else
            preview+="#   $src ($fstype) -> $dst (rsync)\n"
        fi
    done
    preview+="\n"
    
    preview+="# Rsync Excludes:\n"
    for excl in "${SELECTED_EXCLUDES[@]}"; do
        preview+="#   $excl\n"
    done
    preview+="\n"
    
    preview+="# Commands to be generated:\n"
    preview+="# 1. Mount source and destination partitions\n"
    preview+="# 2. rsync files for each partition\n"
    preview+="# 3. Update /etc/fstab with new UUIDs\n"
    [[ -n "$EFI_PART_IDX" ]] && preview+="# 4. Install GRUB bootloader (EFI)\n"
    preview+="# 5. Cleanup mount points\n"
    
    echo -e "$preview"
}

# Show preview and confirm
confirm_preview() {
    get_terminal_size
    
    local preview
    preview=$(generate_preview)
    
    whiptail --title "Command Preview" --scrolltext --yesno \
        "$preview\n\nGenerate the transfer script?" \
        $TERM_HEIGHT $TERM_WIDTH
    
    return $?
}

# =============================================================================
# Script Generation
# =============================================================================

generate_script() {
    cat > "$OUTPUT_SCRIPT" << 'SCRIPT_HEADER'
#!/bin/bash
#
# Drive Transfer Script
# Generated by drive-transfer.sh
#
SCRIPT_HEADER

    cat >> "$OUTPUT_SCRIPT" << SCRIPT_INFO
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Source Drive: $SRC_DRIVE
# Destination Drive: $DST_DRIVE
#

set -e

# =============================================================================
# USAGE
# =============================================================================
# Run normally:     sudo $OUTPUT_SCRIPT
# Dry-run mode:     sudo $OUTPUT_SCRIPT --dry-run
#
# Dry-run will show what rsync would copy without actually transferring files.
# Fstab and grub steps are skipped in dry-run mode.
# =============================================================================

SCRIPT_INFO

    cat >> "$OUTPUT_SCRIPT" << 'SCRIPT_DRYRUN'
DRY_RUN=false
if [[ "$1" == "--dry-run" ]] || [[ "$1" == "-n" ]]; then
    DRY_RUN=true
    echo "=========================================="
    echo "*** DRY-RUN MODE ***"
    echo "No files will be transferred"
    echo "Fstab and GRUB steps will be skipped"
    echo "=========================================="
    echo ""
fi

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

SCRIPT_DRYRUN

    # Write configuration
    cat >> "$OUTPUT_SCRIPT" << SCRIPT_CONFIG
# =============================================================================
# Configuration
# =============================================================================

SRC_DRIVE="$SRC_DRIVE"
DST_DRIVE="$DST_DRIVE"
ROOT_PART_IDX=$ROOT_PART_IDX
EFI_PART_IDX="${EFI_PART_IDX:-}"

# Partition mappings
declare -a SRC_PARTS=($(printf '"%s" ' "${SRC_PARTS[@]}"))
declare -a DST_PARTS=($(printf '"%s" ' "${DST_PARTS[@]}"))
declare -a FS_TYPES=($(printf '"%s" ' "${FS_TYPES[@]}"))
declare -a SRC_UUIDS=($(printf '"%s" ' "${SRC_UUIDS[@]}"))
declare -a DST_UUIDS=($(printf '"%s" ' "${DST_UUIDS[@]}"))

# Rsync excludes
declare -a EXCLUDES=($(printf '"%s" ' "${SELECTED_EXCLUDES[@]}"))

SCRIPT_CONFIG

    cat >> "$OUTPUT_SCRIPT" << 'SCRIPT_FUNCTIONS'
# =============================================================================
# Functions
# =============================================================================

WORK_DIR="/tmp/drive-transfer-$$"

cleanup() {
    echo ""
    echo "Cleaning up mount points..."
    
    # Unmount in reverse order
    for ((i=${#SRC_PARTS[@]}-1; i>=0; i--)); do
        umount "$WORK_DIR/src/part$i" 2>/dev/null || true
        umount "$WORK_DIR/dst/part$i" 2>/dev/null || true
    done
    
    # Unmount chroot binds if they exist
    umount "$WORK_DIR/dst/part$ROOT_PART_IDX/dev/pts" 2>/dev/null || true
    umount "$WORK_DIR/dst/part$ROOT_PART_IDX/dev" 2>/dev/null || true
    umount "$WORK_DIR/dst/part$ROOT_PART_IDX/proc" 2>/dev/null || true
    umount "$WORK_DIR/dst/part$ROOT_PART_IDX/sys" 2>/dev/null || true
    umount "$WORK_DIR/dst/part$ROOT_PART_IDX/run" 2>/dev/null || true
    
    # Remove work directory
    rm -rf "$WORK_DIR" 2>/dev/null || true
    
    echo "Cleanup complete."
}

trap cleanup EXIT

build_exclude_args() {
    local args=""
    for excl in "${EXCLUDES[@]}"; do
        args="$args --exclude='$excl'"
    done
    echo "$args"
}

do_rsync() {
    local src="$1"
    local dst="$2"
    local rsync_opts="-aAXHv --progress --info=progress2"
    
    if [[ "$DRY_RUN" == true ]]; then
        rsync_opts="$rsync_opts --dry-run"
        echo "[DRY-RUN] Would sync: $src -> $dst"
    fi
    
    local exclude_args=$(build_exclude_args)
    eval rsync $rsync_opts $exclude_args "$src" "$dst"
}

SCRIPT_FUNCTIONS

    cat >> "$OUTPUT_SCRIPT" << 'SCRIPT_MAIN'
# =============================================================================
# Main Script
# =============================================================================

echo "=========================================="
echo "Linux Drive Transfer Script"
echo "=========================================="
echo ""
echo "Source: $SRC_DRIVE"
echo "Destination: $DST_DRIVE"
echo ""

# Create work directory
mkdir -p "$WORK_DIR"/{src,dst}

# =============================================================================
# Step 1: Mount and Copy Partitions
# =============================================================================

echo "=== Step 1: Mounting and copying partitions ==="
echo ""

for ((i=0; i<${#SRC_PARTS[@]}; i++)); do
    src_part="${SRC_PARTS[$i]}"
    dst_part="${DST_PARTS[$i]}"
    fstype="${FS_TYPES[$i]}"
    
    echo "--- Partition $((i+1)): $src_part -> $dst_part ($fstype) ---"
    
    # Skip if no destination mapping
    if [[ -z "$dst_part" ]]; then
        echo "Skipping (no destination mapped)"
        echo ""
        continue
    fi
    
    # Skip swap partitions (no files to copy)
    if [[ "$fstype" == "swap" ]]; then
        echo "Skipping swap partition (will update fstab only)"
        echo ""
        continue
    fi
    
    # Create mount points
    mkdir -p "$WORK_DIR/src/part$i"
    mkdir -p "$WORK_DIR/dst/part$i"
    
    # Mount partitions
    echo "Mounting $src_part (read-only)..."
    mount -o ro "$src_part" "$WORK_DIR/src/part$i"
    
    echo "Mounting $dst_part..."
    mount "$dst_part" "$WORK_DIR/dst/part$i"
    
    # Rsync files
    echo "Syncing files..."
    do_rsync "$WORK_DIR/src/part$i/" "$WORK_DIR/dst/part$i/"
    
    echo "Done with partition $((i+1))"
    echo ""
done

# Exit early if dry-run
if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "=========================================="
    echo "*** DRY-RUN COMPLETE ***"
    echo "Fstab and GRUB steps were skipped"
    echo "Run without --dry-run to perform actual transfer"
    echo "=========================================="
    exit 0
fi

# =============================================================================
# Step 2: Update /etc/fstab
# =============================================================================

echo "=== Step 2: Updating /etc/fstab ==="
echo ""

FSTAB_PATH="$WORK_DIR/dst/part$ROOT_PART_IDX/etc/fstab"

if [[ ! -f "$FSTAB_PATH" ]]; then
    echo "Warning: /etc/fstab not found at $FSTAB_PATH"
else
    echo "Backing up original fstab..."
    cp "$FSTAB_PATH" "$FSTAB_PATH.bak"
    
    echo "Updating UUIDs in fstab..."
    for ((i=0; i<${#SRC_PARTS[@]}; i++)); do
        old_uuid="${SRC_UUIDS[$i]}"
        new_uuid="${DST_UUIDS[$i]}"
        
        if [[ -n "$old_uuid" ]] && [[ -n "$new_uuid" ]]; then
            echo "  Replacing $old_uuid -> $new_uuid"
            sed -i "s/$old_uuid/$new_uuid/g" "$FSTAB_PATH"
        fi
    done
    
    echo ""
    echo "Updated fstab contents:"
    echo "------------------------"
    cat "$FSTAB_PATH"
    echo "------------------------"
    echo ""
fi

SCRIPT_MAIN

    # Add GRUB installation if EFI partition is set
    if [[ -n "$EFI_PART_IDX" ]]; then
        cat >> "$OUTPUT_SCRIPT" << 'SCRIPT_GRUB'
# =============================================================================
# Step 3: Install GRUB Bootloader
# =============================================================================

echo "=== Step 3: Installing GRUB bootloader ==="
echo ""

ROOT_MOUNT="$WORK_DIR/dst/part$ROOT_PART_IDX"
EFI_MOUNT="$ROOT_MOUNT/boot/efi"

# Mount EFI partition inside root
echo "Mounting EFI partition..."
mkdir -p "$EFI_MOUNT"
mount "${DST_PARTS[$EFI_PART_IDX]}" "$EFI_MOUNT"

# Bind mount necessary filesystems for chroot
echo "Setting up chroot environment..."
mount --bind /dev "$ROOT_MOUNT/dev"
mount --bind /dev/pts "$ROOT_MOUNT/dev/pts"
mount --bind /proc "$ROOT_MOUNT/proc"
mount --bind /sys "$ROOT_MOUNT/sys"
mount --bind /run "$ROOT_MOUNT/run"

# Install GRUB
echo "Installing GRUB for EFI..."
chroot "$ROOT_MOUNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck

# Update GRUB configuration
echo "Updating GRUB configuration..."
chroot "$ROOT_MOUNT" update-grub

echo "GRUB installation complete."
echo ""

SCRIPT_GRUB
    fi

    cat >> "$OUTPUT_SCRIPT" << 'SCRIPT_FOOTER'
# =============================================================================
# Complete
# =============================================================================

echo "=========================================="
echo "Transfer Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Review the changes made to the destination drive"
echo "2. Reboot your system"
echo "3. Select the new drive in BIOS/UEFI boot menu"
echo "4. Verify the system boots correctly"
echo ""
echo "If you encounter boot issues, you may need to:"
echo "- Check BIOS/UEFI boot order"
echo "- Verify EFI entries with 'efibootmgr -v'"
echo "- Reinstall GRUB from a live USB"
echo ""
SCRIPT_FOOTER

    chmod +x "$OUTPUT_SCRIPT"
}

# =============================================================================
# Main Program
# =============================================================================

main() {
    # Initial checks
    check_root
    check_dependencies
    
    # Create work directory
    mkdir -p "$WORK_DIR"
    
    # Welcome screen
    if ! show_welcome; then
        echo "Cancelled by user."
        exit 0
    fi
    
    # Select drives
    select_source_drive
    select_dest_drive
    
    # Build and confirm partition mapping
    build_partition_mapping
    
    while ! confirm_partition_mapping; do
        edit_partition_mapping
    done
    
    # Select root and EFI partitions
    select_root_partition
    select_efi_partition
    
    # Configure excludes
    configure_excludes
    
    # Select output location
    select_output_location
    
    # Preview and confirm
    if ! confirm_preview; then
        echo "Cancelled by user."
        exit 0
    fi
    
    # Generate script
    generate_script
    
    # Cleanup work directory
    rmdir "$WORK_DIR" 2>/dev/null || true
    
    # Final message
    whiptail --title "Script Generated" --msgbox \
"Transfer script has been generated:

$OUTPUT_SCRIPT

To run the transfer:
  sudo $OUTPUT_SCRIPT

To test without making changes (dry-run):
  sudo $OUTPUT_SCRIPT --dry-run

Please review the script before running it!" 16 70
    
    echo ""
    echo "Script generated: $OUTPUT_SCRIPT"
    echo ""
    echo "To run: sudo $OUTPUT_SCRIPT"
    echo "Dry-run: sudo $OUTPUT_SCRIPT --dry-run"
    echo ""
}

# Run main program
main "$@"
