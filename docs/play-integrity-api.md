# Play Integrity API deployment

`play-integrity-api` is an optional internal service. It is disabled by default because it needs private runtime material.

## Required private inputs

Keep these outside Git and inject them through live values, Kubernetes Secrets, and the runtime PVC:

- `PLAY_INTEGRITY_API_TOKEN`: bearer token used by `wa-app` and direct callers.
- `WA_APP_PLAY_INTEGRITY_API_TOKEN`: same bearer token for `wa-app`.
- `PLAY_INTEGRITY_SERVICE_CONFIG_JSON`: service config JSON. Use placeholders in tracked values only. The long-running path should configure `dg-native-ss-runner.py` against runtime VM material in the PVC.
- `byte-v-forge-play-integrity-api-private` Secret with `keybox.xml`.
- `byte-v-forge-play-integrity-api-data` PVC for current VM runtime material under `/var/lib/play-integrity-api/vm/current` and runner output under `/var/lib/play-integrity-api/work/...`.

## Internal URL

When enabled, set:

```yaml
configEnv:
  WA_APP_PLAY_INTEGRITY_API_URL: http://byte-v-forge-play-integrity-api:8088/v1/play-integrity/tokens

workloads:
  play-integrity-api:
    enabled: true
```

## Safety defaults

- `maxConcurrency` should stay low, normally `1`.
- `vmRunnerAcquireTimeoutSeconds` should be finite; concurrent requests serialize behind the single VM lock and overflow as HTTP 429.
- `persistRunMaterial` should stay `false` for long-running deployments.
- External callers pass the hardware parameters inline in the token request; `hardwareProfileId` is not part of the public deployment contract.
- Do not write keybox, rawDG, backend requests/responses, tokens, or endpoint credentials into tracked values.
- If the API returns `invalid backendResponse` with a short rawDG, the fixed VM runner is producing a legacy/stub shape instead of a live DroidGuard container.
