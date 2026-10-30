# Resilient VPS API checks

Run in Linux/WSL from the feed root:

```sh
python3 -m unittest discover -s openmptcprouter/tests -v
```

The suite currently contains 22 cases:

- 18 source/fixture cases: real shared shell helper and init/tracker functions,
  Bash and Dash, separate mock-curl processes, actual concurrent selection and
  cancellation. Covers default/backup/subflow/signal candidates, stale paths,
  a winner published during the completion scan, IPv6 URL/interface handling,
  auth rejection/refresh, invalid/error responses, one mutation rather than
  fan-out, and no replay across VPS IPs after an uncertain result.
- Four real curl/HTTPS tests against a temporary 127.0.0.1 listener and an
  ephemeral certificate: single POST, form encoding, permission denial, and a
  response lost after the server received the mutation. The last test takes
  approximately ten seconds to trigger the actual curl timeout.

JSONfilter is a Python fixture in both suites; the deployed OpenWrt binary is
not executed. Dash is a portability check, not a BusyBox ash execution claim.
The packaging case checks the explicit dependency/install declarations. It does
not replace APK dependency resolution or partial-upgrade tests on a built image.
Tests use disposable files and localhost only; they do not invoke real UCI,
change interfaces, restart services or contact a customer VPS/router.

The production helper is supplied by the new `omr-api-paths` package, which both
`openmptcprouter` and `omr-tracker` depend on. This makes the shared file an
explicit package dependency, including when either consumer is updated alone.

Only the existing, unauthenticated VPS homepage is probed in parallel. The actual
administration request is serialized through the winning path. GET `/config`
must not be treated as pure/read-only: the paired VPS can create OpenVPN material
and update stored parameters in that handler.

Requests use HTTP status plus JSON parsing. Authentication rejection is distinct
from authorization denial. A failure before delivery can try another path;
timeout or invalid reply after possible delivery yields an explicit uncertain
result. Caller IP loops must preserve that result, reconcile remote state and
avoid automatically repeating the operation. This is a bounded client retry
policy, not a server-side exactly-once/idempotency guarantee.
