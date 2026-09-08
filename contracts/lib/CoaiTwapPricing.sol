// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IPancakeV3PoolState.sol";
import "./TickMath.sol";
import "./UsdPricing.sol";

/// @title COAI pricing off a PancakeV3 TWAP.
/// @notice Turns a USD * 10^USD_DECIMALS amount into COAI wei using the time-weighted average
/// price of a PancakeV3 pool that pairs COAI against a USD-stable quote token. Shared by every
/// contract that accepts COAI so the oracle handling — interval, overflow bounds, tick rounding
/// — is identical everywhere and only has to be reviewed once.
/// @dev All functions are `internal`, so they inline into the calling contract: no library
/// deployment, no delegatecall, and identical runtime behaviour to having the code inline.
library CoaiTwapPricing {
    error TWAPNotAvailable();
    error CoaiNotInPool();

    /// @notice Which side of `pool` COAI sits on, which decides whether the pool's price ratio
    /// has to be inverted. Reverts if COAI is not in the pool at all, so a misconfigured pool
    /// address cannot be stored.
    function resolveCoaiIsToken0(IPancakeV3PoolState pool, address coai) internal view returns (bool) {
        address t0 = pool.token0();
        if (t0 == coai) return true;
        if (pool.token1() == coai) return false;
        revert CoaiNotInPool();
    }

    /// @notice Convert `rawAmount` (USD * 10^USD_DECIMALS) into COAI wei at the pool's TWAP.
    /// @param coaiDecimals Must be 18; callers enforce this when the COAI address is set.
    function toCoaiAmount(
        IPancakeV3PoolState pool,
        uint32 twapInterval,
        bool coaiIsToken0,
        uint8 coaiDecimals,
        uint rawAmount
    ) internal view returns (uint) {
        // PancakeV3 pool with COAI paired against a USD-stable quote (both 18 decimals; COAI enforced).
        // sqrtPriceX96 = sqrt(token1_wei / token0_wei) * 2^96. We compute the COAI amount in wei
        // using Math.mulDiv (512-bit intermediates) so this works across the full price range
        // without overflow (extreme-price token1 path) or silent truncation-to-zero (very small
        // sqrtPriceX96). Same precision/safety pattern as Uniswap V3 OracleLibrary.getQuoteAtTick.
        uint160 sqrtPriceX96 = _twapSqrtPriceX96(pool, twapInterval);
        if (sqrtPriceX96 == 0) revert TWAPNotAvailable();

        // baseAmount = quote-token wei equivalent of rawAmount USD (assumes 18-dec USD-stable quote).
        uint baseAmount = rawAmount * (10 ** (coaiDecimals - UsdPricing.USD_DECIMALS));

        // COAI is token0  =>  USDT is token1  =>  coaiAmount = baseAmount / (token1/token0)
        // COAI is token1  =>  USDT is token0  =>  coaiAmount = baseAmount * (token1/token0)
        if (sqrtPriceX96 <= type(uint128).max) {
            // Square fits in uint256 directly (Q192 ratio).
            uint ratioX192 = uint(sqrtPriceX96) * sqrtPriceX96;
            return coaiIsToken0
                ? Math.mulDiv(1 << 192, baseAmount, ratioX192)
                : Math.mulDiv(ratioX192, baseAmount, 1 << 192);
        } else {
            // sqrtPriceX96^2 would overflow uint256; scale down by 2^64 first (Q128 ratio).
            uint ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            return coaiIsToken0
                ? Math.mulDiv(1 << 128, baseAmount, ratioX128)
                : Math.mulDiv(ratioX128, baseAmount, 1 << 128);
        }
    }

    /// @notice Whether toCoaiAmount would currently succeed. Mirrors its tick handling exactly,
    /// but reports false instead of reverting.
    function isHealthy(IPancakeV3PoolState pool, uint32 twapInterval) internal view returns (bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int256 tickDelta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
            int256 interval = int256(uint256(twapInterval));
            int256 rawAvgTick = tickDelta / interval;
            if (rawAvgTick < int256(TickMath.MIN_TICK) || rawAvgTick > int256(TickMath.MAX_TICK)) return false;
            int24 avgTick = int24(rawAvgTick);
            // Same floor correction as _twapSqrtPriceX96; without it the health check
            // can return true while the price path reverts (avgTick falls below MIN_TICK).
            if (tickDelta < 0 && (tickDelta % interval != 0)) avgTick--;
            return avgTick >= TickMath.MIN_TICK && avgTick <= TickMath.MAX_TICK;
        } catch {
            return false;
        }
    }

    function _twapSqrtPriceX96(IPancakeV3PoolState pool, uint32 twapInterval) private view returns (uint160) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;
        try pool.observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            // Promote to int256 before subtracting so the diff cannot overflow int56 as
            // pool cumulatives drift toward their bounds over years of accumulation.
            int256 tickDelta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
            int256 interval = int256(uint256(twapInterval));
            int256 rawAvgTick = tickDelta / interval;
            // First bound to int24 range so the narrowing cast below is lossless.
            if (rawAvgTick < int256(TickMath.MIN_TICK) || rawAvgTick > int256(TickMath.MAX_TICK)) revert TWAPNotAvailable();
            int24 avgTick = int24(rawAvgTick);
            if (tickDelta < 0 && (tickDelta % interval != 0)) avgTick--;
            // Re-check AFTER the floor correction. At the lower boundary the decrement
            // can push avgTick to MIN_TICK-1, which would make getSqrtRatioAtTick revert
            // with TickOutOfRange — and that revert sits inside the try-success block, so
            // it would NOT be caught by `catch` below and would leak out instead of the
            // intended TWAPNotAvailable. Mirrors the final clamp in isHealthy.
            if (avgTick < TickMath.MIN_TICK || avgTick > TickMath.MAX_TICK) revert TWAPNotAvailable();
            return TickMath.getSqrtRatioAtTick(avgTick);
        } catch {
            revert TWAPNotAvailable();
        }
    }
}
