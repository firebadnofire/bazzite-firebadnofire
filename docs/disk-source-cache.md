# bootc source-image cache operations

## Architecture and safety boundary

Both disk workflows resolve `:stable` to an OCI digest before touching the
cache. Their prepare job then runs rootful Podman from the pinned
bootc-image-builder container and pulls only the exact reference:

```text
pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:...
```

Before this cache existed, both matrix jobs pulled every blob absent from their
new, empty `bib-storage-<run>-<attempt>-<type>` volume. Those volumes were
deleted after each job, so even unchanged multi-gigabyte source-image layers
were unavailable to the sibling job and the next workflow run.

The workflow now keeps two labeled volumes in the dedicated DinD daemon:

| Volume | Contents | Access |
| --- | --- | --- |
| `bazzite-firebadnofire-bib-image-cache-v1` | Rootful Podman overlay image store containing exact source manifests, configuration, and layers | Warm-up/maintenance read-write; builders read-only |
| `bazzite-firebadnofire-bib-image-cache-lock-v1` | `store.lock` | Exclusive for warm-up/maintenance; shared for complete builds |

Every QCOW2/ISO job retains a separate writable
`bib-storage-<run>-<attempt>-<type>` graphroot. The persistent store is listed
as an `additionalimagestores` path in `disk_config/ci-storage.conf`, a mechanism
containers/storage defines for additional read-only image stores. The builders
can read identical cached layers while their temporary images, metadata, and
locks remain isolated. This avoids sharing a writable container-storage
database or separate containers' `/dev/shm` locking state.

bootc-image-builder/osbuild does not reliably resolve the external registry
digest name directly from an additional image store even when Podman can
inspect it. A writable tag or a containers/storage copy made while that
additional store remains visible is also insufficient: osbuild can resolve the
image ID and still fail to find layers that remain owned by the read-only
store. While holding the shared cache lock, the builder resolves the canonical
digest reference to a full Podman image ID, requires an empty per-job store,
and reflink-copies the cache's immutable `overlay`, `overlay-images`, and
`overlay-layers` directories into it. Podman's graphroot-specific `libpod`
database is deliberately excluded.

The builder then switches from `ci-storage.conf` to the primary-store-only
`ci-writable-storage.conf`, verifies that the digest reference resolves from
that store, and creates `localhost/bazzite-firebadnofire-build-source:cached`.
The local name must be a writable-store entry with the identical image ID.
The operation is local and cannot contact the registry. The runner's Btrfs
filesystem provides same-filesystem reflinks between the cache and per-job
Docker volumes; `--reflink=always` fails closed instead of unexpectedly making
a fully allocated copy. bootc-image-builder receives the verified local name,
while artifact filenames and release notes continue to use the originally
resolved registry digest.

The volumes are inner-Docker volumes. Their DinD paths are:

```text
/var/lib/docker/volumes/bazzite-firebadnofire-bib-image-cache-v1/_data
/var/lib/docker/volumes/bazzite-firebadnofire-bib-image-cache-lock-v1/_data
```

Compose persists that entire `/var/lib/docker` tree in its `docker-data`
volume. On the runner host, find the outer physical mountpoint rather than
guessing the Compose project prefix:

```bash
cd /home/william/docker/forgejo-runner
docker volume inspect --format '{{.Name}} -> {{.Mountpoint}}' \
  "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}' forgejo-runner-dind)"
```

The cache's host path is that reported mountpoint followed by
`/volumes/bazzite-firebadnofire-bib-image-cache-v1/_data`; the lock path uses
the corresponding `...-lock-v1/_data` suffix.

No data under the cache is a credential. The source package is public. The
cache is nevertheless trusted build input only after Podman verifies the
requested registry reference and the workflow confirms the exact digest.

Upstream references:

- [containers/storage `storage.conf`](https://github.com/containers/storage/blob/main/storage.conf)
  defines `additionalimagestores` as additional read-only image stores.
- [bootc-image-builder](https://github.com/osbuild/bootc-image-builder#installation)
  requires the source image in rootful containers/storage and mounts that
  storage at `/var/lib/containers/storage`.

## Inspecting the cache

Run these on `192.168.86.54`. They address the inner Docker daemon by executing
its Docker CLI inside the DinD container:

```bash
cache=bazzite-firebadnofire-bib-image-cache-v1
lock=bazzite-firebadnofire-bib-image-cache-lock-v1
bib='quay.io/centos-bootc/bootc-image-builder:latest@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b'

docker exec forgejo-runner-dind docker volume inspect "$cache" "$lock"
docker exec forgejo-runner-dind du -sh "/var/lib/docker/volumes/${cache}/_data"
docker exec forgejo-runner-dind docker run --rm --privileged \
  --security-opt label=type:unconfined_t \
  --volume "${cache}:/var/cache/bib-image-store" \
  --volume "${lock}:/var/cache/bib-cache-lock" \
  --entrypoint /usr/bin/bash "$bib" -c '
    set -Eeuo pipefail
    exec 9>/var/cache/bib-cache-lock/store.lock
    flock --shared 9
    podman --root /var/cache/bib-image-store \
      --runroot /run/bib-cache-inspect \
      --storage-driver overlay images --digests --no-trunc
  '
```

The shared lock lets inspection coexist with builds but blocks an exclusive
refresh or prune. Do not edit files under `_data` directly.

## Pruning stale content

First inspect the image list above and confirm which exact digests are no
longer needed. Then remove only selected stale digest references while holding
the exclusive lock:

```bash
cache=bazzite-firebadnofire-bib-image-cache-v1
lock=bazzite-firebadnofire-bib-image-cache-lock-v1
bib='quay.io/centos-bootc/bootc-image-builder:latest@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b'
stale='pubcode.archuser.org/universalblue/bazzite-firebadnofire@sha256:<old-digest>'
docker exec -e STALE_IMAGE="$stale" forgejo-runner-dind docker run --rm --privileged \
  --security-opt label=type:unconfined_t \
  --env STALE_IMAGE \
  --volume "${cache}:/var/cache/bib-image-store" \
  --volume "${lock}:/var/cache/bib-cache-lock" \
  --entrypoint /usr/bin/bash "$bib" -c '
    set -Eeuo pipefail
    exec 9>/var/cache/bib-cache-lock/store.lock
    echo "Waiting for all active disk builds to release the cache"
    flock --exclusive 9
    podman --root /var/cache/bib-image-store \
      --runroot /run/bib-cache-prune \
      --storage-driver overlay image rm "${STALE_IMAGE}"
    podman --root /var/cache/bib-image-store \
      --runroot /run/bib-cache-prune \
      --storage-driver overlay image prune --force
    du -sh /var/cache/bib-image-store
  '
```

This is bounded to an operator-selected immutable digest and then removes only
unreferenced layers. Do not use a blanket inner-daemon `docker volume prune`:
the daemon also contains job handoff/output volumes, and a broad prune does not
participate in the cache lock. If the selected digest is needed again, the next
workflow run is a safe cache miss and downloads it normally.

## Rollback or complete disposal

Reverting the workflow and `disk_config/ci-storage.conf` restores the former
per-job pull behavior; the two persistent volumes then remain unused. To remove
them, first confirm there is no active disk workflow and that no inner
container mounts either volume:

```bash
cache=bazzite-firebadnofire-bib-image-cache-v1
lock=bazzite-firebadnofire-bib-image-cache-lock-v1
docker exec forgejo-runner-dind docker ps -a \
  --filter "volume=${cache}"
docker exec forgejo-runner-dind docker ps -a \
  --filter "volume=${lock}"
```

If and only if that output is empty, remove the exact volumes:

```bash
docker exec forgejo-runner-dind docker volume rm "$cache" "$lock"
```

Their removal does not damage the runner or the published image. It only makes
the next disk workflow a cold pull. No runner Compose change is part of this
implementation, so there is no external configuration to roll back.

## Proving reuse on a second build

Dispatch the disk workflow twice against the same published digest. In the
first run, **Warm the persistent bootc source-image cache** may show registry
blob copies. In the second run, verify all of the following in the Actions log:

1. `Persistent cache before pull` already lists the exact repository digest.
2. Podman's pull reports that the image is already present or up to date rather
   than copying every blob again.
3. `Persistent cache after pull` retains the same image ID and digest.
4. Both matrix jobs print `Cache reuse:` for that exact digest and list it
   under `Read-only images visible through additionalimagestores`.
5. Each job prints `Canonical registry source: ...@sha256:...`, the cached image
   ID, `Promoting cached image data into the writable store with reflinks`,
   `Writable store resolves canonical source: ...@sha256:...`,
   `Writable build source: localhost/bazzite-firebadnofire-build-source:cached`,
   the writable image ID, and `Confirmed cached and writable-store image IDs
   match`.
6. The builder line names only the verified `localhost/...:cached` reference;
   neither selection nor cache population ever uses `:stable` after digest
   resolution.

For independent runner-side evidence, run the inspection commands before and
after the second dispatch and record the exact image inventory and `du -sh`
size. A second successful workflow plus these cache logs proves local
containers/storage reuse. Static validation alone does not prove the hosted
runner reused blobs, and successful disk creation does not prove VM boot or
physical-hardware compatibility.
