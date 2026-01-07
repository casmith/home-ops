# Cluster Recovery Steps

## Current Situation
- Node 192.168.10.4 (k8s-cp-3) has k8s-pi-8 configuration applied
- Talos API not responding on any nodes
- Kubernetes control plane is down
- Cluster is completely broken

## Root Cause
The upgrade script applied node configurations without properly targeting specific nodes,
causing the wrong config files to be applied to wrong machines.

## Recovery Plan

### Step 1: Boot k8s-cp-3 into Maintenance Mode (PHYSICAL ACCESS REQUIRED)

On the console of 192.168.10.4:

1. Reboot the machine
2. When GRUB bootloader appears, press `e` to edit
3. Find the line starting with `linux` and add `talos.config=none` at the end
4. Press Ctrl+X to boot
5. Node will boot into maintenance mode with API accessible

### Step 2: Apply Correct Configuration

From your workstation, once node is in maintenance mode:

```bash
cd /home/clay/work/home-ops/talos
talosctl apply-config --nodes 192.168.10.4 \
  --file clusterconfig/kubernetes-k8s-cp-3.yaml \
  --insecure \
  --mode=reboot
```

Wait for the node to reboot (2-3 minutes).

### Step 3: Fix Other Control Plane Nodes

Repeat Step 1 & 2 for each control plane node:

**k8s-cp-1 (192.168.10.33):**
```bash
talosctl apply-config --nodes 192.168.10.33 \
  --file clusterconfig/kubernetes-k8s-cp-1.yaml \
  --insecure \
  --mode=reboot
```

**k8s-cp-2 (192.168.10.44):**
```bash
talosctl apply-config --nodes 192.168.10.44 \
  --file clusterconfig/kubernetes-k8s-cp-2.yaml \
  --insecure \
  --mode=reboot
```

### Step 4: Bootstrap etcd (if needed)

Once all control plane nodes are online with correct configs:

```bash
# Check etcd status
talosctl -n 192.168.10.33 service etcd status

# If etcd cluster is broken, bootstrap on ONE node only:
talosctl -n 192.168.10.33 bootstrap
```

**WARNING:** Only run bootstrap ONCE on ONE node!

### Step 5: Fix Worker Nodes

For each worker node that has wrong config:

```bash
# k8s-pi-1 through k8s-pi-8
talosctl apply-config --nodes 192.168.10.71 --file clusterconfig/kubernetes-k8s-pi-1.yaml --insecure
talosctl apply-config --nodes 192.168.10.72 --file clusterconfig/kubernetes-k8s-pi-2.yaml --insecure
talosctl apply-config --nodes 192.168.10.73 --file clusterconfig/kubernetes-k8s-pi-3.yaml --insecure
talosctl apply-config --nodes 192.168.10.74 --file clusterconfig/kubernetes-k8s-pi-4.yaml --insecure
talosctl apply-config --nodes 192.168.10.75 --file clusterconfig/kubernetes-k8s-pi-5.yaml --insecure
talosctl apply-config --nodes 192.168.10.76 --file clusterconfig/kubernetes-k8s-pi-6.yaml --insecure
talosctl apply-config --nodes 192.168.10.77 --file clusterconfig/kubernetes-k8s-pi-7.yaml --insecure
talosctl apply-config --nodes 192.168.10.78 --file clusterconfig/kubernetes-k8s-pi-8.yaml --insecure
```

### Step 6: Verify Recovery

```bash
# Check all nodes are accessible
talosctl -n 192.168.10.33,192.168.10.44,192.168.10.4 health

# Check Kubernetes API
kubectl get nodes

# Check all pods
kubectl get pods -A
```

## Alternative: Nuclear Option (If Above Fails)

If the above doesn't work, you may need to:

1. Wipe and reinstall each node from Talos ISO/PXE
2. Apply fresh configurations
3. Bootstrap a new etcd cluster
4. Restore from backup (if you have one)

## What Went Wrong

The `upgrade-k8s-complete.sh` script had a critical bug in the `apply_configs()` function.
It used `talosctl apply-config --file $config` without `--nodes` flag, which caused
talosctl to broadcast configs to whatever nodes it could reach, resulting in
wrong configs being applied to wrong nodes.

## Prevention

Never use `talosctl apply-config` without explicitly specifying `--nodes <IP>`.
Always match the config file to the specific node IP address.
