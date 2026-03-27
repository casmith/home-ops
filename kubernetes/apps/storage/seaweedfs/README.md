# SeaweedFS

SeaweedFS provides S3-compatible object storage for the cluster.

- **Namespace:** `storage`
- **Internal endpoint:** `http://seaweedfs-s3-internal.storage.svc:8333`
- **External endpoint:** `https://s3.kalde.in`

## Creating a New Bucket

Buckets are created automatically when you first write to them via the S3 API. You can also create them explicitly using the admin credentials:

```bash
# Using mc (MinIO client)
mc alias set sw https://s3.kalde.in <admin_access_key> <admin_secret_key>
mc mb sw/my-new-bucket
```

## Adding S3 Credentials

Credentials are managed through 1Password and the ExternalSecret in `app/externalsecret.yaml`.

### 1. Add credentials to 1Password

In the `seaweedfs` 1Password item, add two new fields:

- `mynewapp_access_key` - the access key
- `mynewapp_secret_key` - the secret key

### 2. Add an identity to the ExternalSecret

Edit `app/externalsecret.yaml` and add a new identity block inside the `"identities"` array:

```json
{
  "name": "{{ .mynewapp_access_key }}",
  "credentials": [
    {
      "accessKey": "{{ .mynewapp_access_key }}",
      "secretKey": "{{ .mynewapp_secret_key }}"
    }
  ],
  "actions": [
    "Read:my-new-bucket",
    "List:my-new-bucket",
    "Write:my-new-bucket"
  ]
}
```

### 3. Commit and let Flux reconcile

Push the change to git. Flux will update the ExternalSecret, which regenerates the `seaweedfs-s3-secret`. The filer pods will reload automatically (via Reloader).

## Available Actions

| Action | Description |
|--------|-------------|
| `Admin` | Full administrative access (all buckets) |
| `Read:<bucket>` | Read objects from a specific bucket |
| `List:<bucket>` | List objects in a specific bucket |
| `Write:<bucket>` | Write/delete objects in a specific bucket |

Omit the `:<bucket>` suffix to grant access to all buckets (e.g., `"Read"` allows reading from any bucket).

## Existing Identities

| Identity | Buckets | Permissions |
|----------|---------|-------------|
| admin | all | Admin, Read, Write |
| terraform | `terraform-state` | Read, List, Write |
| backup | `beoftexas-backup` | Read, List, Write |
