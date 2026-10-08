# Install counter

The only thing talkflow reports about itself: the first time a fresh install
launches, the app sends one empty request, and the site adds 1 to a single
number in a database. That number is the install count.

## What is counted, and what is not

Counted: one total, `count`, in the one row of the `install_counter` table.

Not sent, and not stored:

- no ID of any kind (no install ID, user ID, UUID or device ID);
- no app version, OS, architecture, language or settings;
- no usage, audio, text or stats;
- no IP address, user agent or other headers, and no timestamp per install.

The request is a `POST` with no body and no headers of the app's own. The
operating system's HTTP stack adds its usual ones (on macOS, a default
`User-Agent` and `Accept-Language`); the route never reads them, and they reach
only Vercel's ordinary request logs, as any visit to the website does (see the
privacy policy).

Source builds, contributor builds and CI builds send nothing: the URL is baked
in only by the release build, and without it the app makes no request at all.
The app also never sends from a self-test mode or when `CI` is set.

## How it works

| Piece | Where |
| --- | --- |
| Route: `POST /api/install`, 204 with no body; every other method 405 | `client/app/api/install/route.ts` |
| Request handling, body refusal, rate limit (no DB) | `client/lib/install-counter.ts` |
| The one SQL statement | `client/lib/install-db.ts` |
| Tests (`npm test` in `client/`) | `client/lib/install-counter.test.mts` |
| Table | `client/db/migrations/0001_install_counter.sql` |

The route runs exactly one statement, which takes no input from the request:

```sql
UPDATE install_counter SET count = count + 1 WHERE id
```

Each app keeps a local `installCounted` flag (macOS: `UserDefaults`; Windows:
`windows.json`) and sets it only after a 2xx answer, so a failure or timeout is
retried quietly on the next launch. The flag is not part of the settings backup,
so it never moves to another machine.

## Environment variables

Names only; values never go in git.

| Name | Where | What |
| --- | --- | --- |
| `DATABASE_URL` | Vercel, **Production only** | Neon connection string the route writes with. Server-only: never `NEXT_PUBLIC_`. Not set on Preview, so test deployments can't touch the real count (the route answers 500 there). |
| `TALKFLOW_TELEMETRY_URL` | the release machine, when running `release.sh` | The full URL of the route, e.g. `https://<site>/api/install`. Baked into the release `.app` only. Unset: the build succeeds and never sends. |
| `TALKFLOW_TELEMETRY_URL` | GitHub Actions secret (Windows workflow) | Passed to the Windows installer build on published releases only. |
| `TALKFLOW_STATS_DB_URL` | the owner's shell only | Read-only connection string used to view the count. Never in a file in this repo. |

## The table (migration)

`neon.ts` declares Neon services and branch policy; it has no SQL migrations,
so `neon deploy` does not create the table. Run the migration once per database.
It is idempotent and never drops, deletes or resets anything:

```sql
CREATE TABLE IF NOT EXISTS install_counter (
  id    boolean PRIMARY KEY DEFAULT true CONSTRAINT install_counter_single_row CHECK (id),
  count bigint  NOT NULL DEFAULT 0
);
INSERT INTO install_counter (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
```

The boolean primary key that must be `true` means the table can only ever hold
one row.

Ways to run it: paste the file into the Neon console's SQL Editor (branch
`production`, database `neondb`), or with `psql` installed,
`psql "$(neon connection-string production --role-name neondb_owner)" -f client/db/migrations/0001_install_counter.sql`.
To try it first, run it on a throwaway branch:
`neon branches create --name try-counter --parent production --expires-at <RFC 3339 time>`.

## Least-privilege roles

Run these yourself in the Neon SQL Editor, after the migration, with a long
random password of your own in place of `<password>`. Create these roles with
SQL, not in the console or with `neon roles create`: roles made there join
`neon_superuser`, which is far more than either needs.

**Viewer** (for `TALKFLOW_STATS_DB_URL`): can read the count and nothing else.

```sql
CREATE ROLE talkflow_stats WITH LOGIN PASSWORD '<password>';
GRANT CONNECT ON DATABASE neondb TO talkflow_stats;
GRANT USAGE ON SCHEMA public TO talkflow_stats;
GRANT SELECT ON install_counter TO talkflow_stats;
ALTER ROLE talkflow_stats SET default_transaction_read_only = on;
```

**Writer** (optional, for the site's `DATABASE_URL` instead of the owner role):
can add to the count and nothing else; it can't delete the row, change `id`,
insert or create tables.

```sql
CREATE ROLE talkflow_counter WITH LOGIN PASSWORD '<password>';
GRANT CONNECT ON DATABASE neondb TO talkflow_counter;
GRANT USAGE ON SCHEMA public TO talkflow_counter;
GRANT SELECT, UPDATE (count) ON install_counter TO talkflow_counter;
```

Build the connection string from the owner's one in the console (Connect),
swapping in the role name and password. Use the pooled host (`-pooler`) for the
site.

## Abuse limits

The counter is anonymous, so anyone who finds the URL can add to it. The limits
keep that cheap and bounded; they store nothing about anyone.

- **Body:** a request that declares a body (`Content-Length` above 0) or streams
  one (`Transfer-Encoding`) is refused with 413 before anything else. These two
  headers are the only ones the route looks at, and the body is never read.
- **Per instance:** each server instance accepts at most 30 increments a minute
  and answers 429 after that. It is one number per instance, not per client. A
  refused app just tries again on its next launch.
- **Per IP (Vercel WAF):** in code this would mean holding IP addresses, so it
  is a firewall rule instead. In the Vercel dashboard, Project > Firewall >
  Configure > New Rule:
  - If: Request Path equals `/api/install`, and Method equals `POST`
  - Then: Rate Limit, fixed window, 60 seconds, 5 requests, keyed on IP
    Address, action Too Many Requests (429)

  Vercel's counters are per region. Start it with the action set to Log for a
  few days, then switch to 429. Or with the CLI (conditions given together are
  AND'd; change `log` to `rate_limit` once it looks right):

  ```bash
  vercel firewall rules add "Install counter" \
    --condition '{"type":"path","op":"eq","value":"/api/install"}' \
    --condition '{"type":"method","op":"eq","value":"POST"}' \
    --action rate_limit --rate-limit-window 60 --rate-limit-requests 5 \
    --rate-limit-keys ip --rate-limit-action log
  ```

The count is therefore an upper bound on real installs, not an exact number.
