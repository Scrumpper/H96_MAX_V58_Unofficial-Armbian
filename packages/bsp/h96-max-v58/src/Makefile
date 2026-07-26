# Build the H96 Max V58 front-panel VFD daemon.
#   make            -> native build (build ON the board, or with an aarch64 cross-gcc)
#   make CROSS=aarch64-linux-gnu-   -> cross build
CROSS ?=
CC     := $(CROSS)gcc
CFLAGS := -O2 -Wall -static
all: h96-vfd
h96-vfd: h96-vfd.c
	$(CC) $(CFLAGS) -o $@ $<
clean:
	rm -f h96-vfd
