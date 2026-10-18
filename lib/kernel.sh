# shellcheck shell=bash
# Kernel installation. gentoo-kernel-bin is a single emerge. gentoo-sources
# gets a base config plus the options the install needs, then the user's own
# `make menuconfig`, a check that boot-critical options survived, and a build.

kernel_install() {
  if [[ $G_KERNEL == bin ]]; then
    cstep kernel-package "Installing the prebuilt kernel"
    return 0
  fi
  cstep kernel-prepare "Fetching gentoo-sources and building the starting config"
  cstep kernel-config  "Adding the options this install needs"
  kernel_menuconfig
  cstep kernel-build   "Compiling the kernel"
}

kernel_menuconfig() {
  # Unattended installs build the prepared config as it is.
  if [[ $DRYRUN == 1 || $DIALOG == plain ]]; then return 0; fi
  local f=$KDIR/verify.txt choice text
  ui_msg "Kernel configuration" "The starting config is ready, with everything this install needs to boot already switched on.\n\nmake menuconfig opens next. Change whatever you like, then choose Save and Exit. Afterwards toboggan checks that the options needed to boot are still set."
  while :; do
    clear
    chroot "$TARGET" /bin/bash -c 'cd /usr/src/linux && make menuconfig' || true
    step "Checking the kernel config" chroot_exec kernel-verify
    if [[ -s $f ]]; then
      text="These options are needed to boot with your choices but are no longer set (in menuconfig, press / and type the name to find one):\n\n$(cat "$f")"
    else
      text="All the options needed to boot are still set."
    fi
    choice=$(ui_menu "Kernel config" "$text" \
      build  "Build the kernel with this config" \
      edit   "Back to make menuconfig" \
      reset  "Restore the required options, then back to menuconfig" \
      shell  "Shell inside the new system")
    case $choice in
      build) return 0 ;;
      edit)  ;;
      reset) step "Restoring required options" chroot_exec kernel-restore ;;
      shell) chroot_shell ;;
    esac
  done
}
