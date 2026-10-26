# Toboggan

<p align="center">
    <img src=".github/images/toboggan.png" width=200px />
</p>



Ncurses installer for Gentoo Linux. Partitioning, stage3, Portage, kernel, and bootloader setup in ncurses, plus post-install configuration.

## Introduction

After installing Gentoo manually several times over the past decade, I want a quicker way. I would like to stress that the origin of this project is personal laziness and not a desire to cirumvent the learning process that is a Gentoo install. 

For those who may stumble upon this page and see it as a quick way to land on a desktop with that glorious Gentoo `fastfetch` output, please think again as you will only experience trouble when the first user intervention is needed due to an update, or strange behaviour of your hardware that this tool cannot help you with.

## What it does

* Partitioning
* Init system and DE/WM selection
* Initial configuring of Portage
* Kernel selection (bin or sources - it will not do the kernel work for you)
* Initramfs (dracut or ugrd)
* Bootloader install and configuration

## What it does not do

* Full custom kernel configuration
* Help when a new version of Python comes out and you have to deal with potential software that has not been bumped to the latest version
* Undo an accidental `sudo rm -rf /`
* Solve world hunger

## Install & Run

From your installation environment, or minimal install ISO, bring up the network (wired or Wi-Fi). 

Clone from Github and run:

```bash
git clone https://github.com/rdmillen/toboggan
cd toboggan
./toboggan
```

## Known Issues

* Only tested on a wired machine so far, Wi-Fi process and transfer needs to be verified as functioning.

## Issues and PRs 

Please report issues or submit PRs at your leisure. 

## License

Licensed under GPLv3. 

