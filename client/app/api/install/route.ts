import { createInstallRoute } from "@/lib/install-counter";
import { incrementInstallCount } from "@/lib/install-db";

// POST /api/install: the app's one-time "a fresh install launched" ping. Adds 1
// to the install count and answers 204 with no body. Every other method is 405.
// What is and isn't counted: docs/telemetry.md.
const route = createInstallRoute(incrementInstallCount);

export const { POST, GET, HEAD, PUT, PATCH, DELETE, OPTIONS } = route;
