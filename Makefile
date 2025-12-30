PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: install uninstall lint test

install:
	install -m 0755 updates "$(BINDIR)/updates"

uninstall:
	rm -f "$(BINDIR)/updates"

lint:
	./scripts/lint.sh

test:
	./scripts/test.sh

