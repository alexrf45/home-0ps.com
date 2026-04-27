Show the current state of all Flux resources in the cluster.

```bash
flux get kustomizations
flux get helmreleases -A
flux get sources git -A
```

Summarize any resources that are not Ready and surface any errors.
