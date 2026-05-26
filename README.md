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

If you already ran setup and only want to launch the long job:

```bash
RUN_SETUP=0 ./run_detached_overnight_all.sh
```

Status after reconnect:

```bash
tail -n 80 detached-runs/latest/overnight.log
cat detached-runs/latest/status
cat detached-runs/latest/archive_path
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
DVSim's duplicate `-i` item collapse while still sharing one scratch tree.

`targets/xrun-frontier-missing57.tsv` is only the `57` concrete full-harness
wrappers still missing from the local Arcilator retained-VCD coverage snapshot
as of 2026-05-24. It is not a parity-comparison substitute for the full
dashboard list.
