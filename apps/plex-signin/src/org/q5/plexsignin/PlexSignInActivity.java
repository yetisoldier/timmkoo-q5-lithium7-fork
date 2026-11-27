// SPDX-License-Identifier: Apache-2.0
package org.q5.plexsignin;

import android.app.Activity;
import android.graphics.Color;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Bundle;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.SslErrorHandler;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebStorage;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import java.io.ByteArrayInputStream;

/** No launcher, address bar, JS bridge, downloads, or credential interception. */
public final class PlexSignInActivity extends Activity {
    private WebView browser;
    private TextView notice;
    private ProgressBar progress;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Uri supplied = getIntent().getData();
        final String initial = supplied == null ? null : supplied.toString();
        if (!AllowedUrl.permits(initial)) { finish(); return; }

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.WHITE);
        LinearLayout header = new LinearLayout(this);
        header.setPadding(dp(12), dp(4), dp(8), dp(4));
        TextView title = new TextView(this);
        title.setText("Plex sign-in");
        title.setTextSize(19);
        title.setTextColor(Color.BLACK);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        Button close = new Button(this);
        close.setText("Done");
        close.setOnClickListener(view -> finish());
        header.addView(close, new LinearLayout.LayoutParams(-2, -2));
        root.addView(header);
        notice = new TextView(this);
        notice.setText("Use your Plex email and password, then tap Done.");
        notice.setTextColor(Color.DKGRAY);
        notice.setPadding(dp(12), 0, dp(12), dp(8));
        root.addView(notice);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        root.addView(progress, new LinearLayout.LayoutParams(-1, dp(3)));
        browser = new WebView(this);
        root.addView(browser, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(root);

        WebView.setWebContentsDebuggingEnabled(false);
        WebSettings settings = browser.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSaveFormData(false);
        settings.setSupportMultipleWindows(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        browser.setWebChromeClient(new WebChromeClient() {
            @Override public void onProgressChanged(WebView view, int value) {
                progress.setProgress(value);
                progress.setVisibility(value == 100 ? android.view.View.GONE : android.view.View.VISIBLE);
            }
            @Override public boolean onConsoleMessage(ConsoleMessage message) {
                return true; // Do not write page URLs/PINs or form details to logcat.
            }
        });
        browser.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return blockNavigation(url);
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if (!request.isForMainFrame()) return !"https".equalsIgnoreCase(request.getUrl().getScheme());
                return blockNavigation(request.getUrl().toString());
            }
            @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                String url = request.getUrl().toString();
                if ((request.isForMainFrame() && !AllowedUrl.permits(url))
                        || "http".equalsIgnoreCase(request.getUrl().getScheme())) {
                    return new WebResourceResponse("text/plain", "UTF-8", new ByteArrayInputStream(new byte[0]));
                }
                return null;
            }
            @Override public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
                handler.cancel();
                notice.setText("Secure connection failed. Check the device date and Wi-Fi.");
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) notice.setText("Unable to load sign-in. Check Wi-Fi and try again.");
            }
        });
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(browser, true);
        cookies.removeAllCookies(removed -> {
            if (!isFinishing()) browser.loadUrl(initial);
        });
    }

    private boolean blockNavigation(String url) {
        if (AllowedUrl.permits(url)) return false;
        notice.setText("This window only opens Plex sign-in pages.");
        return true;
    }

    private int dp(int value) {
        return (int) (getResources().getDisplayMetrics().density * value + 0.5f);
    }

    @Override public void onBackPressed() { finish(); }

    @Override protected void onStop() {
        super.onStop();
        if (!isChangingConfigurations()) finish();
    }

    @Override protected void onDestroy() {
        if (browser != null) {
            browser.stopLoading();
            browser.clearHistory();
            browser.clearFormData();
            browser.clearCache(true);
            CookieManager.getInstance().removeAllCookies(null);
            CookieManager.getInstance().flush();
            WebStorage.getInstance().deleteAllData();
            browser.destroy();
            browser = null;
        }
        super.onDestroy();
    }
}
