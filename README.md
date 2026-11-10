# Compiling Optional Kernel Modules for Synology

## (Primarily motivated by docker v28 requiring iptables_raw modules) - but could be extended and used for other things.

---

## Installing on your NAS

Once the modules exist — from a release zip, or built below — you still have to get them onto the
device. `nas-install-modules.sh` runs **on the NAS** and does the whole job: it detects the platform and
kernel, downloads the matching build, verifies each module against `SHA256SUMS` and its `vermagic`,
installs it into `/lib/modules` and loads it. `--boot` also keeps them loaded across reboots.

```bash
sudo ./nas-install-modules.sh --dry-run   # download and verify only
sudo ./nas-install-modules.sh --install --boot   # install, load, and load at every boot
```

See [INSTALL.md](INSTALL.md) for the script's options, the platform/model table, and the manual
procedure if you'd rather do each step yourself.

---

## Using Docker

I am just using docker now which automates all the above. All you have to pass is the platform name (and optionally the DSM version to build from), like `apollolake` or `geminilake`

- mapping a volume like the below will automatically pull the created modules out of the build onto the host for publishing.

| :warning: I strongly advise you DO NOT run this in a container on your NAS as the host. The toolkit specifically advises against that, and I think given what it does with `/proc` it might not be a great idea. |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |

```
docker build -t compile_modules .
docker run --privileged --rm -v ./compiled_modules:/compiled_modules:rw -e PLATFORM=apollolake -e DSM_VERSION=7.4 compile_modules
```

Modules land in `compiled_modules/dsmdsm<dsm>/<kernel version>/<platform>/`, for example `compiled_modules/dsm7.4/4.4.302+/apollolake/`. `DSM_VERSION` says which DSM release's sources to build from; leave it out (and don't mount a platforms file) to use the newest sources.

### Where the platforms come from

There's no platform list to maintain. Each build reads [Synology's toolchain archive](https://archive.synology.com/download/ToolChain) and uses the toolchain and kernel source from the newest DSM 7 release that includes your platform. New platforms are buildable as soon as Synology publishes their sources, and platforms Synology stops updating keep building from their last release.

- **List the platforms:** run the container without `PLATFORM`, or run `python3 discover_platforms.py | jq -r 'keys[]'`.
- **Pick a DSM version:** add `-e DSM_VERSION=7.2` to build from DSM 7.2 sources instead of the newest. `python3 discover_platforms.py --dsm 7.2 | jq -r '."7.2" | keys[]'` lists what 7.2 can build.
- **Build several DSM versions:** `discover_platforms.py --dsm 7.2 --dsm 7.4` prints `{"7.2": {...}, "7.4": {...}}`. A platform is built for every requested DSM that publishes sources for it, so the same platform can have both a `dsm7.2/` and a `dsm7.4/` directory. Platforms with sources only in another DSM (e.g. `cedarview` in 7.1.1) are left out.
- **Pin exact sources:** mount your own file with `-v ./my_platforms.json:/synology-toolkit/platforms.json:ro`. Use the format `discover_platforms.py` prints (keyed by DSM, or a single DSM's platform map).

The kernel version each platform runs (e.g. `4.4.302+`) comes from a small table in `discover_platforms.py` covering DSM 7's three kernel series. That's the only thing to update, and only if Synology moves to a new kernel series. Discovery fails with an error naming the platform if that happens, so it can't be missed.

### Building every platform for every DSM

`compile_for_all.sh` builds all non-legacy platforms for each DSM in `DSM_VERSIONS` (default `7.2 7.4`):

```
./compile_for_all.sh
DSM_VERSIONS="7.2" ./compile_for_all.sh      # just one DSM
DSM_VERSIONS="7.2 7.3 7.4" ./compile_for_all.sh
```

It discovers the platforms once, mounts that list into every container, and writes each build to `compiled_modules/dsmdsm<dsm>/<kernel version>/<platform>/`.

## Using GitHub Actions

The `Build Kernel Modules` workflow (`.github/workflows/build-modules.yml`) runs the same Docker build on GitHub's runners, one parallel job per platform, so you don't need a Linux box at all.

- **Weekly, with no manual steps:** every Monday it checks Synology's archive for the DSM versions in the workflow's `dsm` input (default `7.2, 7.4`) and rebuilds any platform whose toolchain or kernel source differs from what `compiled_modules/` was built from (recorded in `compiled_modules/sources.json`), including platforms Synology has newly published. It then opens a PR with the new modules, merges it, and publishes a release of every platform. If nothing changed, nothing is built or released.
  - Versions are picked automatically: a release that adds a platform (or a DSM version for an existing platform) bumps the minor version (`v1.1.0` → `v1.2.0`), anything else bumps the patch version (`v1.1.0` → `v1.1.1`).
  - A platform that fails to build is left out and retried the next week. The rest still ship, and the run shows the failure.
- **Run it manually:** Actions → _Build Kernel Modules_ → _Run workflow_. Enter `all` or a list of platforms such as `apollolake, geminilake`, and the DSM versions to build, such as `7.2, 7.4`. Under _What to do with the new builds_, choose _open a pull request_ to review the results first, or _merge and release_ to do what the weekly run does.
- **On code changes:** it builds every platform whenever the build files change on a PR or on `main`, as a test. Nothing is published. To ship modules built by changed build scripts, run it manually with _merge and release_, or push a tag.
- **Tags:** pushing a tag like `v2.0.0` builds every platform from scratch and releases it under that tag. To write the notes yourself, first save a **draft** release for that tag (don't publish it), then push the tag: the build attaches its files to the draft, adds the generated notes below yours, and publishes it. Releases are immutable, so a release that's already published can't take new files.

Releases attach one zip per DSM and platform (`<platform>-dsm<dsm>.zip`, e.g. `apollolake-dsm7.4.zip`), `all-platforms.zip`, `sources.json` listing the exact toolchain and kernel URLs used for every build (keyed by DSM version, then platform), and `SHA256SUMS` for those files. The release notes are written by `.github/scripts/release_notes.py`: a table of every DSM/platform with its kernel version, modules, DSM source release, what changed since the previous release, and a download link; install steps; then GitHub's changelog grouped by PR title prefix (`feat:`, `fix:`, `ci:`, `docs:`) with bots left out.

Each run lists the platforms it found in the run summary, checks that the expected `.ko` files were produced, and checks that their `vermagic` matches the platform's kernel version. Download the results from the run's **Artifacts** section: there is one `modules-<dsm>-<platform>` artifact per build, plus a combined `compiled_modules`.

`compiled_modules/SHA256SUMS` lists a SHA256 checksum for every module on `main`, with paths like `dsm7.4/4.4.302+/apollolake/iptable_raw.ko`. It's rewritten in the same commit whenever modules change, so tools that download modules from `main` can check them before loading:

```bash
cd compiled_modules && sha256sum -c SHA256SUMS
```

The checksums come from this repo, like the modules, so they catch corrupted or partial downloads, not a compromised repo.

Repository settings this needs:

- _Settings → Actions → General → Workflow permissions_: allow GitHub Actions to create and approve pull requests.
- If `main` is protected by a branch rule or ruleset that requires reviews or status checks, the workflow can't merge its own PR. Add GitHub Actions to the ruleset's bypass list, or the weekly run will stop at an open PR.
- GitHub pauses scheduled workflows after 60 days without repository activity. Re-enable it from the Actions tab if that happens.

## Experimental - Legacy builds

Older platforms (avoton, braswell, bromolow, grantley, cedarview) run Linux 3.10, which needs the 'legacy' Dockerfile with an older compiler. These builds haven't been tested on hardware yet.

Only `iptable_raw.ko` and `ip6table_raw.ko` are built for 3.10. overlayfs arrived in Linux 3.18, and Synology's 3.10 kernel source doesn't include it (it ships aufs instead), so there is no `overlay.ko` for these platforms.

```
docker build -t compile_modules_legacy ./Dockerfile_legacy
docker run --privileged --rm -v ./compiled_modules:/compiled_modules:rw -e PLATFORM=avoton -e DSM_VERSION=7.4 compile_modules_legacy
```

#### Once run for your platform, your modules should be available in the appropriate folders for copying to your synology. Given the above setup, they're in (for example):

- `compiled_modules/dsm7.4/4.4.302+/apollolake/iptable_raw.ko`
- `compiled_modules/dsm7.4/4.4.302+/apollolake/ip6table_raw.ko`

#### If you're on a 7.2 NAS, use the modules built from DSM 7.2 sources (`compiled_modules/dsm7.2/4.4.302+/...`). Modules built from 7.4 sources usually load as well (the kernel version is the same), but the 7.2 build is the one made from that DSM's own toolchain and sources.

#### If you're on a linux box or have WSL, you can check the details of the mod by running, for example:

- `sudo modinfo net/ipv4/netfilter/iptable_raw.ko` - The `vermagic` line has to match the kernel version of your NAS precisely (including the `+` suffix):

```
filename:       net/ipv4/netfilter/iptable_raw.ko
license:        GPL
depends:        ip_tables
retpoline:      Y
vermagic:       4.4.302+ SMP mod_unload
```

#### You can now copy these files to your NAS in `/lib/modules`

#### Change the permissions and ownership of the new `.ko` files on the NAS:

```
sudo chown root:root /lib/modules/{iptable_raw.ko,ip6table_raw.ko}
sudo chmod 644 /lib/modules/{iptable_raw.ko,ip6table_raw.ko}
```

#### Load the modules one time:

```
sudo insmod /lib/modules/ip6table_raw.ko
sudo insmod /lib/modules/iptable_raw.ko
```

#### Assuming you received no errors, validate they're loaded:

```
$ sudo lsmod | grep raw
iptable_raw             1452  0
ip6table_raw            1456  0
ip6_tables             14933  14 ip6table_filter,ip6table_raw
ip_tables              14342  4 iptable_filter,iptable_mangle,iptable_nat,iptable_raw
x_tables               17395  24 ip6table_filter,xt_ipvs,xt_iprange,xt_mark,xt_recent,ip_tables,xt_tcpudp,ipt_MASQUERADE,xt_geoip,xt_limit,xt_state,xt_conntrack,xt_LOG,xt_mac,xt_nat,xt_set,xt_multiport,iptable_filter,ip6table_raw,xt_REDIRECT,iptable_mangle,ip6_tables,xt_addrtype,iptable_raw
```

#### If you want to load the libraries on startup, add the `insmod` lines from above to a Scheduled Task, running as `root` on boot, or add to a service that is loading modules on startup.

#### For the complete install guide — finding the right platform and DSM folder, copying with correct ownership, verifying `vermagic`, troubleshooting `insmod` errors, surviving DSM updates, and removing them again — see [INSTALL.md](INSTALL.md).

---

## If you want to modify this...

`entrypoint.sh` is where everything happens. If you include additional files be sure to modify the Dockerfile to copy them into the container on build.
Currently, `entrypoint.sh` reads the `PLATFORM` and `DSM_VERSION` values that are passed in, looks the platform up with `discover_platforms.py`, and uses that to set up the DSM toolchain which downloads the cross-compiler and sets the environment up for build. `DSM_VERSION` also picks the matching section of a platforms file that covers several DSM versions.

`apply_patches.sh` gets called from `entrypoint.sh` before compilation, in case any modifications are needed to config or source.

Once module compilations are complete, compiled modules are copied out to `/compiled_modules/dsmdsm<dsm>/<kernel version>/<platform>/`.

So... if you want to make significant changes to this, `entrypoint.sh` is the place to start.

The way this is set up currently (the way I run it, with `--rm`) the container is stateless so DSM toolchain downloads etc happen anew each time.

Happy tinkering!

## Contributing

PRs are **VERY** welcome here. Many of the recent updates have been contributed by users just like you.

1. Open an [Issue](https://github.com/telnetdoogie-labs/synology-kernelmodules/issues)
2. [Fork the repo](https://github.com/telnetdoogie-labs/synology-kernelmodules/fork)
3. Make and test your change on real hardware
4. Submit a PR back to this repo, and link with a comment to the Issue you created.
5. Provide details on what you did, what you've tested it on, and the results of those tests.
