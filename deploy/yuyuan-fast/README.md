# Yuyuan Fast Overlay

This overlay keeps account-level OpenAI `service_tier=priority` control outside
the Sub2API application binary. It is intended to survive upstream Sub2API
updates with minimal merge risk.

## Files

- `server.mjs`: local HTTP injector on `127.0.0.1:18082`.
- `sub2api-fastctl`: account-level fast toggle CLI.
- `sub2api-fast-injector.service`: systemd service for the injector.
- `sub2api-fast-policy-refresh.service`: refreshes active API-key hashes.
- `sub2api-fast-policy-refresh.timer`: refreshes policy every minute.
- `install.sh`: installs or updates the overlay on `cloud-yuyuan`.
- `smoke.sh`: verifies fast and normal accounts without printing API keys.

## Install Or Update

Run on the Sub2API host:

```bash
cd /home/ubuntu/apps/sub2api-source
sudo bash deploy/yuyuan-fast/install.sh
```

The installer preserves the existing fast policy state in
`/home/ubuntu/apps/sub2api-fast-policy/state.json`.

## Daily Operations

```bash
sub2api-fastctl list
sub2api-fastctl on user@example.com
sub2api-fastctl off user@example.com
sub2api-fastctl inherit user@example.com
sub2api-fastctl default off
```

`off` means normal tier only. The API key remains usable, but the injector
removes any client-supplied `service_tier=priority`.

## Smoke Test

```bash
SUB2API_FAST_SMOKE_FAST_EMAIL='fast-user@example.com' \
SUB2API_FAST_SMOKE_NORMAL_EMAIL='normal-user@example.com' \
bash deploy/yuyuan-fast/smoke.sh
```

Expected result:

- fast user latest `usage_logs.service_tier` is `priority`
- normal user latest `usage_logs.service_tier` is `<null>`

## Upgrade Pattern

Keep the fork close to upstream:

```bash
git fetch upstream
git merge upstream/main
git push origin main
```

Build and deploy the fork image, then reinstall this overlay:

```bash
docker compose pull sub2api
docker compose up -d sub2api
sudo bash deploy/yuyuan-fast/install.sh
```

## Optional Upstream Sync Workflow

`workflows/sync-upstream.yml` is a GitHub Actions template for regularly
merging `Wei-Shaw/sub2api:main` into this fork. To activate it, copy it to
`.github/workflows/sync-upstream.yml` and push with a GitHub token that has the
`workflow` scope:

```bash
cp deploy/yuyuan-fast/workflows/sync-upstream.yml .github/workflows/sync-upstream.yml
git add .github/workflows/sync-upstream.yml
git commit -m "Add upstream sync workflow"
git push origin main
```
