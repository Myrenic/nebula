# Frigate

## Where the configuration actually lives

The ConfigMap in this directory (`config.yaml`) is **not** what Frigate runs. The
HelmRelease mounts it at `/seed/config.yml`, and the `seed-config` init container
copies it into `/config` only when that file is missing or empty, which is once,
for the lifetime of the volume:

```yaml
      config-file:
        type: configMap
        name: frigate-config
        globalMounts:
          # seed only - see the seed-config init container above. Restore
          # `path: /config/config.yml` to make the ConfigMap authoritative again.
          - path: /seed/config.yml
```

The effective config is `/config/config.yml` on the `frigate-config` PVC, and
whatever is written there wins - by the config editor in the UI, or by Frigate
itself when it rewrites the file because the schema version does not match. Two
consequences, both worth knowing before debugging anything here:

- Editing `config.yaml` in this repository changes nothing in the cluster: not
  after a reconcile, not after a restart. The pod template carries no checksum
  annotation either, so the ConfigMap is never read again once `/config` exists.
- Restoring `path: /config/config.yml` would make the ConfigMap authoritative, but
  it **replaces** what the volume holds. On 2026-09-30 that would have silently
  dropped MQTT, an object mask and the `voortuin` zone, none of which were in git.
  They were read out of the running pod and committed before this was written.

The two copies are therefore kept in step by hand, in that direction: read
`/config/config.yml` out of the pod, put it in `config.yaml`, commit. Keep the
trailing comment about the schema version and the image tag: Frigate rewrites the
file when `version:` does not match the tag in `helmrelease.yaml`, so a rebuild
would reseed from a file that claims the wrong schema.

## What it detects, and why it alerts on people who are only passing

- Detection runs on the **4K main stream** at 5 fps, decoded with QSV on the iGPU:
  VAAPI crashes on that stream in this VM (`Failed to sync surface` every ~40s),
  which is why `hwaccel_args` is `preset-intel-qsv-h265` and the chain is
  `reolinkproxy` -> go2rtc -> `ffmpeg`. Recordings stay stream-copied.
- The model is YOLO-NAS-S 320x320 on OpenVINO/GPU, `objects.track` is `person`
  only, and face recognition is on - which is why some alerts carry
  `person-verified` for a face that is known.
- **Alerts are not filtered by zone.** `review.alerts.required_zones` is unset, so
  a person anywhere in the 4K frame is an alert: on 2026-09-29 all 33 review items
  were `severity=alert` with an empty `zones` list, including walkers on the public
  path. The object mask over the right of the frame is straddled by that path
  (a person's box was 0.75-0.84 across a mask edge at ~0.79), so they are still
  detected.
- Motion in this view is close to continuous - the recorder comment below says as
  much - and Frigate re-runs detection per region it finds: `detection_fps` was
  measured at 26 with a 5 fps camera, at 27 ms inference, with face recognition and
  semantic search sharing the same iGPU.

Changing that is a decision about what this camera is for rather than a bug fix:
`review.alerts.required_zones: [voortuin]` (alerts only for the front garden),
a wider object mask over the path, `detect` on `stream_sub` instead of the 4K main
stream, or a higher `motion.contour_area`.

## Storage

`frigate-media` is 50 Gi and holds `recordings` (alerts 14 days, detections 7 days,
motion 0 - event clips only, see the comment in `config.yaml`) and `clips`. It has
filled up before: on 2026-09-19 the recorder hit ENOSPC and stopped moving segments
out of `/tmp/cache` without an alert, which is why `continuous` and `motion` are
both 0. On 2026-09-30 it stood at 42 of 50 GB with a 12 GB day from 2026-09-11 that
retention should already have removed - so when the volume looks full, look at
`recordings/` per day before assuming the retention settings are being honoured,
and remember that `record.alerts.retain.mode` (`all` vs `motion`) is the lever that
keeps only the moving window around an event.
