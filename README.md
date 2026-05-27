# opentitan-harness

Minimal private-server harness for producing Xcelium/OpenTitan comparison emissions.

This folder is intentionally standalone. It does not contain OpenTitan source,
generated DVSim wrappers, simulator outputs, or license-bound artifacts. The
scripts clone/build locally on the private machine, run a small Xcelium-focused
DVSim subset, and export derived evidence under `usable-emissions/`.

Run order:

```bash
git clone https://github.com/AmurG/opentitan-harness.git
cd opentitan-harness
cp config.env.example config.env
./00_check_prereqs.sh
./01_setup_opentitan.sh
./02_run_xrun_eval.sh
./03_pack_usable_emissions.sh
```

Flaky SSH / fire-and-forget path:

```bash
git clone https://github.com/AmurG/opentitan-harness.git
cd opentitan-harness
cp config.env.example config.env
./run_detached_overnight_all.sh
```

That starts prerequisite checking, OpenTitan setup, the full overnight Xcelium
run, and packing under `nohup`/`setsid`, then returns immediately with the PID
and log path. You can close the connection after it prints those paths.

The prerequisite scan requires `pkg-config --exists libudev`. OpenTitan's Rust
software build needs the system `libudev.pc` file; on common Linux
distributions this comes from a package such as `systemd-devel` or
`libudev-dev`, or from a site module that sets `PKG_CONFIG_PATH`.
On a no-sudo Rocky/RHEL 8 host, try:

```bash
./06_bootstrap_rocky8_libudev_user.sh
./00_check_prereqs.sh
```

The bootstrap script downloads/extracts the `systemd-devel` RPM into `work/`,
copies the host runtime `libudev.so.1`, writes a user-local `libudev.pc`, and
updates `config.env` with the needed environment.

If you already ran setup and only want to launch the long job:

```bash
RUN_SETUP=0 ./run_detached_overnight_all.sh
```

Status after reconnect:

```bash
./07_status_latest_run.sh
```

If a full run is taking too long, stop the active process group manually, then
collect and pack whatever logs and VCDs already exist:

```bash
run=$(readlink -f detached-runs/latest)
pid=$(cat "$run/pid")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
kill -TERM "-$pgid"
sleep 10
ps -p "$pid" >/dev/null 2>&1 && kill -KILL "-$pgid"
./08_collect_partial_usable_emissions.sh
./03_pack_usable_emissions.sh
```

Do not export `private-xrun/` itself. It can be hundreds of GB and may contain
license-bound raw simulator output. For a smaller feedback bundle, filter to
specific completed groups and make large VCDs header-only:

```bash
COLLECT_INCLUDE_PRIVATE_PATH_REGEX='0004_chip_csr_hw_reset|0005_chip_csr_rw' \
VCD_SIGNATURE_MAX_BYTES=100000000 \
./08_collect_partial_usable_emissions.sh
./03_pack_usable_emissions.sh
du -sh usable-emissions opentitan-usable-emissions-*.tar.gz
```

For the full overnight dashboard collection, run this instead of the default
smoke eval:

```bash
./04_run_overnight_all.sh
./03_pack_usable_emissions.sh
```

To inspect the generated full-dashboard DVSim command without launching Xcelium:

```bash
DVSIM_DRY_RUN=1 ./04_run_overnight_all.sh
sed -n '1p' private-xrun/runs/all-dashboard/command.sh
```

For only the unresolved Arcilator frontier subset, run:

```bash
./05_run_frontier_missing57.sh
./03_pack_usable_emissions.sh
```

For a bounded feedback run intended to finish in about ten hours and produce a
small exportable bundle:

```bash
RUN_SETUP=0 ./run_detached_10h_signal.sh
```

This uses `targets/xrun-10h-signal.tsv`, a 57-row exact-seed subset with
`BATCH_PRESERVE_TARGET_ORDER=1`, ordered breadth-first: known-good Xcelium/CSR
sanity first, then one representative seed from each current Arcilator frontier
and subsystem smoke family, then repeat seeds and heavyweight sentinels. It uses
`DVSIM_MAX_WAVES=1`, one seed per DVSim invocation, a `35m` per-group timeout,
a `10h` outer timeout, no raw-wave export, and a separate
`usable-emissions-signal-10h/` output directory. Large VCDs are summarized
header-only by default above `100MB`.

Status and archive paths are printed in `detached-runs/latest/signal.log`:

```bash
tail -n 100 detached-runs/latest/signal.log
cat detached-runs/latest/archive_path
du -sh usable-emissions-signal-10h opentitan-usable-emissions-*.tar.gz
```

Default behavior:

- clones `lowRISC/opentitan`
- checks out the public dashboard report ref recorded in the local
  `sv-tests` selector metadata
- runs selected chip-level tests through native OpenTitan DVSim with
  `--tool xcelium`
- requests VCD waves by default because the local comparison worker can parse
  them without Xcelium
- keeps raw simulator output under `private-xrun/`
- writes only derived summaries, filtered log excerpts, and VCD signatures to
  `usable-emissions/`

Do not tar `work/` or `private-xrun/` for transfer. Tar only
`usable-emissions/` or the archive created by `03_pack_usable_emissions.sh`.

If your license permits moving raw waveforms, set `EXPORT_RAW_WAVES=1` in
`config.env`; the default is intentionally derived-only.

The default `targets/xrun-smoke.tsv` is five cases. The full overnight file
`targets/xrun-overnight-all-dashboard.tsv` is all `2956` concrete
dashboard-selected full-harness wrappers, with exact seeds copied from the
local generated manifest. The overnight launcher groups those rows by test
name and passes each group to DVSim with that test's exact seed list, avoiding
DVSim's duplicate `-i` item collapse while keeping each group's raw logs and
waves in a separate scratch tree.

For flaky hosts or very large tests, split large seed groups into smaller
chunks without changing the selected rows:

```bash
BATCH_GROUP_MAX_SEEDS=5 RUN_SETUP=0 ./run_detached_overnight_all.sh
```

`targets/xrun-frontier-missing57.tsv` is only the `57` concrete full-harness
wrappers still missing from the local Arcilator retained-VCD coverage snapshot
as of 2026-05-24. It is not a parity-comparison substitute for the full
dashboard list.
