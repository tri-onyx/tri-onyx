# Outlook OAuth2 IMAP Authentication

## Current Issue

The email connector uses plain LOGIN authentication over TLS for IMAP. Microsoft has deprecated basic authentication (username + password) for Office 365 / Outlook.com accounts and requires OAuth2 (XOAUTH2 SASL mechanism) instead.

App passwords — the usual workaround for basic auth deprecation — are not available for all Microsoft account types. When app passwords are unavailable, OAuth2 is the only authentication method.

### Error observed

```
IMAP poll failed: "IMAP LOGIN failed: A001 NO LOGIN failed.\r\n"
```

## What needs to change

The IMAP poller (`TriOnyx.Connectors.Email.Poller`) currently authenticates with:

```
A001 LOGIN username password
```

For Outlook, it needs to use the XOAUTH2 SASL mechanism instead:

```
A001 AUTHENTICATE XOAUTH2 <base64-encoded-token>
```

Where the base64 payload is:

```
user=<email>\x01auth=Bearer <access_token>\x01\x01
```

## Implementation requirements

### 1. Azure AD App Registration

Register an application in the Azure portal (https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationsListBlade):

- **Redirect URI**: `http://localhost` (for the initial token grant)
- **API Permissions**: `IMAP.AccessAsUser.All`, `SMTP.Send`, `offline_access`
- **Grant type**: Authorization Code flow (not client credentials — Microsoft requires delegated permissions for IMAP)

This produces a `client_id` and `client_secret`.

### 2. Initial Token Acquisition

A one-time manual step to obtain a refresh token:

1. Open the authorization URL in a browser:
   ```
   https://login.microsoftonline.com/common/oauth2/v2.0/authorize?
     client_id=<CLIENT_ID>&
     response_type=code&
     redirect_uri=http://localhost&
     scope=https://outlook.office365.com/IMAP.AccessAsUser.All
           https://outlook.office365.com/SMTP.Send
           offline_access&
     response_mode=query
   ```
2. Sign in and consent
3. Copy the `code` parameter from the redirect URL
4. Exchange the code for tokens:
   ```bash
   curl -X POST https://login.microsoftonline.com/common/oauth2/v2.0/token \
     -d "client_id=<CLIENT_ID>" \
     -d "client_secret=<CLIENT_SECRET>" \
     -d "code=<AUTH_CODE>" \
     -d "redirect_uri=http://localhost" \
     -d "grant_type=authorization_code"
   ```
5. Save the `refresh_token` from the response

### 3. Token Refresh in the Poller

The poller needs to:

- Store the refresh token (env var or file)
- Before each IMAP connection, exchange the refresh token for a fresh access token via:
  ```
  POST https://login.microsoftonline.com/common/oauth2/v2.0/token
    grant_type=refresh_token
    client_id=<CLIENT_ID>
    client_secret=<CLIENT_SECRET>
    refresh_token=<REFRESH_TOKEN>
    scope=https://outlook.office365.com/IMAP.AccessAsUser.All
          https://outlook.office365.com/SMTP.Send
          offline_access
  ```
- Use the access token in the XOAUTH2 SASL mechanism
- Handle token expiry and refresh failures gracefully

### 4. New Environment Variables

```bash
TRI_ONYX_IMAP_AUTH=oauth2              # "login" (default) or "oauth2"
TRI_ONYX_OAUTH2_CLIENT_ID=<from-azure>
TRI_ONYX_OAUTH2_CLIENT_SECRET=<from-azure>
TRI_ONYX_OAUTH2_REFRESH_TOKEN=<from-initial-grant>
TRI_ONYX_OAUTH2_TENANT=common          # or specific tenant ID
```

### 5. Files to modify

| File | Change |
|------|--------|
| `lib/tri_onyx/connectors/email.ex` | Add XOAUTH2 SASL auth path in `connect_and_fetch/2`, add token refresh HTTP call |
| `config/runtime.exs` | Read OAuth2 env vars into email config |
| `mix.exs` | May need an HTTP client dep (or use Erlang `:httpc`) for token refresh |
| `docs/email-setup.md` | Add Outlook OAuth2 setup instructions |
| `test/tri_onyx/connectors/email_test.exs` | Test XOAUTH2 auth path |

### 6. SMTP with OAuth2

The same access token works for SMTP via the XOAUTH2 mechanism. The `deliver_smtp/2` function would need a similar auth mode switch — `gen_smtp` supports XOAUTH2 via the `auth` option.

## Workaround (current)

Use an email provider that supports standard IMAP LOGIN authentication:
- **Gmail** with app passwords (enable 2FA first)
- **Fastmail** with app passwords
- **Self-hosted** Dovecot/Postfix with password auth
