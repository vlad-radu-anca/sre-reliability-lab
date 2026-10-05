{{/*
Same sync policy as the platform's own Applications. ServerSideApply is needed
for the Chaos Mesh CRDs, which exceed the client-side annotation size limit.
*/}}
{{- define "sre.syncPolicy" -}}
automated:
  prune: true
  selfHeal: true
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
retry:
  limit: 10
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m
{{- end }}
