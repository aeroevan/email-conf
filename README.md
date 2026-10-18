# email-conf

A terminal mail setup for a Gmail account, with each daemon in its own
rootless podman container run by systemd (quadlets), and neomutt on the host.
Gmail is reached with OAuth2 (XOAUTH2) throughout, with no app passwords:
[pizauth](https://github.com/ltratt/pizauth) holds the token and the other
containers ask it for one when they connect.

```
                 Google OAuth2
                       │
                 ┌─────┴─────┐  token socket, shared via
                 │  pizauth  │  ~/.local/state/pizauth-run
                 └─────┬─────┘
            ┌──────────┴──────────┐
      ┌─────┴─────┐         ┌─────┴─────┐
      │  mbsync   │  IMAP   │   msmtp   │  SMTP
      │ every 60s │◄─Gmail  │  + queue  │─►Gmail
      └─────┬─────┘         └─────▲─────┘
            │ maildir-data        │ podman exec
            ▼  volume             │ (neomutt/msmtp-send)
      ┌───────────┐         ┌─────┴─────┐
      │  notmuch  │  index  │  neomutt  │  host / toolbox
      │ every 30s │────────►│  ~/Mail   │
      └───────────┘         └───────────┘
```

| Directory   | Runs as   | What it does |
|-------------|-----------|--------------|
| `pizauth/`  | container | OAuth2 token daemon, with a wrapper that dumps its token state to the `pizauth-data` volume so restarts do not need a new browser login |
| `mbsync/`   | container | isync, plus a vendored [cyrus-sasl-xoauth2](https://github.com/moriyoshi/cyrus-sasl-xoauth2) plugin (no distro ships one), syncing INBOX and Sent into the `maildir-data` volume every minute |
| `msmtp/`    | container | Sends through Gmail's SMTP server.  Failed sends wait in the `msmtp-data` volume and are retried every minute |
| `notmuch/`  | container | Indexes the maildir every 30s and tags new mail by its headers (see [Tagging](#tagging)) |
| `neomutt/`  | host      | Config for neomutt and the host's notmuch, plus the sendmail shim and the contacts lookup |
| `githooks/` | git       | A pre-commit hook that keeps personal email addresses out of commits |

Config files are bind-mounted read-only from this tree, so most edits only
need a `make restart`.

## Requirements

- Podman with quadlet support (4.4 or later) and a systemd user session.
  This was built on Fedora; the Makefile also works from inside a toolbox
  (see below).
- A Google Cloud OAuth client of type *web application*.
- On the host: `neomutt`, `notmuch`, `w3m` (inline HTML), and optionally
  `urlscan` (link picker).

## Setup

The quadlets and the neomutt config refer to this tree as `~/src/env/email`,
so clone it there (or see [Adapting it](#adapting-it)).

1. **Create the OAuth client.**  At
   <https://console.cloud.google.com/apis/credentials>, create a client of type
   web application with `http://localhost:18080/` as an authorised redirect
   URI.  Then:

   ```sh
   cp pizauth/pizauth.conf.example pizauth/pizauth.conf
   $EDITOR pizauth/pizauth.conf    # client_id and client_secret
   ```

   `pizauth.conf` is gitignored.  Keep it that way.

2. **Build, install and start everything.**

   ```sh
   make                    # build images, install quadlets, start services
   ```

   From inside a toolbox, reach the host's podman with
   `make PODMAN="podman --remote"`.

3. **Authorise once in a browser.**  pizauth logs the URL to open:

   ```sh
   podman exec pizauth pizauth refresh aeroevan@gmail.com
   podman logs pizauth     # open the printed URL
   ```

   The OAuth callback reaches the container on `127.0.0.1:18080`.

4. **Check it.**

   ```sh
   make check              # pizauth status from each container, message count
   ```

5. **Set up the host side.**

   ```sh
   make neomutt-install    # ~/Mail -> the maildir volume, configs symlinked
   make git-hooks          # only if you will commit to this repo
   ```

## Using it

`make status`, `make restart` and `make stop` manage the services.  To follow
a service, run `podman logs -f mbsync` (or `msmtp`, `notmuch`, `pizauth`).

neomutt opens on INBOX, and the sidebar lists notmuch views alongside it:

| View    | Shows |
|---------|-------|
| Unread  | everything unread |
| People  | the last 30 days, minus lists, notifications and bulk |
| Lists   | discussion lists, last 30 days |
| Notify  | automated notifications, last 30 days |
| Bulk    | newsletters and marketing, last 7 days |
| Today, Week, Flagged, Attach | what they say |

Keys added on top of neomutt's defaults:

| Key       | Where           | Does |
|-----------|-----------------|------|
| Ctrl-R    | index, pager    | sync now (`mbsync -a` in the container) |
| Ctrl-T    | address prompts | complete from everyone you have sent mail to |
| Q         | index           | the same contact list as a menu |
| Esc-U     | index, pager    | pick a link from the message with urlscan |
| Ctrl-B    | index, pager    | open the HTML part in the browser |
| Esc-R     | index, pager    | mark everything in the current view as read |
| X         | index, pager    | open any notmuch query as a mailbox |
| Ctrl-T    | index, pager    | edit the notmuch tags of a message |

HTML mail renders inline with w3m, and the plain-text part is preferred when
there is one.

### Contacts

There is no address book to maintain.  `neomutt/contacts-query` reads the
notmuch index for everyone this account has sent mail to, ranked by how often.
Nicknames go in `~/.config/neomutt/aliases`, which is deliberately outside the
repo: neomutt's `a` (create-alias) writes there.

### Tagging

`notmuch/hooks/post-new` runs after each index pass and applies the rules in
`notmuch/hooks/tag-rules` to the new mail:

- `notifications`: GitHub mail, and anything with `Auto-Submitted`
- `lists`: mail with `List-Post`, which is to say a list you can post to
- `bulk`: an unsubscribe link and no list, i.e. newsletters and marketing

Mail that matches none of them shows up under People.  The rules are ordinary
notmuch queries.  Header prefixes (`List:`, `ListPost:`, `Unsubscribe:`,
`AutoSubmitted:`) are declared in `notmuch/notmuchrc` and
`neomutt/notmuch-config`, which must agree with each other.  The prefixes also
work in searches, e.g. `X` then `List:fedora`.

Rules only see headers on mail indexed after the prefixes were declared.  To
apply the rules to older mail, reindex it first (this took about 15 minutes
for a year of mail, roughly 70,000 messages):

```sh
podman exec notmuch sh -c 'cd /var/mail &&
    notmuch reindex "date:1y.." && /etc/notmuch/hooks/post-new "date:1y.."'
```

## Things to know

- **Only INBOX and Sent are synced.**  Archiving or deleting in neomutt stays
  local.  `d` marks a message deleted here and never reaches Gmail, because
  the mbsync config leaves out `PushGone`.  Mail you archive in Gmail's web
  or phone app is marked deleted in the local INBOX, which hides it from the
  notmuch views.  The comments in
  `neomutt/neomuttrc` and `mbsync/mbsyncrc` explain why, and what to change
  to sync archiving.
- **Read/unread and flags do sync**, both ways (`PushFlags` and `PullFlags`).
- **Index only from the container.**  If the host's notmuch is newer than the
  container's, a `notmuch new` on the host can upgrade the database format
  out from under the container.  Searching and tagging from the host are fine.
- **The `pizauth-data` volume holds a credential.**  Its token dump can mint
  access tokens for the account.
- **Sync state lives outside the containers** in `~/.local/state/isync`.
  Losing it makes mbsync download the whole mailbox again.

## Adapting it

The account and paths are written into the files rather than templated:

- `aeroevan@gmail.com` appears in `pizauth/`, `mbsync/mbsyncrc`,
  `msmtp/msmtp.conf`, `notmuch/notmuchrc`, `neomutt/` and
  `githooks/email-allowlist`.  `git grep aeroevan` finds them all.
- `~/src/env/email` (`%h/src/env/email` in the quadlets) appears in every
  `*.container` file and in `neomutt/`.
- `/home/evan/Mail` appears in `neomutt/neomuttrc` and
  `neomutt/notmuch-config`.
- Ctrl-R's sync macro uses `podman --remote`, which is right inside a toolbox.
  Use plain `podman` if neomutt runs directly on the host.

## Keeping personal data out

The repo is public, and personal data has slipped in by accident before, so
`githooks/pre-commit` refuses commits that add any email address not listed
in `githooks/email-allowlist`.  It reports the path and line of each one.
Run `make git-hooks` once per clone to enable it.
