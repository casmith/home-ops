# Running Multiple Kubernetes Clusters with Shared Domain

This document explains how to safely run multiple Kubernetes clusters that share the same domain name (kalde.in) without DNS conflicts.

## The Problem

When running multiple external-dns instances against the same domain, they can conflict by:
- Deleting each other's DNS records
- Fighting over record ownership
- Causing DNS records to flap between states

## How external-dns Prevents Conflicts

external-dns uses **TXT records** to track ownership of DNS records. When it creates a DNS record, it also creates a corresponding TXT record containing metadata:

```
k8s.myservice.kalde.in TXT "heritage=external-dns,external-dns/owner=<txtOwnerId>,..."
```

With `policy: sync`, external-dns will:
- Only manage/delete records that have its own `txtOwnerId` in the TXT record
- Ignore records created by other external-dns instances
- Allow multiple instances to safely coexist on the same domain

## Solution: Use Different txtOwnerId Per Cluster

### Cluster 1 Configuration

File: `kubernetes/apps/network/cloudflare-dns/app/helmrelease.yaml`

```yaml
values:
  txtPrefix: k8s.
  txtOwnerId: cluster1  # or "production", "homelab", etc.
  domainFilters: ["${SECRET_DOMAIN}"]
  policy: sync
```

### Cluster 2 Configuration

```yaml
values:
  txtPrefix: k8s.
  txtOwnerId: cluster2  # MUST be different from cluster1
  domainFilters: ["${SECRET_DOMAIN}"]
  policy: sync
```

## Current Configuration

Our current setup uses:
- `txtOwnerId: default` (should be changed to something more specific like `cluster1`)
- `txtPrefix: k8s.`
- `domainFilters: ["${SECRET_DOMAIN}"]`
- `policy: sync`

**Action Required**: Before setting up a second cluster, change the current cluster's txtOwnerId from `default` to `cluster1` or another unique identifier.

## Cloudflare Tunnel Options

You have two options for Cloudflare tunnels with multiple clusters:

### Option 1: Separate Tunnels (Recommended)
Each cluster has its own Cloudflare tunnel with different CNAME targets:
- Cluster 1: `*.cluster1.cfargotunnel.com`
- Cluster 2: `*.cluster2.cfargotunnel.com`

Benefits:
- Complete isolation
- Independent tunnel management
- Easier troubleshooting

### Option 2: Shared Tunnel
Both clusters point to the same `*.cfargotunnel.com` CNAME.

Benefits:
- Simpler Cloudflare configuration
- Fewer tunnels to manage

Drawback:
- Less isolation between clusters

## Certificate Management

Let's Encrypt certificates work seamlessly with multiple clusters:
- Both clusters can use the same Cloudflare API token for DNS-01 challenges
- cert-manager instances won't conflict
- Each cluster manages its own Certificate resources
- DNS-01 challenge only requires DNS record creation (no conflicts)

## Internal-Only Services

Both clusters can also host internal-only services using:
- DNS-01 challenge for Let's Encrypt certificates
- Internal gateway that doesn't route through Cloudflare tunnel
- No DNSEndpoint creation for internal services

See current setup:
- External Gateway: `192.168.10.251` - routes through Cloudflare tunnel
- Internal Gateway: `192.168.10.252` - internal network only
- Both use the same wildcard Let's Encrypt certificate

## Important Notes

1. **Unique txtOwnerId is critical** - This is the only mechanism preventing conflicts
2. **txtPrefix can be the same** - It just namespaces the TXT records
3. **domainFilters can be the same** - Both can manage `kalde.in`
4. **No hostname overlap** - Ensure services in different clusters use different hostnames
5. **Change existing cluster first** - Update the txtOwnerId before deploying the second cluster

## Verification

After deploying multiple clusters, verify the setup by:

1. Check TXT records in Cloudflare:
   ```bash
   dig TXT k8s.myservice.kalde.in
   ```

2. Look for the owner ID in the TXT record:
   ```
   "heritage=external-dns,external-dns/owner=cluster1,..."
   ```

3. Verify each cluster only manages its own records:
   ```bash
   kubectl logs -n network deployment/cloudflare-dns
   ```

## References

- external-dns documentation: https://github.com/kubernetes-sigs/external-dns
- Current cloudflare-dns config: `kubernetes/apps/network/cloudflare-dns/app/helmrelease.yaml`
- Gateway configs: `kubernetes/apps/kube-system/cilium/gateway/`
