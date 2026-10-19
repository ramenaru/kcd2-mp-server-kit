# Convenience wrapper around the scripts. `make money N=250000` to set the purse.
.PHONY: help install start stop restart status log money test

help:
	@echo "make install          install the server into \$$KCDMP_HOME (default ~/kcdmp)"
	@echo "make start            start the server"
	@echo "make stop             stop the server"
	@echo "make restart          stop, then start"
	@echo "make status           server status"
	@echo "make log              tail the server log"
	@echo "make money N=250000   set the purse (Groschen)"
	@echo "make test             syntax-check the scripts"

install:
	./install.sh

start:
	./kcdmp-server.sh start

stop:
	./kcdmp-server.sh stop

restart:
	./kcdmp-server.sh restart

status:
	./kcdmp-server.sh status

log:
	./kcdmp-server.sh log

money:
	./kcdmp-server.sh money $(N)

test:
	bash -n install.sh kcdmp-server.sh kcd2-launch.sh
	python3 -m py_compile tools/kcd2_groschen.py
	@echo "syntax ok"
