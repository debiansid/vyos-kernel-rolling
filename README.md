# VyOS rolling Fullcone kernel

Builds the current VyOS rolling kernel with the same Fullcone patch set used by
[`homerouter/aports`](https://github.com/homerouter/aports/tree/main/main/linux-lts):

- `0021-nft_fullcone.patch` adds the nftables `fullcone` expression.
- `982-add-bcm-fullconenat-support.patch` and
  `983-bcm-fullconenat-mod-nft-masq.patch` add `masquerade brcmfullcone`.

The repository keeps the original shell build flow, updated from current VyOS:

- `build-kernel.sh` builds the rolling kernel with the Fullcone patches.
- `build-intel-qat.sh` builds and signs the matching Intel QAT driver modules.
- `build-linux-firmware.sh` packages firmware selected from the built drivers.

A QEMU boot test exercises both Fullcone paths before all generated `.deb`
packages are released.

Run **Build VyOS rolling Fullcone kernel** from the Actions tab. No repository
secrets are required.
