// SPDX-License-Identifier: Apache-2.0
import org.q5.plexsignin.AllowedUrl;
public final class AllowedUrlTest {
    public static void main(String[] args) {
        String[] allowed = {"https://app.plex.tv/auth/#!?clientID=test&code=test",
            "https://plex.tv/link", "https://www.plex.tv/sign-in/", "https://plex.tv/users/sign_in",
            "HTTPS://APP.PLEX.TV:443/auth"};
        String[] blocked = {null, "https://example.com", "http://app.plex.tv/auth/",
            "https://app.plex.tv/desktop/", "https://plex.tv/", "https://plex.tv.evil.test/link",
            "https://plex.tv@evil.test/link", "https://user@plex.tv/link", "https://plex.tv:444/link",
            "https://app.plex.tv/auth/../desktop", "https://app.plex.tv/auth/%2e%2e/desktop",
            "https://app.plex.tv/auth/%252e%252e/desktop", "https://app.plex.tv/authentic",
            "file:///data/test", "javascript:alert(1)", "intent://plex.tv/link", "https://plex.tv./link"};
        for(String u:allowed) if(!AllowedUrl.permits(u)) throw new AssertionError("Expected allowed URL");
        for(String u:blocked) if(AllowedUrl.permits(u)) throw new AssertionError("Expected blocked URL");
        System.out.println("PASS: Plex-only HTTPS navigation, exact hosts/routes, traversal and scheme rejection");
    }
}
