# Release governance

This repository is the only deployment entrypoint. A release batch must describe the exact source repositories and revisions that are allowed to enter the remote build context.

## Release Manifest

Use `release-manifest.example.json` as the schema source and keep the working manifest outside committed example files.

Required fields:

- `version`: currently `1`.
- `contract_migration`: set to `true` only when the release intentionally changes public cross-repository contracts.
- `allow_dirty`: defaults to `false`; production-like releases should keep this false.
- `repos`: repository names and immutable revisions for every source repository in the release batch.

`scripts/deploy-remote.sh` validates the manifest when `RELEASE_MANIFEST` is set. Without a manifest it still rejects dirty selected source repositories before syncing to the remote host.

## Chart Source Manifest

`chart-source-manifest.json` declares service-owned SQL migrations and n8n workflow directories staged into `iac/helm/byte-v-forge/files`.

Rules:

- The owner repository remains the source of truth for migration SQL and workflow JSON.
- Deploy only stages those files into the Helm chart before remote sync.
- Missing required migration sources fail preflight and config validation.
- Optional workflow directories are skipped when absent.

## Contract Migration Batch

For public proto changes in `common-lib`, run:

```sh
python3 common-lib/scripts/check-proto-breaking.py --base origin/main
python3 common-lib/scripts/list-contract-consumers.py --source-root .
```

Breaking public contract changes must be released as an explicit contract migration batch with impacted consumers updated in the same batch.
