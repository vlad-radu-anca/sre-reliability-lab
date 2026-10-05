# PodinfoProdSlow

More than 1% of requests to podinfo in prod take longer than 250 ms, measured at the gateway, faster than the latency SLO allows.

- **Page:** a fast burn. A large share of requests is slow right now.
- **Ticket:** a slow burn. Latency has crept up and will exhaust the month's budget.

The measurement is Envoy's upstream request time: from the gateway forwarding the request to the full response arriving. It includes the network between the gateway and podinfo, not just podinfo's processing time.

## Triage

1. **Is podinfo slow, or the path to it?** Compare podinfo's own view with the gateway's. On the dashboard, the latency panel shows the gateway's p50 and p99. If podinfo's own metrics are fast while the gateway's are slow, the time is spent in between: network, node or proxy.

2. **Resource pressure?**
   ```sh
   kubectl top pods -n podinfo-prod
   kubectl describe pods -n podinfo-prod | grep -A3 -i throttl
   ```
   CPU throttling against a low limit is a common cause of a sudden latency increase.

3. **More traffic than usual?** The dashboard's request rate panel. A latency rise that follows a traffic rise is a capacity problem: scale out (`replicaCount` in `environments/prod/podinfo.yaml`).

4. **A node problem?** If only pods on one node are slow, cordon it and let the pods move.

## Mitigation

- Capacity: raise `replicaCount` for prod in gitops-platform.
- A release made it slower: roll back the version.
- One node: `kubectl cordon <node>`, then delete the slow pods so they reschedule.
