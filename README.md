# MAM-Scripts

This repository contains scripts for automating interactions with MyAnonaMouse. Each script is configurable via environment variables and designed for containerised environments (Docker, Kubernetes, etc.).

> **Container Image:**
> These scripts are currently provided as-is and you're welcome to include them in your own docker container solution. A prebuilt image is available at [ghcr.io/cbrherms/mam-scripts](https://ghcr.io/cbrherms/mam-scripts)

## Scripts

### autodl.sh
**Purpose:**  
Automatically downloads torrents from MyAnonaMouse based on defined search criteria.

**Features:**
- Configurable search and filter options.
- Supports dry-run mode to preview candidate torrents without downloading.
- Downloads torrent files to a designated directory.

**Key Options (Environment Variables):**
- **MAM_ID**: MyAnonaMouse session token. *(Required)*
- **MAX_DOWNLOADS**: Maximum number of torrents to download per run. *(Default: `5`)*
- **SET_ASIDE**: Percentage to reserve as a buffer. Will leave this percentage of your unsatisfied allowance available. *(Default: `10`)*
- **WORKDIR**: Directory for temporary files. *(Default: `/config`)*
- **TORRENT_DIR**: Directory to save torrent files. Defaults to `${WORKDIR}/torrents` (overridable).
- **DRY_RUN**: Set to `1` to simulate downloads without saving files. *(Default: `0`)*
- **DEBUG**: Enable additional debugging info. *(Default: `0`)*

**Search Options:**
- **SORT_CRITERIA**: API sort option. *(Default: `dateDesc`)*
- **MAIN_CATEGORY**: JSON array of main category IDs. *(Default: `'[14,13]'`)*
- **LANGUAGES**: JSON array of language IDs. *(Default: `'[1]'`)*
- **SEARCH_TYPE**: Search type (e.g. `fl-VIP`, `all`). *(Default: `fl-VIP`)*

**Numeric Filters:**
- **MIN_SIZE**/**MAX_SIZE**: Size range limits.
- **UNIT_STR**: Size unit (Bytes, KiB, MiB, GiB). *(Default: `MiB`)*
- **MIN_SEEDERS**/**MAX_SEEDERS**: Seeder count limits.

---

### autospend.sh
**Purpose:**  
Converts bonus points into upload credits on MyAnonaMouse.

**Features:**
- Automatically spends excess bonus points while retaining a buffer.
- Optionally upgrades VIP status.
- Can purchase "wedges" after a configurable interval.

**Key Options (Environment Variables):**
- **MAM_ID**: MyAnonaMouse session token. *(Required)*
- **POINTS_BUFFER**: Minimum bonus points to retain after spending. *(Default: `5000`)*
- **BUY_VIP**: Set to `1` to enable VIP upgrade; `0` to disable. *(Default: `1`)*
- **WEDGEHOURS**: Interval (in hours) for wedge purchase; set to `0` to disable. *(Default: `0`)*
- **WORKDIR**: Directory for temporary files. *(Default: `/config`)*

---

### seedbox-api.sh
**Purpose:**  
Monitors and updates your MyAnonaMouse seedbox session by detecting public IP changes.

**Features:**
- Retrieves the current public IP using a selectable method.
- Checks against a stored IP; updates the seedbox session if a change is detected.
- Designed to be run at regular intervals (via cron or Kubernetes CronJob).

**Key Options (Environment Variables):**
- **MAM_ID**: MyAnonaMouse session token. *(Required)*
- **IPSOURCE**: Method to retrieve the public IP. Options are `ifconfigco` or `mam`. *(Default: `ifconfigco`)*
- **WORKDIR**: Directory for temporary files. *(Default: `/config`)*

---

## Usage

Each script is designed to run on a Linux shell within a Docker container or Kubernetes pod. The official container image is available at:

    ghcr.io/cbrherms/mam-scripts

Images are tagged with the build date, but you can use the "rolling" tag as a drop-in for what is typically referred to as "latest."

To run a script, set the environment variable `SCRIPT_NAME` to the name of the script you want to execute (for example, `autospend.sh`).

For example, to run `autospend.sh` with a custom `POINTS_BUFFER`:

```bash
docker run \
  -e MAM_ID="your_mam_id" \
  -e POINTS_BUFFER=10000 \
  -e SCRIPT_NAME="autospend.sh" \
  -v /path/to/your/data:/config \
  ghcr.io/cbrherms/mam-scripts:rolling
```

In a Kubernetes CronJob, specify environment variables in the pod spec.

## Logging and Monitoring

- All scripts output their logs to stdout.
- Container logs can be accessed via `docker logs` or through your Kubernetes logging solution.

## License

This project is provided as-is under the terms of its applicable open source license.
