from __future__ import annotations

from decimal import Decimal

import pytest
from pydantic import ValidationError

from tests.conftest import order_payload
from tradeops import risk, settlement
from tradeops.config import Settings
from tradeops.domain import OrderRequest, OrderStatus, Side, make_order_id, to_cents
from tradeops.risk import RejectReason


def req(**overrides: object) -> OrderRequest:
    return OrderRequest.model_validate(order_payload(**overrides))


class TestOrderRequest:
    def test_limit_order_requires_price(self) -> None:
        with pytest.raises(ValidationError, match="limit_price is required"):
            req(limit_price=None)

    def test_market_order_rejects_price(self) -> None:
        with pytest.raises(ValidationError, match="must be omitted"):
            req(order_type="MARKET")

    @pytest.mark.parametrize(
        ("field", "value"),
        [
            ("quantity", 0),
            ("quantity", -5),
            ("symbol", "aapl"),
            ("account_id", "acc 1"),
            ("client_order_id", "has space"),
            ("limit_price", "1.123456"),
        ],
    )
    def test_rejects_malformed_fields(self, field: str, value: object) -> None:
        with pytest.raises(ValidationError):
            req(**{field: value})

    def test_extra_fields_are_forbidden(self) -> None:
        with pytest.raises(ValidationError):
            OrderRequest.model_validate({**order_payload(), "discount": "1"})

    def test_fingerprint_ignores_client_order_id_but_not_economics(self) -> None:
        assert req(client_order_id="a").fingerprint() == req(client_order_id="b").fingerprint()
        assert req().fingerprint() != req(quantity=101).fingerprint()

    def test_order_id_is_deterministic_per_account_and_client_id(self) -> None:
        assert make_order_id("ACC-1001", "x") == make_order_id("ACC-1001", "x")
        assert make_order_id("ACC-1001", "x") != make_order_id("ACC-1002", "x")

    def test_terminal_statuses(self) -> None:
        assert not OrderStatus.ACCEPTED.is_terminal
        assert all(
            s.is_terminal for s in (OrderStatus.REJECTED, OrderStatus.SETTLED, OrderStatus.FAILED)
        )


class TestRisk:
    settings = Settings()

    def test_accepts_order_within_limits(self) -> None:
        decision = risk.evaluate(req(), self.settings)
        assert decision.accepted
        assert decision.notional == Decimal("23150.00")
        assert not decision.synthetic

    def test_market_order_prices_at_reference(self) -> None:
        decision = risk.evaluate(
            req(order_type="MARKET", limit_price=None, symbol="MSFT"), self.settings
        )
        assert decision.execution_price == Decimal("420.00")
        assert decision.notional == Decimal("42000.00")

    @pytest.mark.parametrize(
        ("overrides", "reason"),
        [
            ({"account_id": "ACC-9999"}, RejectReason.UNKNOWN_ACCOUNT),
            ({"account_id": "ACC-2001"}, RejectReason.ACCOUNT_SUSPENDED),
            ({"symbol": "ZZZZ"}, RejectReason.UNKNOWN_INSTRUMENT),
            ({"symbol": "ACME", "limit_price": "12.50"}, RejectReason.RESTRICTED_INSTRUMENT),
            ({"limit_price": "260.00"}, RejectReason.PRICE_OUTSIDE_COLLAR),
            ({"account_id": "ACC-1002", "quantity": 2000}, RejectReason.NOTIONAL_LIMIT_EXCEEDED),
        ],
    )
    def test_rejections(self, overrides: dict[str, object], reason: str) -> None:
        decision = risk.evaluate(req(**overrides), self.settings)
        assert not decision.accepted
        assert reason in decision.reasons

    def test_collar_boundary_is_inclusive(self) -> None:
        assert risk.evaluate(req(limit_price="253.00"), self.settings).accepted  # exactly +10%
        assert not risk.evaluate(req(limit_price="253.01"), self.settings).accepted

    def test_reports_every_failed_check(self) -> None:
        decision = risk.evaluate(
            req(account_id="ACC-2001", symbol="ACME", limit_price="99.00"), self.settings
        )
        assert set(decision.reasons) == {
            RejectReason.ACCOUNT_SUSPENDED,
            RejectReason.RESTRICTED_INSTRUMENT,
            RejectReason.PRICE_OUTSIDE_COLLAR,
        }

    def test_platform_limit_caps_account_limit(self) -> None:
        tight = Settings(max_order_notional=Decimal("1000.00"))
        assert RejectReason.NOTIONAL_LIMIT_EXCEEDED in risk.evaluate(req(), tight).reasons

    def test_synthetic_accounts_are_flagged(self) -> None:
        assert risk.evaluate(req(account_id="SMOKE-0001", quantity=1), self.settings).synthetic


class TestSettlementMaths:
    def test_minimum_commission(self) -> None:
        assert settlement.commission(Decimal("100.00")) == Decimal("1.00")

    def test_commission_is_five_bps(self) -> None:
        assert settlement.commission(Decimal("23150.00")) == Decimal("11.58")  # 11.575 -> half-even

    def test_half_even_rounding(self) -> None:
        assert to_cents(Decimal("0.125")) == Decimal("0.12")
        assert to_cents(Decimal("0.135")) == Decimal("0.14")

    def test_net_amount_direction(self) -> None:
        assert settlement.net_amount(Side.BUY, Decimal("1000.00"), Decimal("1.00")) == Decimal(
            "-1001.00"
        )
        assert settlement.net_amount(Side.SELL, Decimal("1000.00"), Decimal("1.00")) == Decimal(
            "999.00"
        )
