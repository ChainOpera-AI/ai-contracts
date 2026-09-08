// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

/// @title Shared USD fixed-point conventions for the payment contracts.
/// @notice Prices are quoted in Chainlink-style fixed-point USD (USD * 10^USD_DECIMALS) and
/// converted to token amounts at the point of charge. Keeping the convention and both
/// conversions here means the subscription and top-up contracts cannot drift apart on it.
library UsdPricing {
    /// @dev rawAmount uses USD * 1e8 (e.g. $19.99 -> 1_999_000_000).
    uint8 internal constant USD_DECIMALS = 8;
    /// @dev Discount denominator. A discount of 700 / 1000 is 30% off; DISCOUNT_BASE is full price.
    uint internal constant DISCOUNT_BASE = 1000;

    /// @notice Convert a USD * 10^USD_DECIMALS amount into wei of a token pegged 1:1 to USD
    /// (USDT, USDC).
    function toStableAmount(uint rawAmount, uint8 tokenDecimals) internal pure returns (uint) {
        return rawAmount * (10 ** tokenDecimals) / (10 ** USD_DECIMALS);
    }

    /// @notice Apply a pay-token discount to a USD price. `discount` is a numerator over
    /// DISCOUNT_BASE; callers are responsible for rejecting 0 and anything above DISCOUNT_BASE
    /// when the value is set.
    function applyDiscount(uint rawAmount, uint discount) internal pure returns (uint) {
        return rawAmount * discount / DISCOUNT_BASE;
    }
}
