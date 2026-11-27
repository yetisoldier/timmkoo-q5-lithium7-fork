# Q5 Plex Sign-in

A small Apache-2.0 licensed WebView activity for Saga's external Plex PIN login.
It has no launcher entry, address bar or general-purpose web intent filter.
Only HTTPS Plex sign-in routes are allowed as top-level pages, including an
explicit-intent validation check. Other browsing links do not open this app.

Use Plex email/password, then tap **Done** to return to Saga. Google/Apple SSO,
arbitrary OAuth providers, downloads and general browsing are not supported.
The activity clears its own cookies/storage when closed. It never reads form
fields, injects JavaScript, bypasses TLS errors, or logs page URLs/console data.
It uses the already included WebView engine and requests only INTERNET access.

This is a restricted sign-in window, not a complete parental-control system.
Existing applications still have their own network access.

Build with `build/build_plex_signin.py`; its manifest records source hashes,
the APK checksum and the absence of a launcher/shared system UID. The URL-policy
test runs during the build. Signing keys remain outside the repository.
