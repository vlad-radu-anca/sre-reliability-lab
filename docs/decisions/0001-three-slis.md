# 1. Three SLIs for one service, because no single signal sees every failure

Date: 2026-10-05

Status: accepted

## Context

The SLOs should measure what users experience, so the obvious source is the platform gateway: every request for podinfo passes through the Envoy proxy, and Envoy counts responses and their latency per service. The plan was a single request-based SLI: the share of requests answered without a 5xx.

Before writing any rules, the failure modes were tested on the running platform, with traffic through the gateway and Envoy's statistics read before and after each fault.

| Fault | What the client saw | Per-service counter (`envoy_cluster_upstream_rq_xx`) | Per-virtual-host counter (`envoy_vhost_vcluster_upstream_rq_xx`) | Listener counter (`envoy_http_downstream_rq_xx`) |
| --- | --- | --- | --- | --- |
| podinfo returns a 500 | 500 | counted | counted | counted |
| All pods killed at once | 2 × 503 from Envoy, "no healthy upstream" | not counted, and the counters reset | not counted | counted |
| Fault injected at the gateway, 50% abort | 23 × 503 from Envoy | not counted | not counted | counted |
| 300 ms of network delay | slow 200s | counted in the latency histogram | counted in the latency histogram | counted |

Two findings shaped the design.

**Envoy does not count responses it generates itself in any per-service statistic.** When there is no healthy backend, or the gateway rejects the request itself, the request is absent from the per-service counters, not counted as an error. A request-based SLO on those counters would read 100% during a total outage of the service, because the failing requests never enter the ratio.

**The only counter that sees those responses, the listener's downstream counter, is shared by every hostname on the gateway.** It cannot be attributed to podinfo.

The per-route cluster counters were also rejected for a third reason: they reset when the backend's endpoints change, which happens on every pod restart. The per-virtual-host counters, enabled in gitops-platform with `enableVirtualHostStats`, survive it.

## Decision

Three SLOs for podinfo in prod, each based on the signal that can actually see its failure mode:

| SLO | SLI | Catches | Blind to |
| --- | --- | --- | --- |
| availability, 99.5% | Synthetic probe every 10 s, sent through the gateway with the production hostname | outages, gateway-generated errors, broken routes | errors too infrequent for a 10 s probe to land on |
| errors, 99.5% | Per-virtual-host 5xx share | server errors podinfo returns, at full request resolution | anything the gateway answers itself |
| latency, 99% under 250 ms | Per-virtual-host latency histogram | slow responses | requests that never reach podinfo |

Each blind spot is covered by another SLO. The game day `outage` asserts the gap explicitly: the availability SLO pages, and the errors SLO stays silent.

## Consequences

- Three alerts can fire for one incident: a slow, failing release could trigger all of them. Alertmanager groups by alert name and SLO, and each runbook says what the combination of alerts means.
- The probe costs almost nothing, but it is a sample: at one probe every 10 seconds, it cannot detect an error rate of a few percent quickly. That is the errors SLO's job.
- The design depends on Envoy's statistics. Moving to another gateway means re-checking which failures its counters see, which is what this record is for.

## Alternatives considered

- **Access logs turned into metrics.** Envoy's access log records every response, including its own. Counting log lines per hostname would give one complete request-based SLI, but it needs a log pipeline the platform does not have.
- **One listener per hostname.** The listener counter would then be per service, but plain HTTP listeners on the same port are merged by Envoy, and splitting them only to get metrics would distort the gateway's configuration.
