Check overall cluster and node health.

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
talosctl health
```

Report any pods not in Running/Completed state and surface any Talos node issues.
