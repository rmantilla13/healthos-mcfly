# NOOP packages (vendored)

These Swift packages come from [NOOP](https://github.com/ryanbr/noop), an offline WHOOP companion,
at commit `2a1de7609843b095505274ad6fc811757210be80` (2026-10-25). The healthOS iPhone app uses them to
read a WHOOP strap over Bluetooth and score its days on the phone (`ios/HealthOSSync/Strap/`).

- `WhoopProtocol`: the strap's Bluetooth frames, commands and history records.
- `WhoopStore`: the on-phone SQLite store (GRDB) the history lands in.
- `StrandAnalytics`: sleep staging, recovery, strain and the rest of NOOP's scoring.
- `OuraProtocol`: not used by healthOS, but `WhoopStore` depends on it.

Tests were left out. Nothing here is edited; to update, copy the packages from a newer NOOP commit and
change the commit above.

**License.** NOOP is licensed under the PolyForm Noncommercial License 1.0.0 (`LICENSE`), which covers
this copy. healthOS uses it for a family's own, noncommercial health tracking.

Required Notice: Copyright 2026 NoopApp

GRDB.swift and ZIPFoundation keep their MIT licenses (`NOTICE`). NOOP is not affiliated with WHOOP, and
neither is healthOS; see `DISCLAIMER.md`.
