# Rebuilds the HID-BPF program and re-embeds it into install.sh.
# Needs clang, bpftool and the libbpf headers (libbpf-devel / libbpf-dev).

NAME := 0010-Samsung__GalaxyBook4-ALS-scale
OBJ  := $(NAME).bpf.o

all: $(OBJ)

src/vmlinux.h:
	bpftool btf dump file /sys/kernel/btf/vmlinux format c > $@

# -fdebug-prefix-map keeps the build directory out of the object's BTF
$(OBJ): src/$(NAME).bpf.c src/hid_bpf.h src/hid_bpf_helpers.h src/vmlinux.h
	cd src && clang -std=gnu11 -fno-stack-protector -O2 -target bpf -g -w \
		-fdebug-prefix-map=$(CURDIR)/src=. -c -I. $(NAME).bpf.c -o ../$@.tmp
	bpftool gen object $@ $@.tmp
	rm -f $@.tmp

# Replace the base64 payload at the end of install.sh and its checksum
embed: $(OBJ)
	sed -i '/^__BPF_OBJECT_BASE64__$$/q' install.sh
	base64 -w 76 $(OBJ) >> install.sh
	sed -i "s/^OBJ_SHA256=.*/OBJ_SHA256=$$(sha256sum $(OBJ) | cut -d' ' -f1)/" install.sh

clean:
	rm -f $(OBJ) $(OBJ).tmp src/vmlinux.h

.PHONY: all embed clean
