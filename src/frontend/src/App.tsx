import { useEffect, useState } from 'react'

interface Product {
  id: string
  name: string
  price: number
}

type View = 'catalog' | 'basket'

export default function App() {
  const [catalog, setCatalog] = useState<Product[]>([])
  const [basket, setBasket] = useState<Record<string, number>>({})
  const [view, setView] = useState<View>('catalog')

  // Fetch catalog (and trigger the backend memory leak) on every navigation.
  useEffect(() => {
    fetch('/api/catalog')
      .then((r) => r.json())
      .then(setCatalog)
      .catch(console.error)
  }, [view])

  const addToBasket = (id: string) =>
    setBasket((b) => ({ ...b, [id]: (b[id] ?? 0) + 1 }))

  const basketItems = catalog
    .filter((p) => basket[p.id])
    .map((p) => ({ ...p, quantity: basket[p.id] }))

  const total = basketItems.reduce((s, i) => s + i.price * i.quantity, 0)
  const basketCount = Object.values(basket).reduce((s, v) => s + v, 0)

  return (
    <div style={{ fontFamily: 'sans-serif', maxWidth: 640, margin: '2rem auto', padding: '0 1rem' }}>
      <h1>Zava pet products</h1>
      <nav style={{ marginBottom: '1rem' }}>
        <button onClick={() => setView('catalog')} disabled={view === 'catalog'}>
          Catalog
        </button>{' '}
        <button onClick={() => setView('basket')} disabled={view === 'basket'}>
          Basket ({basketCount})
        </button>
      </nav>

      {view === 'catalog' && (
        <>
          <h2>Catalog</h2>
          <ul>
            {catalog.map((p) => (
              <li key={p.id} style={{ marginBottom: '0.5rem' }}>
                {p.name} – €{p.price.toFixed(2)}{' '}
                <button onClick={() => addToBasket(p.id)}>Add to basket</button>
              </li>
            ))}
          </ul>
        </>
      )}

      {view === 'basket' && (
        <>
          <h2>Your basket</h2>
          {basketItems.length === 0 ? (
            <p>Your basket is empty.</p>
          ) : (
            <>
              <ul>
                {basketItems.map((i) => (
                  <li key={i.id}>
                    {i.name} × {i.quantity} = €{(i.price * i.quantity).toFixed(2)}
                  </li>
                ))}
              </ul>
              <p>
                <strong>Total: €{total.toFixed(2)}</strong>
              </p>
            </>
          )}
        </>
      )}
    </div>
  )
}
