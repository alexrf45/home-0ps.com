kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: wallabag-manual-backup-$(date +%Y%m%d-%H%M%S)
  namespace: wallabag
spec:
  cluster:
    name: wallabag-prod-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
