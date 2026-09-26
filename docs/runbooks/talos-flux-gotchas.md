# Runbook: Talos, Flux and kubectl gotchas

Traps that cost time on this cluster. Each one gives the command that works
instead.

## Credentials for `omnictl` and `talosctl`

```bash
export OMNI_ENDPOINT=https://omni.tuntelder.com/ OMNI_SERVICE_ACCOUNT_KEY="$(cat /tmp/omni-key)"
```

With those set you can reboot a node and read from it, but **reading the machine
config fails with PermissionDenied**. That is expected, not a broken credential:
`reboot`, `read` and `dmesg` do work.

## The cluster name in Omni

The cluster is called `default/talos-default` in Omni, not `nebula`. Commands that
take a cluster name need that, not the repo name.

## `kubectl -o jsonpath` with dots in the key

`{.metadata.labels.kubernetes.io/hostname}` returns empty here, in the
`['...']` form as well. Use `-o json` and parse it with python.

This produced a wrong conclusion twice ("the label is missing") while the label
was there all along. Do not trust an empty jsonpath result for a key containing
dots.

## Pod phase versus displayed status

`kubectl get pods -A --no-headers` puts STATUS in column 4, but the API phase is
`Succeeded` while kubectl displays `Completed`. Filter on the phase through JSON,
not on the display string, or you will keep matching a value that never appears in
the API.

## `flux get ks` columns

In `flux get ks -A` column 3 is REVISION, not READY. Do not read it as readiness;
use `--status-selector ready=true` when you want only the ready ones.

## `kubectl` segfaults

`/usr/bin/kubectl` segfaults. Use `/usr/local/bin/kubectl` (v1.36.3) or run
`hash -r` first so the shell picks up the working binary.

## Backups are back, and the way they fail is silent

Velero runs again (`kubernetes/apps/backup`), authenticating to Azure Blob with a
storage account access key against `tuntelderbackupee3949`. The previous
installation was removed because `backupstoragelocation/default` was `Unavailable`
for weeks while every schedule failed: the resource group and storage account it
pointed at had been deleted, and its service principal secret expired the same day
the config was deleted.

Two traps that do not announce themselves:

- **`kubectl get backup` is not Velero's.** Longhorn also has a `backups` CRD, and
  the short name resolves to `backups.longhorn.io`, which answers "not found" in
  the `velero` namespace and looks like a backup that vanished. Always use
  `backups.velero.io`, `restores.velero.io`, `podvolumebackups.velero.io`.
- **A skipped volume is not a failed backup.** If a pod is not running when the
  schedule fires, Velero skips its volume and still reports `Completed`. The list
  lives in `volumeInfo`, which is only in the object store, so it takes
  `velero backup describe <name> --details` to see it. This has already happened
  once (Forgejo mid-rollout), and it is the reason a `Completed` backup is not on
  its own evidence that the data is in it.

The alert rules for this are in
`kubernetes/apps/monitoring/kube-prometheus-stack/rules/prometheusrule-backup-health.yaml`.
Note that `velero_schedule_expected_interval_seconds` does not exist - the previous
staleness rule divided by it and could therefore never fire, which is part of why
the old failure went unnoticed. The current rule writes each schedule's expected
period out instead.
