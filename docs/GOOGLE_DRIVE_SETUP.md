# Upload from Google Drive — one-time setup

Prepared by Shantanu Suravase · 18-Nov-2026 · wave 112

The upload page (Admin → Uploads) has a **Pick from Google Drive** card with one button per report folder:

| Button | Folder |
|---|---|
| Zonal Tracker | the owner's Zonal Tracker folder |
| Point wise | the owner's Point Wise folder |
| Case wise | the owner's Case Wise folder |

The folder IDs are kept in the database (`bi.app_setting`, key `google_drive`) and shown to admins only — never in this public
repository, because a Drive folder ID works like a link.

A button opens Google's own file picker on that folder. The admin ticks one or more files and presses **Select**. The files are downloaded
in the admin's browser with the admin's own Google access and go through exactly the same steps as a dropped file: file type detected,
personal data removed in the browser, preview and checks, and nothing is written until **Import validated files** is pressed. Manual
upload (drag and drop) keeps working as before.

## What the dashboard needs from Google (about 15 minutes, once)

Do this with the Google account that owns or can see the three folders (a Google Workspace admin account is best).

1. **Project** — open <https://console.cloud.google.com/>, create a project (for example "Crux BI") or pick an existing one.
2. **APIs** — APIs & Services → Library → enable **Google Drive API** and **Google Picker API**.
3. **Consent screen** — APIs & Services → OAuth consent screen (Google Auth Platform → Branding / Audience):
   - App name "Crux BI", support e-mail, developer contact e-mail.
   - Audience: **Internal** if everyone who uploads uses the company Google Workspace domain. If uploaders use personal Gmail
     accounts, choose **External** and add each uploader under *Test users* (or publish the app).
   - Data access / scopes: add `https://www.googleapis.com/auth/drive.file` (access only to the files a person picks).
4. **OAuth client ID** — APIs & Services → Credentials → Create credentials → OAuth client ID → Application type **Web application**.
   Authorised JavaScript origins: `https://cruxindia.github.io` (no path, no trailing slash). No redirect URI is needed. Copy the
   **Client ID** (it ends with `.apps.googleusercontent.com`).
5. **Browser API key** — Credentials → Create credentials → API key → Edit:
   - Application restrictions: **Websites** → `https://cruxindia.github.io/*`
   - API restrictions: **Restrict key** → Google Picker API (and Google Drive API).
   Copy the key (it starts with `AIza`). The restriction means the key only works from the dashboard's own address.
6. **Project number** — Cloud console → the project menu → Project settings → **Project number** (digits only).
7. **Dashboard** — Admin login → Admin workspace → Uploads → *Pick from Google Drive* → **Set up Drive access** → paste the client
   ID, the API key and the project number → **Save Drive settings**. The three folder IDs are already filled in; change them here if
   the folders move.

## First use

Press a folder button. Google asks the admin to sign in and to allow "Crux BI" to see the files they pick (once per browser session).
Allow pop-ups for the dashboard page if the browser blocks the sign-in window. Then tick the files and press **Select**.

## Notes and limits

- Each person who picks files must be able to open the folder in Google Drive (shared with them, or in a shared drive they belong to).
- Native Google Sheets are exported to .xlsx before reading; uploaded .xlsx / .xls files are read as they are.
- The settings are stored in the database (`bi.app_setting`, key `google_drive`) and shown to admins only; the audit log records that
  a value was set, never the value. Changing a setting: same form. Removing access: delete the OAuth client or API key in Google Cloud.
- Nothing runs on a schedule: files are read only when an admin picks them. An automatic nightly pick-up from the folders would need a
  server-side Google service account with read access to the folders; ask if you want that as a next step.
