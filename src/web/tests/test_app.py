import unittest

from app import LEAK_BUCKET, app


class WebAppTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.client = app.test_client()
        LEAK_BUCKET.clear()

    def test_catalog_is_displayed(self) -> None:
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Zava pet products", response.data)

    def test_can_add_item_to_basket(self) -> None:
        self.client.post("/basket/add/1")
        response = self.client.get("/basket")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Dog food", response.data)

    def test_memory_intensive_function_is_triggered_on_navigation(self) -> None:
        self.client.get("/")
        self.assertGreater(len(LEAK_BUCKET), 0)


if __name__ == "__main__":
    unittest.main()
