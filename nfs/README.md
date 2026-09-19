# NFS

[![App Status](https://argocd.local/api/badge?name=nfs&revision=true)](https://argocd.local/applications/nfs)
![NFS](https://img.shields.io/badge/NFS_Provisioner-nfs--client-4A90D9)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes&logoColor=white)

Dynamic NFS volume provisioner for the homelab cluster. Provides the `nfs-client` StorageClass so that PersistentVolumeClaims across all namespaces can be satisfied automatically using the NFS share on the master node.

---

## Architecture

```
  ┌───────────────────────────────────┐
  │  master node (192.168.56.10)      │
  │  NFS Server: exports /share       │
  └───────────────┬───────────────────┘
                  │  NFS mount
  ┌───────────────▼───────────────────┐
  │  nfs-subdir-external-provisioner  │
  │  (Deployment, namespace: nfs)     │
  │  StorageClass: nfs-client         │
  └───────────────┬───────────────────┘
                  │  creates subdir per PVC
  ┌───────────────▼───────────────────┐
  │  PVCs in any namespace            │
  │  storageClassName: nfs-client     │
  │  (Loki, Zot, Prometheus, ...)     │
  └───────────────────────────────────┘
```

The NFS server itself is set up by Ansible on the master node (`/share` exported to `192.168.56.0/24`). The Helm chart only deploys the in-cluster provisioner that watches for PVCs and creates subdirectories under `/share` automatically.

---

## Service Details

| Property | Value |
|---|---|
| Namespace | `nfs` |
| NFS Server | `192.168.56.10` (master node) |
| NFS Export Path | `/share` |
| StorageClass | `nfs-client` |
| Helm chart | `nfs-subdir-external-provisioner/nfs-subdir-external-provisioner` |

---

## Directory Structure

```
NFS/
└── helm/
    └── nfs/
        ├── Chart.yaml    # nfs-subdir-external-provisioner chart
        └── values.yaml   # server .10, path /share, storageClass nfs-client
```

---

## Using the StorageClass

Any workload in any namespace can request NFS-backed storage:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
```

Each PVC creates a subdirectory under `/share` on the master node:
```
/share/
  nfs-my-namespace-my-data-pvc-<uid>/
```

---

## NFS Server Setup

The NFS server is configured by Ansible during cluster bootstrap (see `k8s-vagrant-ansible`). Manual verification:

```bash
# On the master node (vagrant ssh master)
cat /etc/exports
# Should contain: /share 192.168.56.0/24(rw,sync,no_subtree_check,no_root_squash)

showmount -e localhost
```

---

## Troubleshooting

**PVC stuck in `Pending`**
```bash
# Check provisioner pod is running
kubectl get pods -n nfs

# Check provisioner logs
kubectl logs -n nfs -l app=nfs-subdir-external-provisioner

# Verify NFS server is reachable from a node
kubectl run nfs-test --image=busybox --rm -it -- \
  wget -O- 192.168.56.10:/share 2>&1 | head
```

**PVC bound but pod fails to start (`MountVolume.SetUp failed`)**
```bash
# nfs-common must be installed on all nodes (done by Ansible)
# Verify on a node:
vagrant ssh worker1 -- dpkg -l nfs-common
```

**Disk space on master**
```bash
# SSH into master
vagrant ssh master
df -h /share
ls /share | wc -l   # number of PVC directories
```
