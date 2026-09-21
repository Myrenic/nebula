# cluster-secrets

The `cluster-secrets` Secret is this cluster's single secret bundle. It is the only
file in this repository that holds encrypted values, and everything that needs a
credential gets it from here rather than from a file of its own:

- **At build time.** Flux substitutes `${VAR}` placeholders in manifests while it
  renders them (`spec.postBuild.substituteFrom` on the Kustomizations). Git holds
  the placeholder, the rendered object holds the value. Nothing else in git ever
  contains that value.
- **At runtime.** A few workloads take the whole Secret (`envFrom`, or a chart's
  `existingSecret`). Those reference the Secret object directly instead of being
  templated.

Adding or rotating a value - note that the file argument comes first and the value
is a JSON string:

```bash
sops set kubernetes/apps/common/cluster-secrets.sops.yaml '["stringData"]["NEW_KEY"]' '"value"'
sops unset kubernetes/apps/common/cluster-secrets.sops.yaml '["stringData"]["OLD_KEY"]'
sops -d kubernetes/apps/common/cluster-secrets.sops.yaml   # read it back
```

CI enforces the two rules that keep this honest: a file named `*.sops.yaml` must
contain a `sops:` block and `ENC[` values, and no manifest may carry a
plaintext-looking value in a `data:`/`stringData:` block. Both exist because a
plaintext TURN secret was once committed to a public repository.

Two things to know before touching this file:

1. **Rendered values lose their quotes.** Flux substitutes into the manifest text
   before it parses it, and a placeholder that is a whole scalar ends up unquoted -
   so a numeric-looking value is applied as an integer and the API server rejects
   the object (`stringData.TURN_PORT: expected string, got 3478`). Settings that look
   numeric stay literal in the manifest; generated secrets are hex.
2. **This Secret is cluster-wide.** Kustomizations in the two app repositories
   (`mytops`, `mushroom-finder`) substitute from it as well, and anything run by hand
   can read it. A key that no manifest references is therefore not automatically
   unused, and removing one is a deliberate decision, not a tidy-up.

## Removing a key

Check all three evidence sources before deleting anything here: the `${VAR}`
placeholders in this repository, the `mytops` and `mushroom-finder` repositories, and
their out-of-band steps (a credential that is created by hand, like
`OAUTH2_PROXY_COOKIE_SECRET`, never appears as a placeholder). Then confirm nothing
in the cluster consumes the Secret directly - no `envFrom`, no `secretKeyRef`, no
HelmRelease `valuesFrom`:

```bash
kubectl get pods,deployments,statefulsets,daemonsets,cronjobs -A -o json | grep -c cluster-secrets
kubectl get helmreleases -A -o json | grep -c cluster-secrets
```

29 keys were removed this way after their applications left the cluster (aiometadata,
authentik, azure, code-server, comet, esphome, mediafusion, openposterdb, pihole,
subtitles), which is why the bundle holds 20 keys instead of 49. Anything still
installed elsewhere that read one of those keys would have failed loudly on its next
render; nothing did.
