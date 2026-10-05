# PodinfoProdUnavailable

Synthetic requests to podinfo in prod, sent through the platform gateway every 10 seconds, are failing faster than the 99.5% availability SLO allows.

- **Page:** the error budget is burning at 14.4x (2% of the monthly budget in an hour) or 6x (5% in six hours). Users are affected now.
- **Ticket:** a slower burn, 3x or 1x. Not urgent, but the month's budget will run out if nothing changes.

## What this SLO sees that the others do not

This alert is based on probes, not on request counters, because Envoy's per-service counters only record responses that came back from podinfo. If the gateway answers on its own (no healthy backend, a route that no longer matches, an injected fault) the request never appears in them, and `PodinfoProdErrors` stays silent. So **this alert firing without `PodinfoProdErrors` points at the path to the app, not the app itself.**

## Triage

1. **Is it the app or the path?** Check whether pods are up and ready:
   ```sh
   kubectl get pods -n podinfo-prod
   kubectl get endpointslices -n podinfo-prod
   ```
   No ready endpoints means the gateway has nothing to send traffic to: look at why the pods are not ready (`kubectl describe pod`, recent deploys in Argo CD).

2. **Does the gateway still route it?**
   ```sh
   kubectl get httproute podinfo -n podinfo-prod -o jsonpath='{.status.parents[*].conditions}'
   kubectl get backendtrafficpolicy,securitypolicy -n podinfo-prod
   ```
   `Accepted` and `ResolvedRefs` should be `True`. An unexpected policy (fault injection, rate limiting) attached to the route is a likely cause; check who added it in git.

3. **Reproduce what the probe sees:**
   ```sh
   kubectl run probe-debug -n sre --rm -it --image=curlimages/curl --restart=Never -- \
     curl -sv -H 'Host: podinfo-prod.localtest.me' http://platform-gateway.envoy-gateway-system.svc/
   ```
   A 503 with `server: envoy` and no podinfo body means the gateway answered by itself.

4. **Is the gateway itself healthy?**
   ```sh
   kubectl get pods -n envoy-gateway-system
   kubectl logs -n envoy-gateway-system deploy/envoy-gateway --since=30m | grep -i error
   ```

## Mitigation

- A bad change in git (route, policy, values): revert the commit. Argo CD rolls it back within a minute.
- Pods not becoming ready after a deploy: roll back the podinfo version in `environments/prod/` in gitops-platform.

## Dashboard

Grafana, **podinfo SLOs**: the probe panel shows success and duration, and the budget panel shows how much of the month this incident has cost.
