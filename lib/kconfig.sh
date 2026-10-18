# shellcheck shell=bash
# The kernel options a gentoo-sources install needs for the user's choices.
# They're merged on top of the starting config before menuconfig opens, and
# checked again afterwards. Boot-critical drivers are built in (=y)
# so the system boots even without an initramfs.

kconfig_required() {
  local tran
  tran=$(hw_disk_tran "$G_DISK")
  {
    echo "# toboggan required options: applied last, override everything else."
    echo "# Core"
    printf '%s\n' CONFIG_MODULES=y CONFIG_DEVTMPFS=y CONFIG_DEVTMPFS_MOUNT=y CONFIG_TMPFS=y \
      CONFIG_TMPFS_POSIX_ACL=y CONFIG_FW_LOADER=y CONFIG_PARTITION_ADVANCED=y CONFIG_EFI_PARTITION=y \
      CONFIG_MICROCODE=y
    if [[ $G_INITRAMFS != none ]]; then printf '%s\n' CONFIG_BLK_DEV_INITRD=y CONFIG_RD_ZSTD=y; fi

    echo "# Root filesystem: $G_FS"
    case $G_FS in
      ext4)  echo CONFIG_EXT4_FS=y ;;
      xfs)   echo CONFIG_XFS_FS=y ;;
      btrfs) printf '%s\n' CONFIG_BTRFS_FS=y CONFIG_BTRFS_FS_POSIX_ACL=y ;;
    esac
    echo "# Boot partition: $G_BOOT_FS"
    if [[ $G_BOOT_FS == vfat ]]; then
      printf '%s\n' CONFIG_VFAT_FS=y CONFIG_NLS_CODEPAGE_437=y CONFIG_NLS_ISO8859_1=y
    else
      echo CONFIG_EXT4_FS=y
    fi
    if [[ $G_BOOTMODE == uefi ]]; then
      echo "# UEFI"
      printf '%s\n' CONFIG_EFI=y CONFIG_EFI_STUB=y CONFIG_EFIVAR_FS=y CONFIG_SYSFB_SIMPLEFB=y CONFIG_DRM_SIMPLEDRM=y
    fi

    echo "# Storage for $G_DISK (transport: ${tran:-unknown})"
    case $tran in
      nvme) echo CONFIG_BLK_DEV_NVME=y ;;
      sata|ata) printf '%s\n' CONFIG_ATA=y CONFIG_SATA_AHCI=y CONFIG_BLK_DEV_SD=y ;;
      usb) printf '%s\n' CONFIG_USB_SUPPORT=y CONFIG_USB_XHCI_HCD=y CONFIG_USB_STORAGE=y CONFIG_BLK_DEV_SD=y ;;
    esac
    if [[ $tran == virtio ]] || hw_has_virtio; then
      printf '%s\n' CONFIG_VIRTIO_PCI=y CONFIG_VIRTIO_BLK=y CONFIG_SCSI_VIRTIO=y CONFIG_BLK_DEV_SD=y CONFIG_VIRTIO_NET=m
    fi

    if [[ $G_LUKS == yes ]]; then
      echo "# LUKS2 / dm-crypt"
      printf '%s\n' CONFIG_MD=y CONFIG_BLK_DEV_DM=y CONFIG_DM_CRYPT=y CONFIG_CRYPTO_XTS=y CONFIG_CRYPTO_AES=y \
        CONFIG_CRYPTO_AES_NI_INTEL=y CONFIG_CRYPTO_SHA256=y CONFIG_CRYPTO_USER_API_SKCIPHER=y
    fi
    case $G_SWAP in
      file) printf '%s\n' "# Swap" CONFIG_SWAP=y ;;
      zram) printf '%s\n' "# zram swap" CONFIG_SWAP=y CONFIG_ZRAM=m CONFIG_ZRAM_BACKEND_ZSTD=y CONFIG_CRYPTO_ZSTD=y ;;
    esac

    if [[ $G_INIT == systemd ]]; then
      echo "# systemd requirements"
      printf '%s\n' CONFIG_CGROUPS=y CONFIG_INOTIFY_USER=y CONFIG_SIGNALFD=y CONFIG_TIMERFD=y CONFIG_EPOLL=y \
        CONFIG_UNIX=y CONFIG_FHANDLE=y CONFIG_AUTOFS_FS=y CONFIG_TMPFS_XATTR=y CONFIG_SECCOMP=y \
        CONFIG_SECCOMP_FILTER=y CONFIG_DMIID=y CONFIG_BPF_SYSCALL=y CONFIG_CGROUP_BPF=y
    fi

    if [[ -n $G_VIDEO_CARDS ]]; then
      echo "# Graphics: $G_VIDEO_CARDS"
      printf '%s\n' CONFIG_DRM=y CONFIG_DRM_FBDEV_EMULATION=y CONFIG_INPUT_EVDEV=y
      if has_word intel "$G_VIDEO_CARDS"; then echo CONFIG_DRM_I915=m; fi
      if has_word amdgpu "$G_VIDEO_CARDS"; then echo CONFIG_DRM_AMDGPU=m; fi
      if has_word nouveau "$G_VIDEO_CARDS"; then echo CONFIG_DRM_NOUVEAU=m; fi
      if has_word virgl "$G_VIDEO_CARDS"; then echo CONFIG_DRM_VIRTIO_GPU=m; fi
      if has_word qxl "$G_VIDEO_CARDS"; then echo CONFIG_DRM_QXL=m; fi
      if has_word vmware "$G_VIDEO_CARDS"; then echo CONFIG_DRM_VMWGFX=m; fi
      if has_word nvidia "$G_VIDEO_CARDS"; then
        echo "# Proprietary NVIDIA driver: nouveau must be off"
        printf '%s\n' "# CONFIG_DRM_NOUVEAU is not set" CONFIG_SYSVIPC=y
      fi
    fi
  } >"$KDIR/required.config"
  cat "$KDIR/required.config"
}
