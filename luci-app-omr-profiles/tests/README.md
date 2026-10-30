# Profile UI fixture

Run `node luci-app-omr-profiles/tests/test_profiles_ui.js` from the feed root.
The fixture executes the actual LuCI module with a lightweight DOM and mock RPC.
It checks the read-only state, text escaping, application and confirmation,
rollback-failure recovery, visible API errors, separate router/VPS settings,
remote divergence, a polling race and saving current settings.
The deterministic animation fixture advances a shared frame clock, checks
AB → CD → AB, lane identities AC/BD, identical redundant copies, spacing,
single-path A → B → C → D, No tunnel TCP via VPS and UDP/ICMP via master to Internet,
preset reset, polling continuity, pause and removal cleanup. Browser acceptance
also samples real frames at desktop and 320px widths, including icon alignment,
collision bounds, reduced motion and no profile mutation from preview controls.
It is not a browser, OpenWrt, ACL installation or end-to-end network test.

Run `node luci-app-omr-profiles/tests/preview.js` to open a localhost-only
browser preview of the actual widget and CSS. The banner identifies the fake
service; changes apply only to in-memory preview data and never contact a router.
