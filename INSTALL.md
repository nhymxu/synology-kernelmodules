# Installing the compiled modules on your Synology NAS

This guide covers putting `iptable_raw.ko`, `ip6table_raw.ko` (and optionally `overlay.ko`) onto a
real NAS: finding the right build for your device, copying it over, loading it, keeping it loaded
across reboots, and undoing it if something goes wrong.

The modules themselves are produced either by the Docker build in the [README](README.md), by
[GitHub Actions](README.md#using-github-actions), or downloaded from a release zip. All three end up
with the same `.ko` files; only the path you get them from differs.

---

## 1. Find your platform and kernel version

The module has to be built for the exact kernel your NAS runs, so start by asking the NAS. SSH in
(Control Panel → Terminal & SNMP → Enable SSH service) and run:

```bash
uname -r
grep -o 'unique="[^"]*"' /etc.defaults/synoinfo.conf
cat /proc/sys/kernel/syno_hw_version
```

(If the `grep` comes back empty, prefix it with `sudo`.)

Example output on a DS920+:

```
4.4.302+
unique="synology_apollolake_920+"
synology_apollolake_920+
```

- `uname -r` is the kernel version **including the `+` suffix**. It becomes the middle directory
  name. Only the `4.4.302+` / `5.10.55+` / `3.10.108` part matters — DSM patch levels don't change it.
- The `unique=` line gives the platform: `synology_<platform>_<model>`. Drop the `synology_` prefix
  and the model suffix — `synology_apollolake_920+` → **apollolake**.

Together they select one directory in `compiled_modules/`, for example:

```
compiled_modules/dsm7.4/4.4.302+/apollolake/
├── iptable_raw.ko
├── ip6table_raw.ko
└── overlay.ko
```

### If `syno_hw_version` prints only a model name

On some DSM builds — `DS3622xs+`, `DS2422+`, and others — `/proc/sys/kernel/syno_hw_version`
returns the bare model instead of the platform:

```bash
$ cat /proc/sys/kernel/syno_hw_version
DS3622xs+
```

That's still useful, just not a platform name. Read the platform from the `unique=` line instead,
which is reliable on every DSM 7 build:

```bash
$ grep -o 'unique="[^"]*"' /etc.defaults/synoinfo.conf
unique="synology_broadwellnk_3622xs+"
```

→ platform **broadwellnk**, so the folder is `compiled_modules/dsm7.4/4.4.302+/broadwellnk/`.

If the `unique=` line is missing too, map the model with the table below. Note the model number is
not the platform: `DS3622xs+` is **not** built for `broadwell` or `kvmx64`, and `DS920+` is not
`apollolake` despite both being 4.4.302+ machines.

| Model | Platform | Kernel (DSM 7) |
| --- | --- | --- |
| DS918+, DS1019+ | apollolake | `4.4.302+` |
| DS920+, DS1520+, DS220+, DS420+ | geminilake | `4.4.302+` |
| DS1621+, DS1821+, DS2422+, RS1221+ | v1000 | `4.4.302+` |
| DS3622xs+, RS3621xs+, RS4021xs+ | broadwellnk | `4.4.302+` |
| DS3617xs | broadwell | `4.4.302+` |
| DS3018xs, DS1618+ | denverton | `4.4.302+` |
| RS1619xs+, FS6400, FS3400 | purley | `4.4.302+` |
| DS923+, DS1522+, DS723+ | r1000 | `4.4.302+` |
| DS1823xs+ | v1000nk | `5.10.55+` |
| DS1515+, DS1815+, DS415+ | avoton | `3.10.108` (legacy) |
| DS916+, DS416play | braswell | `3.10.108` (legacy) |

The table is a convenience for common units, not an authority. `unique=` on the running NAS always
wins, and `uname -r` decides the kernel directory. If your model isn't listed, search the
[Synology product page](https://www.synology.com/products) for its CPU, or compare against
`compiled_modules/sources.json`, which records the platform names Synology publishes.

**Which DSM folder?** Prefer the one matching your installed DSM major/minor version (`dsm7.2/`,
`dsm7.4/`). Both were built from the same kernel series and either normally loads, but the folder
for your own DSM was built with that release's toolchain and sources, so it's the safer choice.
Check your version under Control Panel → Info Center, or `cat /etc/VERSION`.

**Platform not in `compiled_modules/`?** Confirm what this repo actually builds with
`discover_platforms.py`:

```bash
python3 discover_platforms.py | jq -r 'keys[]'
```

If your platform genuinely has no folder, it hasn't been built yet — build it (see the README) or
open an issue.

---

## 2. Get the files onto the NAS

### From a release zip (no build needed)

Download `<platform>-dsm<dsm>.zip` from the [releases page](https://github.com/telnetdoogie-labs/synology-kernelmodules/releases),
then upload it to a volume with File Station or `scp`:

```bash
scp apollolake-dsm7.4.zip admin@your-nas:/volume1/
```

### From a local build in this repo

```bash
scp "compiled_modules/dsm7.4/4.4.302+/apollolake/"*.ko admin@your-nas:/volume1/modules/
```

### Optional: check the checksums first

`compiled_modules/SHA256SUMS` lists a checksum for every module on `main`, with paths such as
`dsm7.4/4.4.302+/apollolake/iptable_raw.ko`. Verify on the machine that has the repo, before copying:

```bash
cd compiled_modules && sha256sum -c SHA256SUMS
```

These checksums come from the same repo as the modules, so they catch a truncated or corrupted
download, not a compromised repository.

---

## 3. Verify the module matches your kernel

Do this **before** loading anything. A mismatched module fails with `invalid module format` and can
look like a broken build.

```bash
strings iptable_raw.ko | grep vermagic
```

Expected output for a DSM 7 x86_64 box on the 4.4 series:

```
vermagic:       4.4.302+ SMP mod_unload
```

That string must match `uname -r` exactly — **including the trailing `+`**. `4.4.302` without the
`+` is a different kernel and will refuse to load. If you have `kmod` available, `modinfo
iptable_raw.ko` gives the same information plus `depends:` and `license:`.

To sanity-check more thoroughly, check the architecture too:

```bash
file iptable_raw.ko
```

For x86_64 platforms (apollolake, geminilake, broadwellnk, purley, …) this should say
`ELF 64-bit LSB relocatable, x86-64`.

---

## 4. Install and load

Put the files in `/lib/modules` with root ownership so nothing can quietly modify them:

```bash
sudo install -o root -g root -m 644 iptable_raw.ko ip6table_raw.ko /lib/modules/
# only if you need it:
sudo install -o root -g root -m 644 overlay.ko /lib/modules/
```

Load them, IPv6 first (it depends on `ip6_tables`, which is normally already present — as is
`ip_tables`, so ordering only matters if you're being tidy):

```bash
sudo insmod /lib/modules/ip6table_raw.ko
sudo insmod /lib/modules/iptable_raw.ko
sudo insmod /lib/modules/overlay.ko
```

Confirm:

```bash
lsmod | grep -E 'raw|overlay'
```

A healthy result looks like:

```
iptable_raw             1452  0
ip6table_raw            1456  0
ip6_tables             14933  14 ip6table_filter,ip6table_raw
ip_tables              14342  4 iptable_filter,iptable_mangle,iptable_nat,iptable_raw
```

The `0` after the size is the use count — it's expected to be low; `iptable_raw` only gets used once
something actually creates raw-table rules (Docker does this when it starts).

### `insmod: ERROR: could not insert module ...: File exists`

The module is already built into your running kernel. Nothing to do — move on.

### `insmod: ERROR: could not insert module ...: Invalid module format`

The `vermagic` doesn't match (wrong kernel folder), the file is truncated, or it's the wrong
architecture. Re-check step 3. The usual cause is picking the folder by **model** instead of
**platform** — a `DS3622xs+` needs `broadwellnk/`, not a folder named after the model — or using
`4.4.302` where the NAS runs `4.4.302+`. Confirm with `uname -r` and
`grep unique= /etc.defaults/synoinfo.conf`.

### `insmod: ERROR: could not insert module ...: Unknown symbol in module`

A dependency isn't loaded. Check `dmesg | tail -20` for the missing symbol name and confirm
`ip_tables` / `ip6_tables` are present in `lsmod`.

---

## 5. Load them at every boot

`insmod` is one-shot; nothing on DSM knows about these modules, so a reboot drops them.

**Option A — Task Scheduler (recommended).** Control Panel → Task Scheduler → Create → **Triggered
Task** → **Boot-up**, User = **root**, and in *Task Settings → Run command*:

```bash
insmod /lib/modules/ip6table_raw.ko
insmod /lib/modules/iptable_raw.ko
```

Leave out `overlay.ko` unless you need it. Don't use `modprobe`: these files aren't in DSM's module
dependency database, so `insmod` with the full path is the reliable route.

**Option B — boot script.** Drop an executable script in `/usr/local/etc/rc.d/`, for example
`/usr/local/etc/rc.d/load-raw-modules.sh`:

```bash
#!/bin/sh
[ -f /lib/modules/ip6table_raw.ko ] && /sbin/insmod /lib/modules/ip6table_raw.ko
[ -f /lib/modules/iptable_raw.ko ] && /sbin/insmod /lib/modules/iptable_raw.ko
exit 0
```

```bash
sudo chmod 755 /usr/local/etc/rc.d/load-raw-modules.sh
```

The `-f` guard keeps boot from erroring out if a DSM update wiped the files.

If you containerised Docker's networking and need this to happen before the container daemon starts,
verify the ordering after a reboot — `lsmod | grep raw` is the quickest check.

---

## 6. After a DSM update

DSM updates replace the root filesystem, so **`/lib/modules` loses these files** and the boot task
may stop working. After every DSM upgrade:

1. Re-run `uname -r` — confirm the kernel didn't move to a new series (e.g. 4.4 → 5.10).
2. Re-copy the `.ko` files from the matching folder (or build/download fresh ones if `uname -r`
   changed).
3. Re-add the `insmod` calls if the Scheduled Task was removed.

Keep the `.ko` files on a volume (e.g. `/volume1/modules/`) so step 2 is a `cp`, not a rebuild. Some
users keep the load script pointing at the volume copy and `install` from there, which survives
updates on its own.

---

## 7. Unloading and removing

If a module causes trouble, unload it (this fails while something is using it — stop Docker/containers
first if `iptable_raw` is held):

```bash
sudo rmmod iptable_raw
sudo rmmod ip6table_raw
```

Then remove the files and the boot task:

```bash
sudo rm -f /lib/modules/iptable_raw.ko /lib/modules/ip6table_raw.ko /lib/modules/overlay.ko
```

Removing the files alone is enough to disable them from the next reboot onward; `rmmod` just makes it
happen immediately.

---

## Platform notes

- **Linux 3.10 platforms** (avoton, braswell, bromolow, grantley, cedarview): only `iptable_raw.ko`
  and `ip6table_raw.ko` exist. There is no `overlay.ko` — overlayfs arrived in Linux 3.18 and
  Synology's 3.10 kernel ships aufs instead. These builds are experimental and untested on hardware.
- **ARM platforms** are not built by this repo. Everything in `compiled_modules/` is x86_64.
- **Legacy `ip6table_raw.ko` naming**: older DSM builds place it under
  `net/ipv6/netfilter/`, but the file itself is the same; the flat copy into `/lib/modules` works
  either way.
