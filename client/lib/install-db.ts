import { neon } from "@neondatabase/serverless";

// Neon's serverless driver over HTTPS: one statement, no connection to keep.
// DATABASE_URL is server-only (never NEXT_PUBLIC_) and set on Vercel for
// Production only, so preview deployments can't touch the count.
function sql() {
  const url = process.env.DATABASE_URL;
  if (!url) throw Object.assign(new Error("DATABASE_URL is not set"), { code: "no_database_url" });
  return neon(url, { fullResults: true });
}

/** Adds 1 to the one counter row in a single atomic statement. Takes no input. */
export async function incrementInstallCount(): Promise<void> {
  const result = await sql().query("UPDATE install_counter SET count = count + 1 WHERE id");
  // Zero rows means the migration hasn't been run on this database.
  if (result.rowCount !== 1) throw Object.assign(new Error("install_counter has no row"), { code: "no_counter_row" });
}
