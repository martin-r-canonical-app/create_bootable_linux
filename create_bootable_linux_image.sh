#!/usr/bin/env bash
set -e
set -o pipefail

# ----------------------------------------------------------------------------
# Global state and variable initialization
# ----------------------------------------------------------------------------

# Allocate some FDs to point to the real stdout and stderr
exec {DEBUG_STDOUT_FD}>&1
exec {DEBUG_STDERR_FD}>&2

DEBUG=0
KEEP_TMP=0
PREPARE_ONLY=0
LOOP_DEVICE=""
DASHED_LINE="$(printf '%0.s-' {1..80} && printf '\n')"

# Temporary directory and file locations
# --------------------------------------
TMP_DIR="$(readlink -f "$(mktemp -d ./tmpdir.linuximage.XXXXXX)")"
CMD_LOG_DIR="${TMP_DIR}/cmd_logs"
mkdir -p "${CMD_LOG_DIR}"
TMP_IMG_FILE="${TMP_DIR}/linux.img"
PRIMARY_PARTITION_MOUNT="${TMP_DIR}/mnt/p1"

# Image parameters 
# ----------------
DEFAULT_OUTPUT_FILE="linux.img"
DISK_IMG_SIZE="50M"
BUSYBOX_URL="https://www.busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64"
KERNEL_URL="http://archive.ubuntu.com/ubuntu/pool/main/l/linux-signed/linux-image-5.15.0-117-generic_5.15.0-117.127_amd64.deb"


# ----------------------------------------------------------------------------
# Generic helper functions
# ----------------------------------------------------------------------------

debug_echo() {
    if [[ ${DEBUG} -eq 1 ]]; then
        echo "$@" >&"${DEBUG_STDOUT_FD}"
    fi
}

debug_printf() {
    if [[ ${DEBUG} -eq 1 ]]; then
        # shellcheck disable=SC2059
        printf "$@" >&"${DEBUG_STDOUT_FD}"
    fi
}

section_start() {
    local section_description="$1"

    if [[ ${DEBUG} -eq 1 ]]; then
        echo "${section_description} ..." >&"${DEBUG_STDOUT_FD}"
        echo "${DASHED_LINE}" >&"${DEBUG_STDOUT_FD}"
    else
        echo "${section_description} ..." >&"${DEBUG_STDOUT_FD}"
    fi
}

section_end() {
    if [[ ${DEBUG} -eq 1 ]]; then
        echo "... completed" >&"${DEBUG_STDOUT_FD}"
        echo >&"${DEBUG_STDOUT_FD}"
    else
        echo "  ... completed" >&"${DEBUG_STDOUT_FD}"
    fi
}

cleanup () {
    local quiet="$1"
    local original_exit_code="$2"

    # Disable the trap after first execution
    trap - SIGINT SIGTERM SIGQUIT SIGHUP EXIT

    if [[ ${quiet} != "quiet" ]]; then
        section_start "Cleaning up temporary resources"
        if [[ ${original_exit_code} ]]; then
            debug_echo "Original exit code ${original_exit_code}"
        fi
    fi

    if mountpoint -q "${PRIMARY_PARTITION_MOUNT}"; then
        sudo umount -R "${PRIMARY_PARTITION_MOUNT}"
    fi

    if [[ ${LOOP_DEVICE} ]]; then
        sudo losetup -d "${LOOP_DEVICE}"
    fi

    if [[ ${KEEP_TMP} -ne 1 ]]; then
        rm -rf "${TMP_DIR}"
    fi

    if [[ ${quiet} != "quiet" ]]; then
        section_end
    fi

    exec {DEBUG_STDERR_FD}>&-
    exec {DEBUG_STDOUT_FD}>&-
}

cleanup_exit () {
    local original_exit_code="$?"

    cleanup loud "${original_exit_code}"

    # Restore exit code
    exit "${original_exit_code}"
}

# Trap signals
trap cleanup_exit SIGINT SIGTERM SIGQUIT SIGHUP EXIT

run_and_debug() {
    local -a command=("$@")
    local command_exit_code
    local stdout_file
    local stderr_file

    # Create temporary files to capture stdout and stderr separately
    # NB: These are cleaned up in the general cleanup function.
    stdout_file="$(mktemp --tmpdir="${CMD_LOG_DIR}")"
    stderr_file="$(mktemp --tmpdir="${CMD_LOG_DIR}")"

    # Run the command, tee-ing stdout and stderr to separate files
    debug_printf 'Running command: '
    debug_printf '%q ' "${command[@]}"
    debug_printf '\n'
    debug_echo "  stdout: ${stdout_file}, stderr: ${stderr_file}"
    "$@" 2> >(tee "${stderr_file}" >&2) | tee "${stdout_file}" && true
    command_exit_code="$?"
    debug_echo "  finished with exit status: ${command_exit_code}"

    return "${command_exit_code}"
}

# ----------------------------------------------------------------------------
# Core functionality
# ----------------------------------------------------------------------------

# Function to display usage
usage() {
    echo "Usage: $0 [-o output_filename] [-v] [-h]"
    echo "  -o output_filename Specify the output filename (default is ${DEFAULT_OUTPUT_FILE})"
    echo "  -v                 Enable debug mode"
    echo "  -k                 Keep temporary logs and files"
    echo "  -p                 Prepare image, do NOT boot qemu"
    echo "  -h                 Display this help message"

    cleanup quiet
    exit 1
}

parse_cli() {
    local opt

    # Parse command-line options
    while getopts "hvpko:" opt; do
        case $opt in
            v)
                DEBUG=1  # Enable debug mode
                ;;
            k)
                KEEP_TMP=1  # Keep temporary logs and files
                ;;
            p)
                PREPARE_ONLY=1  # Prepare image, don't boot
                ;;
            o)
                OUTPUT_FILE="${OPTARG}"  # Set output filename
                ;;
            h)
                usage  # Display usage
                ;;
            *)
                usage  # Display usage for invalid options
                ;;
        esac
    done

    # Shift parsed options
    shift $((OPTIND - 1))

    # Check for unexpected positional arguments
    if [ "$#" -ne 0 ]; then
        echo "Error: Unexpected positional arguments: $*"
        usage
    fi

    if [[ ! ${OUTPUT_FILE} ]]; then
        OUTPUT_FILE="${DEFAULT_OUTPUT_FILE}"
    fi
}

section_disk_init() {
    run_and_debug qemu-img create -f raw "${TMP_IMG_FILE}" "${DISK_IMG_SIZE}" > /dev/null
    LOOP_DEVICE="$(run_and_debug sudo losetup -f --show "${TMP_IMG_FILE}")"
    debug_echo "Using loop device: ${LOOP_DEVICE}"
}

section_disk_partition_format() {
    # Create MBR partition table
    run_and_debug sudo parted "${LOOP_DEVICE}" mklabel msdos &> /dev/null
    # Create the primary partition
    run_and_debug sudo parted "${LOOP_DEVICE}" mkpart primary ext4 1MiB 100% &> /dev/null
    PRIMARY_PARTITION_LOOP="${LOOP_DEVICE}p1"
    # Set the boot flag on the primary partition, as we'll use this for boot too
    run_and_debug sudo parted "${LOOP_DEVICE}" set 1 boot on &> /dev/null
    # Format the primarty partition as ext4
    run_and_debug sudo mkfs.ext4 "${PRIMARY_PARTITION_LOOP}" &> /dev/null
}

section_install_fs() {
    mkdir -p "${PRIMARY_PARTITION_MOUNT}"
    sudo mount -o noatime,nodiratime "${PRIMARY_PARTITION_LOOP}" "${PRIMARY_PARTITION_MOUNT}"
    sudo mkdir -p "${PRIMARY_PARTITION_MOUNT}/"{dev,proc,sys}
    debug_echo "Primary partition mounted at: ${PRIMARY_PARTITION_MOUNT}"

    # Download BusyBox
    sudo mkdir -p "${PRIMARY_PARTITION_MOUNT}/usr/bin"
    run_and_debug sudo wget "${BUSYBOX_URL}" -O "${PRIMARY_PARTITION_MOUNT}/usr/bin/busybox" &> /dev/null
    sudo chmod +x "${PRIMARY_PARTITION_MOUNT}/usr/bin/busybox"

    debug_echo "Creating symlinks for BusyBox utilities"
    sudo mkdir -p "${PRIMARY_PARTITION_MOUNT}/"{bin,sbin,usr/bin,usr/sbin}
    "${PRIMARY_PARTITION_MOUNT}"/usr/bin/busybox --list-full | xargs -I {} -P "$(nproc)" sudo ln -s /usr/bin/busybox "${PRIMARY_PARTITION_MOUNT}/{}"
}

section_install_boot() {
    # Create GRUB configuration
    debug_echo "Creating GRUB configuration"
    sudo mkdir -p "${PRIMARY_PARTITION_MOUNT}"/boot/grub
cat << EOF | sudo tee "${PRIMARY_PARTITION_MOUNT}/boot/grub/grub.cfg" > /dev/null
set timeout=2
set default=0

menuentry "BusyBox Linux" {
    linux /boot/vmlinuz root=/dev/sda1 rw init=/init quiet console=ttyS0
}
EOF

    debug_echo "Downloading and installing kernel"
    run_and_debug wget "${KERNEL_URL}" -O "${TMP_DIR}/kernel.deb" &> /dev/null
    run_and_debug dpkg-deb -x "${TMP_DIR}/kernel.deb" "${TMP_DIR}/kernel" > /dev/null
    sudo cp "${TMP_DIR}/kernel/boot/vmlinuz-5.15.0-117-generic" "${PRIMARY_PARTITION_MOUNT}/boot/vmlinuz"

    debug_echo "Creating init script"
    cat << EOF | sudo tee "${PRIMARY_PARTITION_MOUNT}/init" > /dev/null
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo "Booted into BusyBox, use \\\`poweroff -f\\\` to shutdown"
echo "hello world"

# Stop errors about no job control
setsid  cttyhack sh

exec /bin/sh
EOF
    sudo chmod +x "${PRIMARY_PARTITION_MOUNT}/init"

    debug_echo "Installing GRUB"
    run_and_debug sudo grub-install \
        --target=i386-pc \
        --boot-directory="${PRIMARY_PARTITION_MOUNT}/boot" \
        --no-floppy \
        --modules=part_msdos \
        --root-directory="${PRIMARY_PARTITION_MOUNT}" \
        --force \
        "${LOOP_DEVICE}" \
        &> /dev/null
}

cleanup_exec_qemu() {
    ln -f "${TMP_IMG_FILE}" "${OUTPUT_FILE}"
    cleanup

    echo "Success"
    if [[ ${DEBUG} -eq 1 ]]; then
        echo "${DASHED_LINE}"
    fi
    echo "  Image created at: ${OUTPUT_FILE}"

    if [[ ${PREPARE_ONLY} -ne 1 ]]; then
        local qemu_cmd=(
            qemu-system-x86_64
            -drive "file=${OUTPUT_FILE},format=raw"
            -m 512m
            -smp 2
            -nographic
            -serial mon:stdio
        )

        echo "  Launching with qemu:"
        printf '     '
        printf '%q ' "${qemu_cmd[@]}"
        printf '\n'
        exec "${qemu_cmd[@]}"
    fi
}

main() {
    parse_cli "$@"

    debug_echo "Temporary directory: ${TMP_DIR}"
    debug_echo

    section_start "Creating base disk image"
    section_disk_init
    section_end

    section_start "Disk partitionning and formatting"
    section_disk_partition_format
    section_end

    section_start "Installing filesystem"
    section_install_fs
    section_end

    section_start "Installing kernel, init, and bootloader"
    section_install_boot
    section_end

    sync

    # Success! Save created image, cleanup, and exec into qemu
    # --------------------------------------------------------
    cleanup_exec_qemu
}

main "$@"
