# VyOS rolling Fullcone kernel

Builds the current VyOS rolling kernel with the same Fullcone patch set used by
[`homerouter/aports`](https://github.com/homerouter/aports/tree/main/main/linux-lts):

- `0021-nft_fullcone.patch` adds the nftables `fullcone` expression.
- `982-add-bcm-fullconenat-support.patch` and
  `983-bcm-fullconenat-mod-nft-masq.patch` add `masquerade brcmfullcone`.

The workflow checks out `vyos/vyos-build@rolling`, reads its current kernel
version, and uses VyOS's own package builder and configuration. A QEMU boot test
then exercises both Fullcone paths before the `.deb` packages are released.

Run **Build VyOS rolling Fullcone kernel** from the Actions tab. No repository
secrets are required.
