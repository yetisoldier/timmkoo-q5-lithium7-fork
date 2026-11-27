// SPDX-License-Identifier: Apache-2.0
package org.q5.plexsignin;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;

/** Navigation policy for a sign-in window, not a general web browser. */
public final class AllowedUrl {
    private AllowedUrl() { }

    public static boolean permits(String value) {
        if (value == null) return false;
        try {
            URI uri = new URI(value);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getRawUserInfo() != null
                    || (uri.getPort() != -1 && uri.getPort() != 443)) return false;
            String host = uri.getHost();
            if (host == null) return false;
            host = host.toLowerCase(Locale.US);
            String path = uri.getRawPath();
            if (path == null || path.length() == 0) path = "/";
            // Authentication routes need no encoded path segments. Reject
            // ambiguous traversal before the browser/server normalizes them.
            if (path.indexOf('%') >= 0 || path.indexOf('\\') >= 0) return false;
            for (String segment : path.split("/", -1)) {
                if (".".equals(segment) || "..".equals(segment)) return false;
            }
            if ("app.plex.tv".equals(host)) return route(path, "/auth");
            if (!"plex.tv".equals(host) && !"www.plex.tv".equals(host)
                    && !"auth.plex.tv".equals(host)) return false;
            for (String prefix : new String[]{"/auth", "/link", "/sign-in", "/signin",
                    "/users/sign_in", "/users/sign_up", "/users/password",
                    "/users/reset_password", "/users/confirmation", "/oauth"}) {
                if (route(path, prefix)) return true;
            }
            return false;
        } catch (URISyntaxException exception) {
            return false;
        }
    }

    private static boolean route(String path, String prefix) {
        return path.equals(prefix) || path.startsWith(prefix + "/");
    }
}
