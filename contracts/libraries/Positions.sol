// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.13;

import '../interfaces/IRangePoolStructs.sol';
import './DyDxMath.sol';
import './FeeMath.sol';
import './PrecisionMath.sol';
import './TickMath.sol';
import './Ticks.sol';
import './Tokens.sol';
import './Samples.sol';

/// @notice Position management library for ranged liquidity.
library Positions {
    error NotEnoughPositionLiquidity();
    error InvalidClaimTick();
    error LiquidityOverflow();
    error WrongTickClaimedAt();
    error NoLiquidityBeingAdded();
    error PositionNotUpdated();
    error InvalidLowerTick();
    error InvalidUpperTick();
    error InvalidPositionAmount();
    error InvalidPositionBoundsOrder();
    error NotImplementedYet();

    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    event Mint(
        address indexed recipient,
        int24 indexed lower,
        int24 indexed upper,
        uint128 liquidityMinted,
        uint128 amount0,
        uint128 amount1
    );

    event Burn(
        address owner,
        address indexed recipient,
        int24 indexed lower,
        int24 indexed upper,
        uint128 liquidityBurned,
        uint128 amount0,
        uint128 amount1,
        bool collect
    );

    event Compound(
        address indexed owner,
        int24 indexed lower,
        int24 indexed upper,
        uint128 liquidityCompounded,
        uint128 positionAmount0,
        uint128 positionAmount1
    );

    event MintFungible(
        int24 lower,
        int24 upper,
        uint128 liquidityMinted,
        uint128 amount0,
        uint128 amount1
    );

    event BurnFungible(
        address indexed recipient,
        uint256 indexed tokenId,
        uint128 tokenBurned,
        uint128 liquidityBurned,
        uint128 amount0,
        uint128 amount1
    );

    function validate(
        IRangePoolStructs.MintParams memory params,
        IRangePoolStructs.PoolState memory state,
        IRangePoolStructs.Immutables memory constants
    ) external pure returns (IRangePoolStructs.MintParams memory, uint256 liquidityMinted) {
        Ticks.validate(params.lower, params.upper, constants.tickSpacing);
        
        uint256 priceLower = uint256(TickMath.getSqrtRatioAtTick(params.lower));
        uint256 priceUpper = uint256(TickMath.getSqrtRatioAtTick(params.upper));

        liquidityMinted = DyDxMath.getLiquidityForAmounts(
            priceLower,
            priceUpper,
            state.price,
            params.amount1,
            params.amount0
        );
        if (liquidityMinted == 0) require(false, 'NoLiquidityBeingAdded()');
        (params.amount0, params.amount1) = DyDxMath.getAmountsForLiquidity(
            priceLower,
            priceUpper,
            state.price,
            liquidityMinted,
            true
        );
        if (liquidityMinted > uint128(type(int128).max)) require(false, 'LiquidityOverflow()');

        return (params, liquidityMinted);
    }

    function add(
        IRangePoolStructs.Position memory position,
        mapping(int24 => IRangePoolStructs.Tick) storage ticks,
        IRangePoolStructs.Sample[65535] storage samples,
        IRangePoolStructs.TickMap storage tickMap,
        IRangePoolStructs.AddParams memory params
    ) external returns (
        IRangePoolStructs.PoolState memory,
        IRangePoolStructs.Position memory,
        uint128
    ) {
        if (params.mint.amount0 == 0 && params.mint.amount1 == 0) return (params.state, position, 0);

        IRangePoolStructs.PositionCache memory cache = IRangePoolStructs.PositionCache({
            priceLower: TickMath.getSqrtRatioAtTick(params.mint.lower),
            priceUpper: TickMath.getSqrtRatioAtTick(params.mint.upper),
            liquidityOnPosition: 0,
            liquidityAmount: 0,
            totalSupply: Tokens.totalSupply(address(this), params.mint.lower, params.mint.upper),
            tokenId: Tokens.id(params.mint.lower, params.mint.upper)
        });

        params.state = Ticks.insert(
            ticks,
            samples,
            tickMap,
            params.state,
            params.mint.lower,
            params.mint.upper,
            params.amount
        );

        (
            position.feeGrowthInside0Last,
            position.feeGrowthInside1Last
        ) = rangeFeeGrowth(
            ticks[params.mint.lower],
            ticks[params.mint.upper],
            params.state,
            params.mint.lower,
            params.mint.upper
        );

        position.liquidity += uint128(params.amount);
        
        // modify liquidity minted to account for fees accrued
        if (params.mint.fungible) {
            if (position.amount0 > 0 || position.amount1 > 0
                || (position.liquidity - params.amount) > cache.totalSupply) {
                // modify amount based on autocompounded fees
                if (cache.totalSupply > 0) {
                    cache.liquidityOnPosition = DyDxMath.getLiquidityForAmounts(
                                                    cache.priceLower,
                                                    cache.priceUpper,
                                                    position.amount0 > 0 ? cache.priceLower : cache.priceUpper,
                                                    position.amount1,
                                                    position.amount0
                                                );
                    params.amount = uint128(uint256(params.amount) * cache.totalSupply /
                         (uint256(position.liquidity - params.amount) + cache.liquidityOnPosition));
                } /// @dev - if there are fees on the position we mint less positionToken
            }
            IRangePoolERC1155(address(this)).mintFungible(params.mint.to, cache.tokenId, params.amount);
            emit MintFungible(
                params.mint.lower,
                params.mint.upper,
                params.liquidity,
                params.mint.amount0,
                params.mint.amount1
            );
        } else {
            emit Mint(
                params.mint.to, 
                params.mint.lower,
                params.mint.upper,
                params.amount,
                params.mint.amount0,
                params.mint.amount1
            );
        }
        return (params.state, position, params.amount);
    }

    function remove(
        IRangePoolStructs.Position memory position,
        mapping(int24 => IRangePoolStructs.Tick) storage ticks,
        IRangePoolStructs.Sample[65535] storage samples,
        IRangePoolStructs.TickMap storage tickMap,
        IRangePoolStructs.PoolState memory state,
        IRangePoolStructs.BurnParams memory params,
        IRangePoolStructs.RemoveParams memory removeParams
    ) external returns (
        IRangePoolStructs.PoolState memory,
        IRangePoolStructs.Position memory,
        uint128,
        uint128
    ) {
        IRangePoolStructs.PositionCache memory cache = IRangePoolStructs.PositionCache({
            priceLower: TickMath.getSqrtRatioAtTick(params.lower),
            priceUpper: TickMath.getSqrtRatioAtTick(params.upper),
            liquidityOnPosition: 0,
            liquidityAmount: 0,
            totalSupply: 0,
            tokenId: Tokens.id(params.lower, params.upper)
        }); 
        if (params.fungible){
            
            cache.totalSupply = Tokens.totalSupplyById(address(this), cache.tokenId);
        }
        cache.liquidityAmount = params.fungible && params.amount > 0 ? uint256(params.amount) * uint256(position.liquidity) 
                                                                       / (cache.totalSupply + params.amount)
                                                                     : params.amount;
        if (params.amount == 0) {
            emit Burn(
                params.fungible ? address(this) : msg.sender,
                msg.sender,
                params.lower,
                params.upper,
                params.amount,
                removeParams.amount0,
                removeParams.amount1,
                params.collect
            );
            return (state, position, removeParams.amount0, removeParams.amount1);
        } 
        if (params.amount > position.liquidity) require(false, 'NotEnoughPositionLiquidity()');
        {
            uint128 amount0Removed; uint128 amount1Removed;
            (amount0Removed, amount1Removed) = DyDxMath.getAmountsForLiquidity(
                cache.priceLower,
                cache.priceUpper,
                state.price,
                cache.liquidityAmount,
                true
            );
            if (params.fungible && params.amount > 0) {
                params.collect = true;
            }
            removeParams.amount0 += amount0Removed;
            removeParams.amount1 += amount1Removed;

            position.amount0 += amount0Removed;
            position.amount1 += amount1Removed;
            position.liquidity -= uint128(cache.liquidityAmount);
        }
        if (position.liquidity == 0) {
            position.feeGrowthInside0Last = 0;
            position.feeGrowthInside1Last = 0;
        }
        state = Ticks.remove(
            ticks,
            samples,
            tickMap,
            state, 
            params.lower,
            params.upper,
            uint128(cache.liquidityAmount)
        );

        if (params.fungible) {
            emit BurnFungible(
                params.to,
                cache.tokenId,
                params.amount,
                uint128(cache.liquidityAmount),
                removeParams.amount0,
                removeParams.amount1
            );
        } else {
            emit Burn(
                params.fungible ? address(this) : msg.sender,
                msg.sender,
                params.lower,
                params.upper,
                uint128(cache.liquidityAmount),
                removeParams.amount0,
                removeParams.amount1,
                params.collect
            );
        }
        return (state, position, removeParams.amount0, removeParams.amount1);
    }

    function compound(
        IRangePoolStructs.Position memory position,
        mapping(int24 => IRangePoolStructs.Tick) storage ticks,
        IRangePoolStructs.Sample[65535] storage samples,
        IRangePoolStructs.TickMap storage tickMap,
        IRangePoolStructs.PoolState memory state,
        IRangePoolStructs.CompoundParams memory params
    ) external returns (IRangePoolStructs.Position memory, IRangePoolStructs.PoolState memory) {
        IRangePoolStructs.PositionCache memory cache = IRangePoolStructs.PositionCache({
            priceLower: TickMath.getSqrtRatioAtTick(params.lower),
            priceUpper: TickMath.getSqrtRatioAtTick(params.upper),
            liquidityOnPosition: 0,
            liquidityAmount: 0,
            totalSupply: 0,
            tokenId: 0
        });

        // price tells you the ratio so you need to swap into the correct ratio and add liquidity
        cache.liquidityAmount = DyDxMath.getLiquidityForAmounts(
            cache.priceLower,
            cache.priceUpper,
            state.price,
            position.amount1,
            position.amount0
        );
        if (cache.liquidityAmount > 0) {
            state = Ticks.insert(
                ticks,
                samples,
                tickMap,
                state,
                params.lower,
                params.upper,
                uint128(cache.liquidityAmount)
            );
            uint256 amount0; uint256 amount1;
            (amount0, amount1) = DyDxMath.getAmountsForLiquidity(
                cache.priceLower,
                cache.priceUpper,
                state.price,
                cache.liquidityAmount,
                true
            );
            position.amount0 -= uint128(amount0);
            position.amount1 -= uint128(amount1);
            position.liquidity += uint128(cache.liquidityAmount);
        }
        emit Compound(
            params.owner,
            params.lower,
            params.upper,
            uint128(cache.liquidityAmount),
            position.amount0,
            position.amount1
        );
        return (position, state);
    }

    function update(
        mapping(int24 => IRangePoolStructs.Tick) storage ticks,
        IRangePoolStructs.Position memory position,
        IRangePoolStructs.PoolState memory state,
        IRangePoolStructs.UpdateParams memory params
    ) external returns (
        IRangePoolStructs.Position memory, 
        uint128, 
        uint128
    ) {
        uint256 totalSupply;
        if (params.fungible) {
            totalSupply = Tokens.totalSupply(address(this), params.lower, params.upper);
            if (params.amount > 0) {
                uint256 tokenId = Tokens.id(params.lower, params.upper);
                IRangePoolERC1155(address(this)).burnFungible(msg.sender, tokenId, params.amount);
            }
        }
        
        (uint256 rangeFeeGrowth0, uint256 rangeFeeGrowth1) = rangeFeeGrowth(
            ticks[params.lower],
            ticks[params.upper],
            state,
            params.lower,
            params.upper
        );

        uint128 amount0Fees = uint128(
            PrecisionMath.mulDiv(
                rangeFeeGrowth0 - position.feeGrowthInside0Last,
                uint256(position.liquidity),
                Q128
            )
        );

        uint128 amount1Fees = uint128(
            PrecisionMath.mulDiv(
                rangeFeeGrowth1 - position.feeGrowthInside1Last,
                position.liquidity,
                Q128
            )
        );

        position.feeGrowthInside0Last = rangeFeeGrowth0;
        position.feeGrowthInside1Last = rangeFeeGrowth1;

        position.amount0 += uint128(amount0Fees);
        position.amount1 += uint128(amount1Fees);

        if (params.fungible) {
            uint128 feesBurned0; uint128 feesBurned1;
            if (params.amount > 0) {
                feesBurned0 = uint128(
                    (uint256(position.amount0) * uint256(uint128(params.amount))) / (totalSupply)
                );
                feesBurned1 = uint128(
                    (uint256(position.amount1) * uint256(uint128(params.amount))) / (totalSupply)
                );
            }
            return (position, feesBurned0, feesBurned1);
        }
        return (position, amount0Fees, amount1Fees);
    }

    function rangeFeeGrowth(
        IRangePoolStructs.Tick memory lowerTick,
        IRangePoolStructs.Tick memory upperTick,
        IRangePoolStructs.PoolState memory state,
        int24 lower,
        int24 upper
    ) internal pure returns (uint256 feeGrowthInside0, uint256 feeGrowthInside1) {

        uint256 feeGrowthGlobal0 = state.feeGrowthGlobal0;
        uint256 feeGrowthGlobal1 = state.feeGrowthGlobal1;

        uint256 feeGrowthBelow0;
        uint256 feeGrowthBelow1;
        if (state.tickAtPrice >= lower) {
            feeGrowthBelow0 = lowerTick.feeGrowthOutside0;
            feeGrowthBelow1 = lowerTick.feeGrowthOutside1;
        } else {
            feeGrowthBelow0 = feeGrowthGlobal0 - lowerTick.feeGrowthOutside0;
            feeGrowthBelow1 = feeGrowthGlobal1 - lowerTick.feeGrowthOutside1;
        }

        uint256 feeGrowthAbove0;
        uint256 feeGrowthAbove1;
        if (state.tickAtPrice < upper) {
            feeGrowthAbove0 = upperTick.feeGrowthOutside0;
            feeGrowthAbove1 = upperTick.feeGrowthOutside1;
        } else {
            feeGrowthAbove0 = feeGrowthGlobal0 - upperTick.feeGrowthOutside0;
            feeGrowthAbove1 = feeGrowthGlobal1 - upperTick.feeGrowthOutside1;
        }
        feeGrowthInside0 = feeGrowthGlobal0 - feeGrowthBelow0 - feeGrowthAbove0;
        feeGrowthInside1 = feeGrowthGlobal1 - feeGrowthBelow1 - feeGrowthAbove1;
    }

    function rangeFeeGrowth(
        address pool,
        int24 lower,
        int24 upper
    ) external view returns (
        uint256 feeGrowthInside0,
        uint256 feeGrowthInside1
    ) {
        Ticks.validate(lower, upper, IRangePool(pool).tickSpacing());
        (
            ,,
            int24 currentTick,
            ,,,,,
            uint256 _feeGrowthGlobal0,
            uint256 _feeGrowthGlobal1,
            ,
        ) = IRangePool(pool).poolState();
        (
            ,
            uint216 tickLowerFeeGrowthOutside0,
            uint216 tickLowerFeeGrowthOutside1,
            ,
        )
            = IRangePool(pool).ticks(lower);
        (
            ,
            uint216 tickUpperFeeGrowthOutside0,
            uint216 tickUpperFeeGrowthOutside1,
            ,
        )
            = IRangePool(pool).ticks(upper);

        // ticks not initialized or range not crossed into
        if (tickLowerFeeGrowthOutside0 == 0
            && tickLowerFeeGrowthOutside1 == 0
            && tickUpperFeeGrowthOutside0 == 0
            && tickUpperFeeGrowthOutside0 == 0) {
            return (0,0);
        }

        uint256 feeGrowthBelow0;
        uint256 feeGrowthBelow1;
        uint256 feeGrowthAbove0;
        uint256 feeGrowthAbove1;

        if (lower <= currentTick) {
            feeGrowthBelow0 = tickLowerFeeGrowthOutside0;
            feeGrowthBelow1 = tickLowerFeeGrowthOutside1;
        } else {
            feeGrowthBelow0 = _feeGrowthGlobal0 - tickLowerFeeGrowthOutside0;
            feeGrowthBelow1 = _feeGrowthGlobal1 - tickLowerFeeGrowthOutside1;
        }

        if (currentTick < upper) {
            feeGrowthAbove0 = tickUpperFeeGrowthOutside0;
            feeGrowthAbove1 = tickUpperFeeGrowthOutside1;
        } else {
            feeGrowthAbove0 = _feeGrowthGlobal0 - tickUpperFeeGrowthOutside0;
            feeGrowthAbove1 = _feeGrowthGlobal1 - tickUpperFeeGrowthOutside1;
        }
        feeGrowthInside0 = _feeGrowthGlobal0 - feeGrowthBelow0 - feeGrowthAbove0;
        feeGrowthInside1 = _feeGrowthGlobal1 - feeGrowthBelow1 - feeGrowthAbove1;
    }

    function snapshot(
        address pool,
        int24 lower,
        int24 upper
    ) external view returns (
        int56   tickSecondsAccum,
        uint160 secondsPerLiquidityAccum,
        uint32  secondsGrowth
    ) {
        Ticks.validate(lower, upper, IRangePool(pool).tickSpacing());

        IRangePoolStructs.SnapshotCache memory cache;
        (
            ,
            ,,,,
            cache.price,
            cache.liquidity,
            ,,,
            cache.samples,
        ) = IRangePool(pool).poolState();
        (
            ,,,
            cache.tickSecondsAccumLower,
            cache.secondsPerLiquidityAccumLower
        )
            = IRangePool(pool).ticks(lower);

        // if both have never been crossed into return 0
        (
            ,,,
            cache.tickSecondsAccumUpper,
            cache.secondsPerLiquidityAccumUpper
        )
            = IRangePool(pool).ticks(upper);

        // ticks not initialized or range not crossed into
        if (cache.secondsOutsideUpper == 0
            && cache.secondsOutsideLower == 0){
            return (0,0,0);
        }
        
        cache.tick = TickMath.getTickAtSqrtRatio(cache.price);

        if (lower >= cache.tick) {
            return (
                cache.tickSecondsAccumLower - cache.tickSecondsAccumUpper,
                cache.secondsPerLiquidityAccumLower - cache.secondsPerLiquidityAccumUpper,
                cache.secondsOutsideLower - cache.secondsOutsideUpper
            );
        } else if (upper >= cache.tick) {
            cache.blockTimestamp = uint32(block.timestamp);
            (
                cache.tickSecondsAccum,
                cache.secondsPerLiquidityAccum
            ) = Samples.getSingle(
                IRangePool(address(this)), 
                IRangePoolStructs.SampleParams(
                    cache.samples.index,
                    cache.samples.length,
                    uint32(block.timestamp),
                    new uint32[](2),
                    cache.tick,
                    cache.liquidity
                ),
                0
            );
            return (
                cache.tickSecondsAccum 
                  - cache.tickSecondsAccumLower 
                  - cache.tickSecondsAccumUpper,
                cache.secondsPerLiquidityAccum
                  - cache.secondsPerLiquidityAccumLower
                  - cache.secondsPerLiquidityAccumUpper,
                cache.blockTimestamp
                  - cache.secondsOutsideLower
                  - cache.secondsOutsideUpper
            );
        }
    }

    function id(int24 lower, int24 upper) public pure returns (uint256) {
        return Tokens.id(lower, upper);
    }
}
