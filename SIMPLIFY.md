# Simplify: replacing hand-rolled infrastructure with things other people maintain

The goal is **fewer lines of infrastructure code**, not more features. Nothing
here adds a capability you do not already have. If a step's justification drifts
into "and it also gives us X", that is a sign the step is being sold rather than
argued, and it should be cut.

Written 2026-08-07, after a day that produced four defects — all four in the two
largest hand-rolled components, all four producing plausible-looking values
rather than errors.

## Where the code is now

```
monitor/collect.py            470   ← 47% of the platform, for the least
                                       essential function, and where the bugs live
backup/pull-backups.sh        150
deploy-app.sh                 122
bootstrap.sh                  116
cloudflared/render-config.sh   61
lib/appconf.sh                 36
auto-deploy.sh                 27
systemd/install-units.sh       27
                             ────
                             1009   non-comment, non-blank
```

Target after phases 0–2: **~400**. Phase 3 is unlikely to be worth it; see below.

---

## The blind spot that justifies most of this

The health dashboard **runs on the Pi**. If the Pi is off, unplugged, or its SD
card is dead, there is no dashboard and nothing says so. The current design
cannot report the failure that matters most, and no amount of polishing it will
change that — the observer has to be somewhere else.

Every monitoring change below moves the observer off the box. That is a
correctness argument, not a tidiness one, and it happens to delete the single
largest file in the repo.

---

## Phase 0 · Conventions that delete configuration · ~1h

Infrastructure is bespoke here mostly because the apps are. Fix that first and
later phases get smaller.

**Every app keeps its SQLite database at `/data/app.db`.**

karb reads `SLONK_DB` from its environment already, so this is a path change and
a file rename, not a code change:

```
SLONK_DB=/data/app.db          # was /data/slonk_arb.db
```

**Then delete, because nothing needs them any more:**

- `snapshot.js` (whorl), `snapshot.py` (karb)
- `BACKUP_DB` and `BACKUP_SNAPSHOT_CMD` from every conf
- The deploy-time check in `deploy-app.sh` that the snapshot script is in the
  image — a check that exists only because that script exists

Those per-app snapshot scripts were written on the belief that `VACUUM INTO` had
to run *inside* the app's container to see the same file. **That is not true.**
The data directory is a bind mount, so the host path and the container path are
the same inode. Any process that can open the file can snapshot it. The real
constraint was narrower: the Pi had no `sqlite3` binary, and each image happened
to have a different language runtime.

```
sudo apt-get install -y sqlite3
sqlite3 /home/podsvc/data/<app>/app.db "VACUUM INTO '/tmp/<app>.db'"
```

One generic command for every app, forever, instead of one script per runtime.

**Removes:** ~60 lines and two files in app repos.
**Risk:** low. Verify a restored snapshot's row counts before deleting anything.

---

## Phase 1 · Move monitoring off the box · ~2h · the big one

Two free external services, split by what they can actually observe.

### 1a. Dead-man's-switch pings — healthchecks.io

Each scheduled job pings a URL when it finishes cleanly. If a ping does not
arrive on schedule, healthchecks emails you. **The absence of work becomes
visible without anything on the Pi knowing to look for it.**

One line at the end of each job:

```sh
curl -fsS -m 10 --retry 3 "$HC_URL" >/dev/null
```

Checks to create (5): `karb-daily`, `karb-sports`, `karb-sweep`, `karb-hot`,
`pi-backup`. Free tier covers 20. Self-hostable later if that ever matters.

**Deletes:** the whole job-receipt mechanism (`/var/lib/rpi-health/jobs`, the
`receipt()` function, `JOB_RECEIPTS`, `job_ages()`, `job_state()`), the backup
receipt, `backup_age()`, both threshold pairs, and `notify()`.

### 1b. External HTTP checks — UptimeRobot or Uptime Kuma elsewhere

Probes `whorl.mathslug.com` and `karb.mathslug.com` **from outside**, which is
the check the Pi cannot perform about itself. Free tier is ample for two URLs.

Do **not** self-host Uptime Kuma on the Pi. It would be one more container with
its own database and upgrade path, and it would go down at exactly the moment
you need it — reproducing the blind spot in a nicer UI.

### 1c. What is genuinely local

Disk, temperature, throttling, and memory can only be seen from the box. That
does not need 470 lines or a web page — it needs a guard that fails the ping:

```sh
# rpi-guard.sh, run by a timer, ~25 lines
# Pings healthchecks on success; on breach, pings /fail with the reason, and
# the email arrives from outside the machine that has the problem.
[ "$(df --output=pcent / | tail -1 | tr -dc 0-9)" -lt 90 ] || fail "disk"
[ "$(vcgencmd get_throttled)" = "throttled=0x0" ]          || fail "throttled"
```

**Removes:** ~445 of `collect.py`'s 470 lines, plus the dashboard container, plus
the `mypi.mathslug.com` hostname and its Access application.

**Risk:** low, and reversible at every step — run both old and new in parallel
for a week before deleting anything. **Do not delete `collect.py` until you have
seen healthchecks fire a real alert**, deliberately triggered by stopping a
timer. A monitor you have not watched fail is a rumour, same as a backup.

**What you lose, honestly:** the sparklines, the at-a-glance page, and local
history. If you miss the page, add UptimeRobot's free status page — it renders
the same information from outside.

---

## Phase 2 · restic for backups · ~2h

The two backup defects found on 2026-08-07 were both in logic restic owns:

- **Retention counted runs, not days.** Nine manual runs in an afternoon
  collapsed a fourteen-day window to two days of real history.
  `restic forget --keep-daily 14` cannot express that mistake.
- **The snapshot timestamp came from the wrong machine's clock.** restic records
  snapshot times itself; there is no receipt to get wrong.

Keep the **pull** model. It exists because the Mac sleeps and moves while the Pi
does not, and that reasoning is unchanged — a push from the Pi would fail
silently every time the laptop was shut.

```sh
# 1. Consistent snapshot on the Pi (Phase 0 made this generic)
ssh "$PI" "sqlite3 ~podsvc/data/$app/app.db \"VACUUM INTO '/tmp/$app.db'\""
# 2. Pull to staging
# 3. restic backup <staging>
# 4. restic forget --keep-daily 14 --keep-weekly 8 --prune
# 5. restic check --read-data-subset=5%
```

**Deletes:** gzip/stream handling, `--link-dest` hardlinking, `prune()`,
`collapse_same_day()`, the Python verifier, `latest` symlink management.
`pull-backups.sh` goes from 150 lines to roughly 40.

**The cost, stated plainly:** today a restore is `gunzip` and `scp` — two tools
that will exist on any machine in 2035. After this, a restore requires the
`restic` binary and the repository password. That is a real reduction in
recoverability, and it is the strongest argument against this phase.

Mitigate it, and record the mitigation in `RECOVERY.md`:

- Store the repo password somewhere that is not the Mac and not this repo
- Keep the repository **unencrypted** if it lives only on hardware you control —
  it removes the password from the restore path entirely
- Run `restic restore` once, to a scratch directory, and check row counts.
  Write the date you did it in `RECOVERY.md`

---

## Phase 3 · Dokku · probably not · here for completeness

Dokku is the real product for "small PaaS on hardware I own": `git push` to
deploy, arm64 support, and `dokku cron` for scheduled jobs. It would replace most
of `deploy-app.sh`, the Quadlet units, and `render-config.sh` — roughly 200
lines.

**Why it is likely not worth it, after phases 0–2:**

- It requires **Docker**, so podman and every Quadlet unit come out. That is the
  part of the current system with the fewest defects and the least churn —
  replacing it spends the largest risk budget on the smallest problem.
- `Containerfile` → `Dockerfile` in every app repo.
- Auto-deploy does **not** go away. Dokku is push-based, and the Pi is behind
  NAT with nothing able to reach in. You would keep a pull script that runs
  `git pull && dokku ps:rebuild`, so `auto-deploy.sh` survives in another form.
- The tunnel would point at Dokku's nginx instead of at each app, adding a
  routing layer to remove a generated config file.

Phases 0–2 remove ~600 lines. Phase 3 removes ~200 more for a runtime
migration. **Revisit only if a second machine appears** — at which point the
whole calculus changes and this document is the wrong one to be reading.

---

## What must survive any rewrite

The scripts are the cheapest thing here to replace. This list is not:

- **`VACUUM INTO`, never `cp`.** Both databases run in WAL mode. Production
  whorl's `app.db` was once 4096 bytes with 1.3MB of write-ahead log; copying it
  yields a valid, silently **empty** database with no error.
- **Quadlet truncates an inline command at the first nested quote**, leaving a
  container permanently "unhealthy" while the app is fine. Health checks go in
  a script file. Verify with `podman inspect --format
  '{{.Config.Healthcheck.Test}}'` after any change.
- **A cgroup memory limit covers page cache, not just process memory.** Size it
  to the app's largest file, not its process. karb read a comfortable 25% in
  `podman stats` while hitting its ceiling 852 times; `memory.events` is the
  signal, `MemPerc` is not.
- **`OnCalendar` without a `UTC` suffix** is read in local time and silently
  shifts every job by the offset.
- **Raspberry Pi firmware injects `cgroup_disable=memory`.** `/proc/cmdline` is
  truth; `cmdline.txt` is intention.
- **Declare an app's config at DNS cutover, not before.** karb's arrived three
  hours early and booked 37 samples of 404 against a hostname still pointing at
  the old server.
- **A backup nobody has restored is a rumour.** So is a monitor nobody has
  watched fail.

## Order, and the stopping point

```
Phase 0   conventions      ~1h    ~60 lines    low risk
Phase 1   monitoring off   ~2h   ~445 lines    low risk, biggest win
          the box
Phase 2   restic           ~2h   ~110 lines    medium risk (restore path)
Phase 3   Dokku            ~6h   ~200 lines    high risk, low marginal value
```

Phases 0–2 are about six hours and remove roughly **60% of the infrastructure
code**, with the removed portion being exactly where the defects have been.

**Stop after Phase 1 if you only do one thing.** It deletes the most code, fixes
a real blind spot, and is the easiest to reverse.
