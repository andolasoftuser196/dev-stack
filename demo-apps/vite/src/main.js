// This app has no backend of its own: services.database is `none` in the
// matching example, and dx starts no database container at all. What it can
// still prove is that the runtime, the proxy and HMR all work.
//
// The status lines are already in index.html so that curl and the integration
// test see them. This only replaces the two values a browser knows better.
const el = document.getElementById('out');
el.textContent = el.textContent
  .replace('version=dev', `version=${import.meta.env.MODE}`)
  .replace('instance=main', `instance=${import.meta.env.VITE_DX_INSTANCE ?? 'main'}`);
