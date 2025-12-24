# Substack Reader Plugin for KOReader

Coded with an LLM, but using best software practices as far as possible.

## Setup

This plugin requires a Substack session cookie to fetch your inbox and saved posts.

### 1. Fetching the Cookie

1. Log in to [substack.com](https://substack.com) in your web browser.
2. Open Developer Tools (F12 or Right-click > Inspect).
3. Go to the **Application** tab (Chrome/Edge) or **Storage** tab (Firefox).
4. In the left sidebar, expand **Cookies** and select `https://substack.com`.
5. Look for a cookie named `substack.sid`.
6. Copy the **Value** of this cookie (it will be a long string of characters). It must be the URL decoded version.

### 2. Configuring the Plugin

1. Create a file named `substack_cookie.txt`.
2. Paste the `substack.sid` value into this file.
3. Place `substack_cookie.txt` in the following location on your e-reader:
   - `koreader/settings/substack_cookie.txt`

### 3. Usage

Once the cookie is in place, you can access "Recent Posts", "Saved Posts", and your "Subscriptions" from the Substack Reader menu in KOReader.