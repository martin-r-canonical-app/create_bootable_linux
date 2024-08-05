#!/usr/bin/env bash
set -e
set -o pipefail

sudo apt-get -y update
sudo apt-get -y install \
    coreutils \
    e2fsprogs \
    grub2-common \
    grub-pc-bin \
    mount \
    parted \
    qemu-system-x86 \
    qemu-utils \
    util-linux \
    wget