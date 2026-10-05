# sre-reliability-lab

SLOs, alerting and game days for a Kubernetes platform, as code. The SLOs are defined once and generated into multi-window, multi-burn-rate alerts. The alerts are unit tested against synthetic data. And on every pull request, CI deploys the whole platform, breaks it on purpose, and checks that the right alert pages and the wrong ones stay silent.

It runs on top of [gitops-platform](https://github.com/vlad-radu-anca/gitops-platform) and measures its podinfo service in production. The platform provides Prometheus, Alertmanager, Grafana and the Envoy gateway; this repository owns everything about reliability.

[![CI](https://github.com/vlad-radu-anca/sre-reliability-lab/actions/workflows/ci.yaml/badge.svg)](https://github.com/vlad-radu-anca/sre-reliability-lab/actions/workflows/ci.yaml)
[![game day](https://github.com/vlad-radu-anca/sre-reliability-lab/actions/workflows/gameday.yaml/badge.svg)](https://github.com/vlad-radu-anca/sre-reliability-lab/actions/workflows/gameday.yaml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

## The SLOs

| SLO | Objective | SLI | Catches |
| --- | --- | --- | --- |
| availability | 99.5% | Synthetic request through the gateway every 10 s | outages, including errors the gateway generates itself |
| errors | 99.5% | Share of responses from podinfo that are 5xx, at the gateway | server errors from the app, at full request resolution |
| latency | 99% within 250 ms | Envoy's upstream latency histogram, at the gateway | slow responses |

Three SLIs for one service is deliberate, and was decided by measurement, not by default. Testing failures on the running platform showed that **Envoy leaves out of its per-service statistics every response it generates itself**: when no backend is healthy, or the gateway rejects a request, that request is missing from the counters entirely, rather than counted as an error. A request-based SLO alone would read 100% during a total outage. The probe covers that blind spot, and the request-based SLOs cover what a probe is too coarse to see. The measurements are in [ADR 0001](docs/decisions/0001-three-slis.md).

## How an SLO becomes a page

```
slos/podinfo-prod.yaml            the SLO spec: objective, SLI queries, alert names
        │  make generate (Sloth)
        ▼
manifests/sre/slo-rules/          recording rules over 5m to 30d windows, plus
        │                         multi-window multi-burn-rate alerts
        │  Argo CD
        ▼
Prometheus ──▶ Alertmanager ──▶ page:   immediately, repeat hourly
               (slo-routing)    ticket: batched, repeat daily
```

Alerts follow the multi-window, multi-burn-rate method from the [Google SRE workbook](https://sre.google/workbook/alerting-on-slos/):

| Severity | Fires when | Means |
| --- | --- | --- |
| page | 14.4x burn over 1 h and 5 m, or 6x over 6 h and 30 m | 2% of the monthly budget gone in an hour: users are hurting now |
| ticket | 3x over 1 d and 2 h, or 1x over 3 d and 6 h | the month's budget will run out at this rate |

The short window in each pair makes an alert resolve quickly once a problem is fixed; the long one stops a brief spike from paging. Every alert links to its [runbook](runbooks/).

## Tested before it ships

**Alert unit tests** ([tests/](tests/podinfo-prod.test.yaml)) feed synthetic metrics into the generated rules with `promtool` and assert exactly which alerts fire:

| Test | Expects |
| --- | --- |
| outage | page and ticket within minutes |
| a single failed probe after six healthy hours | nothing |
| 20% errors after a clean half hour | page and ticket |
| 2% errors for three hours | ticket, **not** a page |
| 0.1% errors, inside the budget | nothing |
| every request slower than 250 ms | page and ticket |

The first run of these tests caught a real bug: the probe SLI carried the probe's own labels into the alerts, which would have produced one page per probe target.

Unit tests only check the rules against data shaped the way the test author expects, though, and the first game day in CI caught what they could not: **the latency SLO could never fire.** Envoy exposes its 250 ms histogram bucket as `le="250"`, but Prometheus 3 normalises bucket bounds on ingestion and stores it as `le="250.0"`. The SLI matched no series, evaluated to no data, and an alert on no data stays silent. The test data had made the same assumption as the rule. Both now use the stored form, and the test comment records why.

**Game days** ([scripts/gameday.sh](scripts/gameday.sh)) run against the deployed platform: steady load with k6, a clean baseline, then a fault, then assertions on Alertmanager itself, including that the page reached the receiver.

| Scenario | Fault | Must page | Must stay silent |
| --- | --- | --- | --- |
| `pod-kill` | Chaos Mesh kills every podinfo pod at once | nothing | all three |
| `outage` | the gateway answers every podinfo request with 503 | `PodinfoProdUnavailable` | `PodinfoProdErrors`, which cannot see gateway-generated errors |
| `latency` | Chaos Mesh adds 300 ms of network delay to podinfo | `PodinfoProdSlow` | `PodinfoProdUnavailable`, `PodinfoProdErrors` |

The `outage` scenario asserts the blind spot on purpose: if the errors SLO ever started seeing gateway errors, the test would fail and the design would need revisiting.

## Layout

```
slos/                 SLO specs, the source of truth
manifests/sre/        what Argo CD deploys: generated rules, the probe, the Envoy
                      scrape config, alert routing, an alert receiver, the dashboard
apps/                 the Argo CD Applications this repository owns, rendered by
                      gitops-platform's sre-apps Application
tests/                promtool alert unit tests
chaos/                fault experiments for game days
load/                 k6 load for game days
scripts/gameday.sh    runs a scenario and checks the alerting
runbooks/             one per alert, linked from the alert itself
docs/decisions/       architecture decision records
```

## Running it

Everything that does not need a cluster runs in pinned containers, so Docker is the only requirement:

```sh
make generate     # regenerate rules after editing slos/
make test         # promtool rule checks and alert unit tests
make validate     # render and validate every manifest against its schema
```

For game days, bring up gitops-platform with this layer, then run a scenario:

```sh
# in gitops-platform
make cluster argocd
make root SRE_REVISION=main
make wait

# here
make gameday SCENARIO=outage      # or latency, pod-kill
```

Grafana's **podinfo SLOs** dashboard (http://grafana.localtest.me:8080) shows the error budget remaining, the burn rate and each SLI against its objective. Alertmanager is at http://alertmanager.localtest.me:8080, and every delivered notification is in `kubectl logs -n sre deploy/alert-sink`.

## CI

| Workflow | What |
| --- | --- |
| [CI](.github/workflows/ci.yaml) | Regenerates the rules and fails if they differ from the committed ones, runs the alert unit tests, validates every manifest, and lints the scripts |
| [game day](.github/workflows/gameday.yaml) | Deploys gitops-platform on kind with this repository at the commit under test, then runs all three game days |

## License

[Apache-2.0](LICENSE)
