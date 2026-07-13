from __future__ import annotations

from flask import Flask, redirect, render_template_string, request, session, url_for

app = Flask(__name__)
app.secret_key = "zava-demo-secret"

CATALOG = [
    {"id": "1", "name": "Dog food", "price": 29.99},
    {"id": "2", "name": "Cat litter", "price": 15.5},
    {"id": "3", "name": "Bird toy", "price": 8.75},
]

LEAK_BUCKET: list[str] = []


# Intentional bug for the SRE demo: called while users navigate the site.
def AVeryMemoryIntensiveFunction() -> int:
    LEAK_BUCKET.append("X" * 10_000_000)
    return len(LEAK_BUCKET)


@app.before_request
def trigger_bug() -> None:
    if request.endpoint in {"index", "basket", "add_to_basket"}:
        leak_size = AVeryMemoryIntensiveFunction()
        app.logger.error("AVeryMemoryIntensiveFunction leak size=%s", leak_size)


@app.route("/")
def index() -> str:
    basket = session.get("basket", {})
    return render_template_string(
        """
        <h1>Zava pet products</h1>
        <h2>Catalog</h2>
        <ul>
          {% for item in catalog %}
          <li>
            {{ item.name }} - €{{ "%.2f"|format(item.price) }}
            <form method="post" action="{{ url_for('add_to_basket', item_id=item.id) }}" style="display:inline">
              <button type="submit">Add to basket</button>
            </form>
          </li>
          {% endfor %}
        </ul>
        <p><a href="{{ url_for('basket') }}">Basket ({{ basket_size }})</a></p>
        """,
        catalog=CATALOG,
        basket_size=sum(basket.values()) if basket else 0,
    )


@app.post("/basket/add/<item_id>")
def add_to_basket(item_id: str):
    basket = session.get("basket", {})
    basket[item_id] = basket.get(item_id, 0) + 1
    session["basket"] = basket
    return redirect(url_for("index"))


@app.route("/basket")
def basket() -> str:
    basket_data = session.get("basket", {})
    items = []
    total = 0.0
    for item in CATALOG:
        quantity = basket_data.get(item["id"], 0)
        if quantity:
            line_total = quantity * item["price"]
            items.append({"name": item["name"], "quantity": quantity, "line_total": line_total})
            total += line_total

    return render_template_string(
        """
        <h1>Your basket</h1>
        <ul>
          {% for item in items %}
          <li>{{ item.name }} x {{ item.quantity }} = €{{ "%.2f"|format(item.line_total) }}</li>
          {% endfor %}
        </ul>
        <p>Total: €{{ "%.2f"|format(total) }}</p>
        <p><a href="{{ url_for('index') }}">Back to catalog</a></p>
        """,
        items=items,
        total=total,
    )


@app.get("/healthz")
def healthz() -> tuple[str, int]:
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
