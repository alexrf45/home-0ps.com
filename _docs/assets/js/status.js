// Live reachability checks for the Status page.
// Runs in the viewer's browser, so it reflects whether *you* can reach each
// service (works from the LAN where dev.int.* resolves). No backend needed.
(function () {
  const SERVICES = [
    { id: "authentik", url: "https://dev.int.auth.home-0ps.com/" },
    { id: "grafana", url: "https://dev.int.grafana.home-0ps.com/" },
    { id: "freshrss", url: "https://dev.int.freshrss.home-0ps.com/" },
    { id: "homer", url: "https://dev.int.homer.home-0ps.com/" },
    { id: "docs", url: "https://dev.int.docs.home-0ps.com/" },
  ];

  async function probe(svc) {
    const el = document.getElementById("status-" + svc.id);
    if (!el) return;
    el.textContent = "⏳ checking…";
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 6000);
    try {
      // no-cors: we can't read the response, but the request resolving means
      // the host answered; a network/DNS failure or timeout rejects.
      await fetch(svc.url, { mode: "no-cors", cache: "no-store", signal: ctrl.signal });
      el.textContent = "🟢 reachable";
    } catch (e) {
      el.textContent = "🔴 unreachable";
    } finally {
      clearTimeout(timer);
    }
  }

  function runAll() {
    if (!document.getElementById("status-authentik")) return; // not the status page
    SERVICES.forEach(probe);
  }

  // Plain load + Material instant-navigation (document$) if present.
  document.addEventListener("DOMContentLoaded", runAll);
  if (typeof window.document$ !== "undefined") {
    window.document$.subscribe(runAll);
  }
})();
