# Makefile for the pizauth + msmtp + mbsync + notmuch mail setup
# (rootless podman quadlets).
#
# Usage:
#   make                 # build images, install quadlets, start services
#   make build           # build the container images
#   make install         # create runtime dir, install quadlets, daemon-reload
#   make start|stop|restart
#   make status          # systemctl status of all services
#   make check           # verify pizauth daemon + mail index from the containers
#   make uninstall       # stop services and remove the quadlets
#   make neomutt-install # symlink ~/Mail + the neomutt/notmuch configs
#   make git-hooks       # enable githooks/ (pre-commit personal-data check)
#
# From inside a toolbox container, add:  PODMAN="podman --remote"
#
# Config files (pizauth/pizauth.conf, msmtp/msmtp.conf, mbsync/mbsyncrc) are
# mounted read-only from this tree; edit them here, then:  make restart

UID            ?= $(shell id -u)
PODMAN         ?= podman
PIZAUTH_IMAGE  ?= local/email-pizauth:latest
MSMTP_IMAGE    ?= local/email-msmtp:latest
MBSYNC_IMAGE   ?= local/email-mbsync:latest
NOTMUCH_IMAGE  ?= local/email-notmuch:latest
QUADLET_DIR    ?= $(HOME)/.config/containers/systemd
RUN_DIR        ?= $(HOME)/.local/state/pizauth-run

# Point explicitly at this user's manager; also works from toolbox where the
# default --user bus would reach the sandbox's own user manager instead.
SYSTEMD_USER_ENV = XDG_RUNTIME_DIR=/run/user/$(UID) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(UID)/bus
SYSTEMCTL        ?= $(SYSTEMD_USER_ENV) systemctl --user

SERVICES = pizauth msmtp mbsync notmuch

# neomutt runs on the host, not in a container, and reads the maildir volume
# through this symlink.  `podman volume inspect` is the only supported way to
# learn where a named volume actually lives.
MAILDIR        ?= $(HOME)/Mail
MAILDIR_SRC     = $(shell $(PODMAN) volume inspect maildir-data --format '{{.Mountpoint}}')
# neomuttrc reaches its helper scripts through the links neomutt-install puts
# in ~/.config/neomutt, so changing NEOMUTT_DIR means changing neomuttrc too.
NEOMUTT_DIR    ?= $(HOME)/.config/neomutt
NEOMUTT_FILES   = neomuttrc msmtp-send mbsync-now contacts-query mailcap \
                  dracula.muttrc dracula-palette
NOTMUCH_DIR    ?= $(HOME)/.config/notmuch/default

.PHONY: all build install start stop restart status check uninstall \
        neomutt-install neomutt-uninstall git-hooks

all: build install start

# pizauth first: the msmtp and mbsync images are built on top of it.
build:
	$(PODMAN) build -t $(PIZAUTH_IMAGE) -f pizauth/Containerfile pizauth/
	$(PODMAN) build -t $(MSMTP_IMAGE) -f msmtp/Containerfile msmtp/
	$(PODMAN) build -t $(MBSYNC_IMAGE) -f mbsync/Containerfile mbsync/
	$(PODMAN) build -t $(NOTMUCH_IMAGE) -f notmuch/Containerfile notmuch/

# The quadlets name host paths as @REPO@ (this checkout, wherever it was
# cloned) and @RUN_DIR@; they are filled in here on the way to QUADLET_DIR.
install:
	mkdir -p "$(RUN_DIR)" "$(QUADLET_DIR)"
	for s in $(SERVICES); do \
	    sed -e 's|@REPO@|$(CURDIR)|g' -e 's|@RUN_DIR@|$(RUN_DIR)|g' \
	        $$s/$$s.container > "$(QUADLET_DIR)/$$s.container" || exit 1; \
	done
	$(SYSTEMCTL) daemon-reload

start:
	$(SYSTEMCTL) start $(SERVICES)

stop:
	$(SYSTEMCTL) stop notmuch mbsync msmtp pizauth

restart:
	$(SYSTEMCTL) restart $(SERVICES)

status:
	$(SYSTEMCTL) status $(SERVICES)

check:
	$(PODMAN) exec pizauth pizauth status
	$(PODMAN) exec msmtp pizauth status
	$(PODMAN) exec mbsync pizauth status
	$(PODMAN) exec notmuch sh -c 'cd /var/mail && notmuch count'

# Symlinks rather than copies, so editing the files in this tree takes effect
# without reinstalling -- the same arrangement as the read-only bind mounts
# the containers get.
neomutt-install:
	@test -n "$(MAILDIR_SRC)" || { echo "maildir-data volume not found; run 'make start' first" >&2; exit 1; }
	ln -sfn "$(MAILDIR_SRC)" "$(MAILDIR)"
	mkdir -p "$(NEOMUTT_DIR)" "$(NOTMUCH_DIR)" "$(HOME)/.cache/neomutt"
	for f in $(NEOMUTT_FILES); do \
	    ln -sfn "$(CURDIR)/neomutt/$$f" "$(NEOMUTT_DIR)/$$f" || exit 1; \
	done
	ln -sfn "$(CURDIR)/neomutt/notmuch-config" "$(NOTMUCH_DIR)/config"
	touch "$(NEOMUTT_DIR)/aliases"

# Point git at the tracked hooks in githooks/ instead of .git/hooks, which
# is not part of the repo.  Once per clone.
git-hooks:
	git config core.hooksPath githooks

neomutt-uninstall:
	rm -f $(addprefix "$(NEOMUTT_DIR)/",$(NEOMUTT_FILES)) "$(NOTMUCH_DIR)/config" "$(MAILDIR)"

uninstall:
	-$(SYSTEMCTL) stop $(SERVICES)
	rm -f $(addprefix "$(QUADLET_DIR)/",pizauth msmtp mbsync notmuch).container
	$(SYSTEMCTL) daemon-reload
