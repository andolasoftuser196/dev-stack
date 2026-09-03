import { status } from '../status.js';

// Server component, and force-dynamic: the whole point is to probe on every
// request. A cached status page would report a database that went away twenty
// minutes ago as healthy.
export const dynamic = 'force-dynamic';

export default async function Page() {
  return <main>{await status('next')}</main>;
}
