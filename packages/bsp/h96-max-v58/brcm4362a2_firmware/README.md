# BCM4362A2.hcd

Broadcom Bluetooth firmware/patch blob for the onboard **BCM4362A2** UART Bluetooth
radio (paired with the PCIe **AP6275P/BCM43752** WiFi 6 half). Every prior build of
this board wrongly assumed the chip was a BCM4345C0 and loaded the wrong firmware,
which is why Bluetooth silently failed to come up. `h96-bt-attach.py` loads this file,
attaches the H4 line discipline, and brings `hci0` up at boot.

Vendor-supplied binary blob, redistributed here (as-is) so a from-scratch build has
everything it needs, same as this board's WiFi firmware ships through the distro's own
`linux-firmware` package rather than a custom blob.
