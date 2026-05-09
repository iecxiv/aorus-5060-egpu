obj-m += aorus-egpu-trust.o

KVER  ?= $(shell uname -r)
KSRC  ?= /lib/modules/$(KVER)/build
PWD   := $(shell pwd)

all:
	$(MAKE) -C $(KSRC) M=$(PWD) modules

clean:
	$(MAKE) -C $(KSRC) M=$(PWD) clean

install: all
	install -d /lib/modules/$(KVER)/extra
	install -m 644 aorus-egpu-trust.ko /lib/modules/$(KVER)/extra/
	depmod -a

uninstall:
	rm -f /lib/modules/$(KVER)/extra/aorus-egpu-trust.ko
	depmod -a

.PHONY: all clean install uninstall
