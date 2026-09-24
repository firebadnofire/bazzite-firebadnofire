# Disk artifact handoff and FinalizeArtifact diagnosis

## Confirmed path and remaining uncertainty

The former workflow used
`https://code.forgejo.org/forgejo/upload-artifact@16871d9e8cfcf27ff31822cac382bbb5450f1e1e`,
Forgejo's patched **v4.3.1**, with ZIP compression level 0. Its consumer was
`forgejo/download-artifact@d8d0a99033603453ad2255e58720b460a0555e1e`.
The public server version endpoint returned `14.0.5+gitea-1.22.0` during this
investigation. This Forgejo version implements the v4 artifact API; replacing
the action with GitHub's upstream action or downgrading it is not the diagnosis.

The uploader constructs a POST using the origin of `ACTIONS_RESULTS_URL`:

```text
/twirp/github.actions.results.api.v1.ArtifactService/FinalizeArtifact
```

For the normal public endpoint that is
`https://pubcode.archuser.org/twirp/github.actions.results.api.v1.ArtifactService/FinalizeArtifact`.
The actual job's results URL determines whether an internal origin was used.
This is not `/api/v1/...` and is separate from the preceding chunk PUTs to
`.../UploadArtifact?comp=block` and the block-list PUT. The finalization request
itself is small JSON containing identifiers, ZIP size, and ZIP SHA256. The
logged ZIP checksum is not the raw ISO's checksum.

In Forgejo 14.0.5, finalization synchronously opens the chunks, merges them into
a new storage object while checking SHA256, updates the database, and deletes
the chunks before returning JSON. A completed blob upload therefore does not
mean finalization is cheap or already complete. During merging, storage needs
room for the chunks **and** the merged object. The pinned client uses 8 MiB
chunks; about 7 GB means roughly 840–900 concurrently opened chunk readers per
artifact. Concurrent matrix finalizations can amplify I/O and descriptor use.

The pinned client calls `JSON.parse()` **before** handling HTTP error status;
an HTML 502/504/error page becomes `Unexpected token '<'`, and that syntax error
bypasses its normal retry handling. Without the failed response's HTTP status,
timing, and server logs, the exact deployed cause is **not confirmed**.

| Evidence | Likely cause / next check |
| --- | --- |
| 504 at a consistent timeout, nginx `upstream timed out ... while reading response header` | Merge/hash took longer than proxy read timeout. nginx's default is 60 seconds. |
| 502, upstream prematurely closed/reset, Forgejo restart | Process crash, OOM, connection failure, or server write deadline. |
| Forgejo `Error merge chunks`, `save merged file error`, `open chunk error` | Full disk/inodes, storage backend errors, permission failure, missing chunks, or too many open files. |
| 413 on chunk PUT or block-list PUT | Proxy request limit or Forgejo owner artifact quota; distinguish using both logs. |
| 401/403/redirect/HTML login or WAF page | Expired runtime authorization, cancelled task, auth proxy, routing, or edge filtering. |
| Checksum mismatch or database update error | Storage/data corruption or database failure; do not publish or bypass verification. |

The inspected finalizer has no fixed 7 GB size ceiling. Owner artifact quota
checks occur in the upload handler; `[attachment] MAX_SIZE` is not an Actions
artifact size setting. Successful chunk/block-list upload makes a body-size
limit less likely at finalization: increasing `client_max_body_size` alone
does not fix a timeout on a small JSON POST.

Source references:

- [Pinned upload client](https://code.forgejo.org/forgejo/upload-artifact/src/commit/16871d9e8cfcf27ff31822cac382bbb5450f1e1e/dist/upload/index.js)
- [Forgejo v14.0.5 finalizer and upload quota checks](https://codeberg.org/forgejo/forgejo/src/tag/v14.0.5/routers/api/actions/artifactsv4.go)
- [Forgejo chunk merge and hashing](https://codeberg.org/forgejo/forgejo/src/tag/v14.0.5/routers/api/actions/artifacts_chunks.go)
- [nginx proxy read timeout](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_read_timeout)
- [Pinned release action: draft, upload, publish](https://code.forgejo.org/actions/forgejo-release/src/commit/98265452477dafb3f0f27ba9c462c90b18cb44fd/forgejo-release.sh)

## Server-side evidence to collect

Use the failed job's UTC timestamp, run ID, artifact name `disk-installer-iso`,
and request path to correlate logs. Substitute actual container/service names;
these are read-only checks on the Forgejo/proxy host, not the Actions runner:

```bash
docker ps --format '{{.Names}}\t{{.Image}}'
# Replace names and narrow --since/--until to the failed upload window.
docker logs --timestamps --since 30m forgejo 2>&1 |
  grep -Ei 'FinalizeArtifact|merge chunks|open chunk|save merged|checksum|quota|panic|timeout|database'
docker logs --timestamps --since 30m nginx 2>&1 |
  grep -Ei 'FinalizeArtifact|upstream|too large|timed out'
# If nginx writes files instead of stdout/stderr:
sudo grep -F 'FinalizeArtifact' /var/log/nginx/access.log /var/log/nginx/error.log
docker inspect --format '{{json .State}}' forgejo
sudo journalctl -k --since '30 minutes ago' | grep -Ei 'oom|out of memory|killed process|I/O error'
```

If services run under systemd, use `journalctl -u forgejo` and `journalctl -u
nginx` for the same window. Inspect the actual Actions storage backend selected
by `[storage.actions_artifacts]` / legacy `[actions.artifacts]`, including S3 or
MinIO logs if applicable. Check free bytes and inodes on that filesystem, not
only the runner. Check the Forgejo process's `/proc/<pid>/limits` and current
`/proc/<pid>/fd` count; the shell's `ulimit` may differ from the service's limit.

The useful nginx access fields are `$status`, `$upstream_status`,
`$request_time`, `$upstream_response_time`, `$upstream_addr`, `$request_length`,
and `$uri`. Prefer `$uri` over full query strings: signed chunk URLs contain
credentials. Do not log Authorization headers, runtime tokens, or signed URLs.
Inspect effective `nginx -T` locally for the matching location's
`proxy_read_timeout`, `proxy_send_timeout`, `proxy_intercept_errors`,
`error_page`, `client_max_body_size`, and any upstream CDN/load-balancer timeout.
Do not post full configuration dumps or unredacted artifact debug logs.

If timeout evidence confirms the diagnosis, set a bounded read timeout suitable
for measured merge time in the existing artifact proxy location, validate with
`nginx -t`, and reload under the operator's normal change procedure. Do not
blindly disable limits or add a new location that loses authentication/TLS
settings. Changing request/response buffering does not eliminate Forgejo's
synchronous merge. No server settings were changed by this repository fix.

The new workflow bypasses this Actions path, but final Release uploads still
POST the whole file to `/api/v1/repos/{owner}/{repo}/releases/{id}/assets`.
Verify the matching proxy permits the largest complete multipart request plus
overhead, has sufficient request-buffer temporary disk (if enabled), and has
appropriate timeouts. Also check owner release-asset quotas, allowed release
file types, and attachment-backend capacity. Chunk-upload success does not prove
that a single 7 GB Release POST will pass these separate limits.

## New handoff and verification

`scripts/disk-handoff.sh` uses the same daemon as the prepare job. It stages
one volume per format, with revision/digest labels and a checksum, and verifies
those before copying into the release job. It runs no helper image code and
passes no credentials to helpers. Both matrix results must be successful before
collection/signing/publication. Existing checksum generation, pinned OpenPGP
identity, signature verification, exact six-file validation, and draft-first
Release publishing remain intact. The image build, Terra fix, Podman source
storage, BIB command, and OCI digest pinning are unchanged.

Run the static gate and small-payload integration test on a Linux machine with
Docker access (the integration test creates/removes only its own test volumes):

```bash
just validate
set -a
source bazzite-firebadnofire.env
set +a
docker pull "$BIB_IMAGE"
bash scripts/test-disk-handoff.sh
```

The test covers two legacy undated formats, a date-prefixed network ISO,
repeated staging, valid collection, wrong-daemon rejection, wrong-attempt
rejection, checksum corruption rejection, and repeated cleanup. Static success
is not a hosted Docker/Forgejo test. Local integration
was exercised with real Podman volumes/copies through a Docker-command adapter;
Docker daemon identity was simulated in that local test.

After committing the workflow, dispatch **Build and release disk artifacts**.
No OCI rebuild is needed for this handoff change. Confirm both staging steps
succeed, release collection reports two verified handoffs, all signature checks
succeed, all six assets upload before draft publication, and cleanup removes
both volumes. On a test run with one failed matrix job, confirm publication is
blocked and the successful sibling's staging volume is cleaned up.

Jobs must use the same dedicated daemon; labels are scheduling selectors, not
proof of storage locality, so the workflow checks daemon identity explicitly.
If checkout/bootstrap fails or a runner disappears, cleanup may not execute.
On the correct daemon, list `docker volume ls --filter label=handoff.scope` and
inspect each exact candidate's labels. Confirm its run is no longer active
before explicitly removing that volume; never use blanket `docker volume prune`
as a cleanup substitute. Rerun the entire workflow, not only the failed release
job, after cleanup: outputs are attempt-scoped and deliberately not reused.
