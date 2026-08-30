# Photo S3 Backup

A simple macOS backup script for Immich.

## What it does

- Checks that the external HDD is mounted.
- Dumps the PostgreSQL database to one fixed gzip file.
- Syncs the Immich files to S3.
- Sends a success or failure notification with ntfy.
- Writes to `logs/backup.log`.

The S3 sync skips `thumbs/` and `encoded-video/`. It does not use `--delete`.

## Setup

You need Docker Desktop, AWS CLI, the external HDD, and a local `config.env` file. Install the ntfy app and subscribe to the topic in `NTFY_TOPIC_URL`.

## Run

This runs a real database backup and a real S3 sync:

```bash
./backup.sh
```

## Schedule

The LaunchAgent runs every Saturday at 04:00:

```bash
cp launchd/com.songjin.photo-s3-backup.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.songjin.photo-s3-backup.plist
```
