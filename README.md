# Create Bootable Linux Image

## Provided specification

Bootable Linux image via QEMU

In this exercise you are expected to create a shell script that will run in a Linux environment (will be tested on Ubuntu 20.04 LTS or 22.04 LTS). This shell script should create and run an AMD64 Linux filesystem image using QEMU that will print “hello world” after successful startup. Bonus points for creating a fully bootable filesystem image (but not mandatory). The system shouldn’t contain any user/session management or prompt for login information to access the filesystem.  

You can use any version/flavor of the Linux kernel. The script can either download and build the kernel from source on the host environment or download a publicly available pre-built kernel.

The script shouldn’t ask for any user input unless superuser privileges are necessary for some functionality, therefore any additional information that you require for the script should be available in your repository.

The script should run within the working directory and not consume any other locations on the host file system.

## Considerations

There is ambiguity in the specification which may allow a wide-variety of solutions, and so the following choices are made:

- Filesystem image:
  - Chosen: A raw disk image, complete with MBR partition scheme and self-contained bootloader
  - Alternatives:
    - A simple root-filesystem, e.g. in a squashfs or cpio archive, without bootloader
- Partitioning of filesystem image
  - Chosen: A simple MBR with a single primary partition
  - Alternatives:
    - A GPT partition scheme, which would be required for EFI boot
    - More complex partitions to separate filesystem e.g. for boot, system, swap
- Contents of filesystem image:
  - Chosen: A minimial BusyBox system. NB: Due to the small size it's overkill to create a separate initramfs and instead can boot straight into the root partition.
  - Alternatives:
    - No userspace executables, either printing "hello world" from the kernel, or a init script
    - Minimal, but "complete", ubuntu filesystem (similar to server image), that doesn't contain any user or session management by replacing `/init` with a custom script
    - As above, but with `systemd` as init. Completely "removing" the user and session management is non-trivial, and so chosen to be out-of-scope, even though this would be the most feature rich option.
- Creation of filesystem image:
  - Chosen: Manual installation of BusyBox
  - Alternatives:
    - Use a pre-built rootfs
    - Use debootstrap (or similar) to install packages to a new root.
    - Install packages to a new root manually (essentially implementing debootstrap)

In addition the following assumptions are made:
- Host architecture is also `amd64`
- With respect to "[don't] consume any other locations on the host file system", the `losetup` tool will *represent* loop devices under `/dev`, but this unavoidable and not that disimilar to the way there will unavoidable representations elsewhere on the filesystem, e.g. under `/proc`. Any required temprary *storage* will be stored in a temporary directory under the CWD and cleaned up on process exit.
- It is acceptable to overwrite existing filesystem images if they already exist
- It is acceptable to use various host applications, notably `grub-pc`. These will likely be installed already, and should be checked by running `requirements.sh` to install any missing packages.
  
## Approach

- A raw disk image is created
- It is formatted with an MBR partition scheme and singular primary partition formatted as ext4
- Pre-built BusyBox is downloaded and installed to the primary partition
- Pre-build Kernel (5.15) is downloaded and installed to the primary partition (under the boot directory)
- The *host* grub application is used to install the bootloader onto the disk image

## Usage

One-time setup: Ensure required packages are installed by running `requirements.sh`.

```
$ ./create_bootable_linux_image.sh -h
Usage: ./create_bootable_linux_image.sh [-o output_filename] [-v] [-h]
  -o output_filename Specify the output filename (default is linux.img)
  -v                 Enable debug mode
  -k                 Keep temporary logs and files
  -p                 Prepare image, do NOT boot qemu
  -h                 Display this help message
```

Note: Error reporting is limited, so upon an error it is recommend you re-run with `-k` and `-v` to see what failed and inspect the relevant logs.

Example output:

```
$ ./create_bootable_linux_image.sh
Creating base disk image ...
  ... completed
Disk partitionning and formatting ...
  ... completed
Installing filesystem ...
  ... completed
Installing kernel, init, and bootloader ...
  ... completed
Cleaning up temporary resources ...
  ... completed
Success
  Image created at: linux.img
  Launching with qemu:
     qemu-system-x86_64 -drive file=linux.img\,format=raw -m 512m -smp 2 -nographic -serial mon:stdio
SeaBIOS (version 1.13.0-1ubuntu1.1)


iPXE (http://ipxe.org) 00:03.0 CA00 PCI2.10 PnP PMM+1FF8CA10+1FECCA10 CA00



Booting from Hard Disk...

                             GNU GRUB  version 2.04

 ┌────────────────────────────────────────────────────────────────────────────┐
 │*BusyBox Linux                                                              │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 │                                                                            │
 └────────────────────────────────────────────────────────────────────────────┘

      Use the ↑ and ↓ keys to select which entry is highlighted.
      Press enter to boot the selected OS, `e' to edit the commands
      before booting or `c' for a command-line.
   The highlighted entry will be executed automatically in 0s.
Booted into BusyBox, use `poweroff -f` to shutdown
hello world
/ # poweroff -f
[26292.067637] reboot: Power down
```

## Testing

Build and boot has been manually tested on:
- Ubuntu 20.04.6 LTS (x86_64, server edition)
- Ubuntu 22.04.4 LTS (x86_64, server edition)

Boot has additionally been manually tested on:
- macOS 14.6 (arm64) with qemu-system-x86_64 emulation