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

export default function App() {
  const [catalog, setCatalog] = useState<Product[]>([]);
  const [basket, setBasket] = useState<Record<string, number>>({});
  const [view, setView] = useState<View>("catalog");
  const [category, setCategory] = useState<string>("All");
  const [loading, setLoading] = useState(true);
  const [detail, setDetail] = useState<Product | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);

  // Fetch the catalog once on load.
  useEffect(() => {
    setLoading(true);
    fetch("/api/catalog")
      .then((r) => r.json())
      .then((data: Product[]) => setCatalog(data))
      .catch(console.error)
      .finally(() => setLoading(false));
  }, []);

  // Opening a product hits the slow backend endpoint (the SRE demo bug):
  // the more products you open, the longer this takes to respond.
  const openProduct = (id: string) => {
    setDetail(null);
    setDetailLoading(true);
    setView("product");
    fetch(`/api/catalog/${id}`)
      .then((r) => r.json())
      .then((data: Product) => setDetail(data))
      .catch(console.error)
      .finally(() => setDetailLoading(false));
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

  return (
    <div className="app">
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
                <p className="muted">
                  This can take a while when the store is busy.
                </p>
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
