# Profile UI fixture

Run `node luci-app-omr-profiles/tests/test_profiles_ui.js` from the feed root.
The fixture executes the actual LuCI module with a lightweight DOM and mock RPC.
It checks the read-only state, text escaping, application and confirmation,
rollback-failure recovery, visible API errors, separate router/VPS settings,
remote divergence, a polling race and saving current settings.
It is not a browser, OpenWrt, ACL installation or end-to-end network test.

Run `node luci-app-omr-profiles/tests/preview.js` to open a localhost-only
browser preview of the actual widget and CSS. The banner identifies the fake
service; changes apply only to in-memory preview data and never contact a router.
