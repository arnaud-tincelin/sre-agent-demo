import { useEffect, useMemo, useState } from "react";
import "./App.css";

interface Product {
  id: string;
  name: string;
  price: number;
  category: string;
  description: string;
  emoji: string;
}

type View = "catalog" | "product" | "basket";

interface HealthPayload {
  status: string;
  productCount: number;
  revision: string;
  reason: string | null;
}

type HealthState =
  | { kind: "unknown" }
  | { kind: "up"; productCount: number; revision: string; latencyMs: number }
  | { kind: "down"; httpStatus: number | null; reason: string };

interface RequestFailure {
  path: string;
  status: number | null;
}

const HEALTH_POLL_MS = 5000;

// The banner is the demo's scoreboard: a total outage (health probe failing) outranks
// individual request failures, which in turn outrank the healthy state.
function describeStatus(health: HealthState, failure: RequestFailure | null) {
  if (health.kind === "down") {
    return {
      tone: "down",
      label: "SERVICE DISRUPTION",
      detail: health.httpStatus
        ? `HTTP ${health.httpStatus} · ${health.reason}`
        : health.reason,
    };
  }
  if (failure) {
    return {
      tone: "degraded",
      label: "DEGRADED",
      detail: failure.status
        ? `HTTP ${failure.status} on ${failure.path}`
        : `Request to ${failure.path} failed`,
    };
  }
  if (health.kind === "up") {
    return {
      tone: "up",
      label: "ALL SYSTEMS OPERATIONAL",
      detail: `${health.productCount} products · ${health.latencyMs} ms · revision ${health.revision}`,
    };
  }
  return {
    tone: "unknown",
    label: "CHECKING STATUS",
    detail: "Contacting the Zava backend…",
  };
}

export default function App() {
  const [catalog, setCatalog] = useState<Product[]>([]);
  const [basket, setBasket] = useState<Record<string, number>>({});
  const [view, setView] = useState<View>("catalog");
  const [category, setCategory] = useState<string>("All");
  const [loading, setLoading] = useState(true);
  const [detail, setDetail] = useState<Product | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [health, setHealth] = useState<HealthState>({ kind: "unknown" });
  const [failure, setFailure] = useState<RequestFailure | null>(null);

  // Poll the backend health endpoint so the banner reflects the live state of the
  // service, not just the last thing the shopper clicked.
  useEffect(() => {
    let cancelled = false;

    const probe = async () => {
      const started = performance.now();
      try {
        const res = await fetch("/api/health");
        const latencyMs = Math.round(performance.now() - started);
        const body = (await res.json().catch(() => null)) as HealthPayload | null;
        if (cancelled) return;

        if (res.ok && body?.status === "healthy") {
          setHealth({
            kind: "up",
            productCount: body.productCount,
            revision: body.revision,
            latencyMs,
          });
        } else {
          setHealth({
            kind: "down",
            httpStatus: res.status,
            reason: body?.reason ?? `Backend returned HTTP ${res.status}.`,
          });
        }
      } catch {
        if (!cancelled) {
          setHealth({ kind: "down", httpStatus: null, reason: "Backend unreachable." });
        }
      }
    };

    probe();
    const timer = window.setInterval(probe, HEALTH_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  // Fetch the catalog once on load.
  useEffect(() => {
    let cancelled = false;

    (async () => {
      setLoading(true);
      try {
        const res = await fetch("/api/catalog");
        if (cancelled) return;
        if (!res.ok) {
          setFailure({ path: "/api/catalog", status: res.status });
          return;
        }
        setCatalog((await res.json()) as Product[]);
        setFailure(null);
      } catch {
        if (!cancelled) setFailure({ path: "/api/catalog", status: null });
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  const openProduct = async (id: string) => {
    const path = `/api/catalog/${id}`;
    setDetail(null);
    setDetailLoading(true);
    setView("product");
    try {
      const res = await fetch(path);
      if (!res.ok) {
        setFailure({ path, status: res.status });
        return;
      }
      setDetail((await res.json()) as Product);
      setFailure(null);
    } catch {
      setFailure({ path, status: null });
    } finally {
      setDetailLoading(false);
    }
  };

  const addToBasket = (id: string) =>
    setBasket((b) => ({ ...b, [id]: (b[id] ?? 0) + 1 }));

  const removeFromBasket = (id: string) =>
    setBasket((b) => {
      const next = { ...b };
      if ((next[id] ?? 0) <= 1) delete next[id];
      else next[id] = next[id] - 1;
      return next;
    });

  const categories = useMemo(
    () => ["All", ...Array.from(new Set(catalog.map((p) => p.category)))],
    [catalog],
  );

  const visibleCatalog =
    category === "All"
      ? catalog
      : catalog.filter((p) => p.category === category);

  const basketItems = catalog
    .filter((p) => basket[p.id])
    .map((p) => ({ ...p, quantity: basket[p.id] }));

  const total = basketItems.reduce((s, i) => s + i.price * i.quantity, 0);
  const basketCount = Object.values(basket).reduce((s, v) => s + v, 0);
  const status = describeStatus(health, failure);

  return (
    <div className="app">
      <div className="topbar">
        <div className={`status-bar status-${status.tone}`}>
          <span className="status-dot" />
          <strong className="status-label">{status.label}</strong>
          <span className="status-detail">{status.detail}</span>
          {(status.tone === "down" || status.tone === "degraded") && (
            <span className="status-hint">SRE Agent investigating</span>
          )}
        </div>

        <header className="header">
          <div className="brand">
            <span className="brand-logo">🐾</span>
            <div>
              <h1>Zava Pet Store</h1>
              <p className="tagline">Everything your best friend needs</p>
            </div>
          </div>
          <nav className="nav">
            <button
              className={view === "catalog" ? "nav-btn active" : "nav-btn"}
              onClick={() => setView("catalog")}
            >
              Shop
            </button>
            <button
              className={view === "basket" ? "nav-btn active" : "nav-btn"}
              onClick={() => setView("basket")}
            >
              🛒 Basket
              {basketCount > 0 && <span className="badge">{basketCount}</span>}
            </button>
          </nav>
        </header>
      </div>

      <main className="main">
        {view === "catalog" && (
          <>
            <div className="filters">
              {categories.map((c) => (
                <button
                  key={c}
                  className={category === c ? "chip active" : "chip"}
                  onClick={() => setCategory(c)}
                >
                  {c}
                </button>
              ))}
            </div>

            {loading ? (
              <p className="muted">Loading products…</p>
            ) : (
              <div className="grid">
                {visibleCatalog.map((p) => (
                  <article
                    key={p.id}
                    className="card"
                    onClick={() => openProduct(p.id)}
                  >
                    <div className="card-image">{p.emoji}</div>
                    <div className="card-body">
                      <span className="card-category">{p.category}</span>
                      <h3 className="card-title">{p.name}</h3>
                      <p className="card-desc">{p.description}</p>
                      <div className="card-footer">
                        <span className="price">€{p.price.toFixed(2)}</span>
                        <button
                          className="add-btn"
                          onClick={(e) => {
                            e.stopPropagation();
                            addToBasket(p.id);
                          }}
                        >
                          Add
                        </button>
                      </div>
                    </div>
                  </article>
                ))}
              </div>
            )}
          </>
        )}

        {view === "product" && (
          <section className="detail">
            <button className="back-btn" onClick={() => setView("catalog")}>
              ← Back to shop
            </button>
            {detailLoading ? (
              <div className="detail-loading">
                <span className="spinner" />
                <p>Loading product…</p>
              </div>
            ) : detail ? (
              <div className="detail-card">
                <div className="detail-image">{detail.emoji}</div>
                <div className="detail-body">
                  <span className="card-category">{detail.category}</span>
                  <h2>{detail.name}</h2>
                  <p className="detail-desc">{detail.description}</p>
                  <div className="detail-footer">
                    <span className="price">€{detail.price.toFixed(2)}</span>
                    <button
                      className="add-btn"
                      onClick={() => addToBasket(detail.id)}
                    >
                      Add to basket
                    </button>
                  </div>
                </div>
              </div>
            ) : (
              <p className="muted">Sorry, this product could not be loaded.</p>
            )}
          </section>
        )}

        {view === "basket" && (
          <section className="basket">
            <h2>Your basket</h2>
            {basketItems.length === 0 ? (
              <div className="empty">
                <span className="empty-emoji">🛒</span>
                <p>Your basket is empty.</p>
                <button className="add-btn" onClick={() => setView("catalog")}>
                  Start shopping
                </button>
              </div>
            ) : (
              <>
                <ul className="basket-list">
                  {basketItems.map((i) => (
                    <li key={i.id} className="basket-row">
                      <span className="basket-emoji">{i.emoji}</span>
                      <div className="basket-info">
                        <strong>{i.name}</strong>
                        <span className="muted">
                          €{i.price.toFixed(2)} each
                        </span>
                      </div>
                      <div className="qty">
                        <button onClick={() => removeFromBasket(i.id)}>
                          −
                        </button>
                        <span>{i.quantity}</span>
                        <button onClick={() => addToBasket(i.id)}>+</button>
                      </div>
                      <span className="line-total">
                        €{(i.price * i.quantity).toFixed(2)}
                      </span>
                    </li>
                  ))}
                </ul>
                <div className="basket-summary">
                  <span>Total</span>
                  <strong>€{total.toFixed(2)}</strong>
                </div>
                <button className="checkout-btn">Checkout</button>
              </>
            )}
          </section>
        )}
      </main>

      <footer className="footer">
        <span>© {new Date().getFullYear()} Zava Pet Store</span>
      </footer>
    </div>
  );
}
