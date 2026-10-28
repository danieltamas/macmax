# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository (Security, Report a vulnerability).
Please do not open a public issue for a security problem. You will get an answer within 7 days.

## What MacMax is trusted with

MacMax runs as you, with your permissions, and no more: no root helper, no kernel or system
extension, no `sudo`. It reads the activity of every process you can see, the network counters
macOS keeps per process, your VPN services' state, and, if you grant Full Disk Access, the sizes of
protected folders. It can quit your apps, end your processes, stop Docker containers and move
caches to the Trash, each only on your press.

## Threat model and trust boundaries

1. **Other processes' text is untrusted.** Process names, command lines, window titles and paths
   are written by other programs, possibly hostile ones. MacMax redacts secrets from command lines
   (tokens, keys, passwords, URLs with credentials, long random strings) before anything is
   stored, shown or returned to an agent; strips terminal escapes and invisible Unicode before
   display; and never interprets that text.
2. **Acting on a process** requires a press, applies only to your own user's processes, never to
   system processes, and re-checks right before the signal that the process is the one you saw
   (same pid and same start time), so a reused pid is never signalled.
3. **Cleanup** moves to the Trash only, never deletes; only inside a fixed list of cache folders;
   never inside protected folders (documents, mail, keychains, application support, containers,
   anything with `.git`, your own list), including through symlinks; and re-checks each item right
   before moving it.
4. **Network**: two destinations only, the IP check (default `https://1.1.1.1/cdn-cgi/trace`,
   editable, can be turned off) and `api.github.com` for the update check and, when Settings, More
   apps is open, the latest release of each app it lists (unauthenticated, read-only, no data
   about you beyond the request). All have timeouts. A
   failed check shows as unknown, never as OK. No telemetry or analytics.
5. **Updates** are downloaded from this repository's GitHub releases and verified against the
   release's `SHA256SUMS` before anything is replaced. Releases are ad hoc signed, so the checksum is
   the only check on the new app (see Residual risks). Update runs only for the installed copy in
   `/Applications` or `~/Applications`, and replaces that copy.
6. **The agent server** (`macmax mcp`) speaks only over the stdin and stdout of the program that
   started it; MacMax opens no listening socket. It answers nothing until you turn on Settings, Agent
   access (off by default; a failed read of that setting counts as off). Every tool is read-only: an agent can read what
   MacMax sees, and can never quit, kill, delete or change settings. Its answers label process
   text as untrusted data.
7. **Local data** lives in `~/.macmax`, mode 0700: history, audits, the action log, the config. It
   includes your public and ISP IP addresses and the names of apps you ran. It never leaves the Mac.
   Files are created without following symlinks.

## Residual risks

- Anyone who can run code as you can read `~/.macmax` and run `macmax`; MacMax does not defend
  against your own user account.
- Redaction is pattern-based. A secret in an unusual format may pass; MacMax never stores full
  command lines in its history for that reason, only redacted short forms when shown.
- With ad hoc signed releases, the update's integrity rests on GitHub and this repository's
  release process (checksums come from the same release). macOS also treats each new version as a
  new app, so privacy grants such as Full Disk Access are given again after an update.
- The IP check reveals your IP address to the endpoint you configure (Cloudflare by default), as
  any website you visit would see it.
