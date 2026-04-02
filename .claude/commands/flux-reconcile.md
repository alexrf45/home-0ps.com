Reconcile Flux kustomizations. If a kustomization name is provided as an argument, reconcile that specific one. Otherwise, reconcile all kustomizations and report their status.

For a specific kustomization:
```bash
flux reconcile kustomization $ARGUMENTS --with-source
```

For all kustomizations:
```bash
flux get kustomizations
```

After reconciling, show the current status and flag any that are not Ready.
