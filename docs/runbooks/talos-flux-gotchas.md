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

## Still broken: no backup safety net

Pre-existing and untouched: Velero's `backupstoragelocation/default` is
`Unavailable` (19+ days) and `velero-ui` crashloops. There is therefore **no
backup safety net**.
