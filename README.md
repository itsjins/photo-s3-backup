# Photo S3 Backup

An incremental backup and disaster-recovery project for a self-hosted Immich library using AWS S3.

## Current status

This repository currently implements **V1 Step 4 — pre-check infrastructure only**. It verifies that the local source, Immich services, AWS identity, and destination bucket are available before a future backup starts.

It does **not** dump PostgreSQL, upload or synchronize the Immich library, delete local files, or delete S3 objects.

## Requirements

- macOS
- Docker CLI with access to the Docker daemon
- AWS CLI configured with a named profile
- `diskutil` and `plutil` (included with macOS)
- The Immich upload volume mounted at its configured mount point

## Setup

Copy the configuration template:

```bash
cp config.env.example config.env
```

Edit `config.env` so every value matches the local Immich and AWS environment. `LOG_DIR` may be absolute or relative; a relative path is resolved from the directory containing `backup.sh`, not from the caller's working directory.

`IMMICH_VOLUME_PATH` is configured separately from `IMMICH_UPLOAD_PATH`. The script uses `diskutil`'s plist output and `plutil` to confirm that this exact path is a real mount point. This prevents a same-named ordinary directory on the system disk from being mistaken for the external backup source.

Make the script executable if needed:

```bash
chmod +x backup.sh
```

## Run

The script can be launched from any working directory:

```bash
./backup.sh
```

On success it exits with status `0` and prints:

```text
All pre-checks passed. Backup can safely proceed.
```

Any failed critical check writes an `ERROR` entry, stops immediately, and exits non-zero. Logs are written to `logs/backup.log` by default and also displayed in the terminal.

## Pre-check order

1. Load and validate `config.env`.
2. Confirm `docker`, `aws`, `diskutil`, and `plutil` are installed.
3. Confirm the configured external volume is actually mounted at that exact mount point.
4. Confirm the Immich upload directory is located on that volume and is readable.
5. Confirm the Docker daemon is available.
6. Confirm the configured PostgreSQL container exists and is running; record its health status when available.
7. Confirm the named AWS CLI profile can call STS.
8. Confirm the profile can access the configured S3 bucket.

The S3 check uses `s3api head-bucket`, so an empty bucket passes and object names are not written to the log.

## Security

- Never commit `config.env`.
- Never store AWS access keys or secret keys in this repository.
- AWS credentials remain managed by the named AWS CLI profile (currently `immich-backup`).
- The script does not print AWS credentials or account identifiers.
- The current implementation performs no S3 upload, synchronization, or deletion.
