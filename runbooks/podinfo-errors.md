# PodinfoProdErrors

podinfo in prod is returning 5xx responses faster than the 99.5% errors SLO allows. The errors come from podinfo itself: Envoy forwarded the request and podinfo answered with a server error.

- **Page:** a fast burn (14.4x over 1 hour, or 6x over 6 hours). Users are affected now.
- **Ticket:** a slow burn (3x over a day, or 1x over three days). A steady trickle of errors that will exhaust the month's budget.

## Triage

1. **Did something just change?** Most error bursts follow a deploy. In Argo CD, check the history of `podinfo-prod`; in git, `environments/prod/podinfo.yaml` in gitops-platform.

2. **What is podinfo logging?** Errors, panics, failing dependencies:
   ```sh
   kubectl logs -n podinfo-prod -l app.kubernetes.io/name=podinfo --since=15m --prefix
   ```
   The dashboard's status class panel shows whether the errors are constant or spiky, and when they started.

3. **All pods, or one?** One bad pod among several points at the node or at that pod's state; all pods points at the release or a dependency.
   ```sh
   kubectl top pods -n podinfo-prod
   kubectl get pods -n podinfo-prod -o wide
   ```

4. **Is it everything, or just this service?** Compare with the other environments on the dashboard. Errors in dev and staging too, on the same version, point at the release.

## Mitigation

- Errors started with a release: roll back the version in `environments/prod/podinfo.yaml` and let Argo CD sync. Investigate afterwards.
- A single unhealthy pod: delete it and let the Deployment replace it.

## Note

This alert cannot see requests the gateway answers itself (no healthy backend, a broken route). If users report failures but this alert is quiet, check `PodinfoProdUnavailable`.
