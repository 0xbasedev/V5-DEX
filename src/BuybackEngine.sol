// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPriceSource} from "./TuningFork.sol";

interface IPoolForEngine {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function price() external view returns (uint256);
    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address to) external returns (uint256);
}

interface ITokenForEngine {
    function totalSupply() external view returns (uint256);
}

/// @title BuybackEngine
/// @notice Buys the token with the venue's stables, a little at a time, and
/// sends what it buys to the Burn Vault (spec v1.16 §7, §18.2).
///
/// It has no admin, no settings and no setter. Everything is fixed when it is
/// deployed, and it is deployed through the timelocked deployer, so every
/// value below was published and waited out the delay.
///
///  - The token's address is committed. On every buy the code at that address
///    must match the audited token's code hash, and the token's supply must
///    be at or below the committed figure. A token that could mint, or a
///    different contract at the address, stops the Engine.
///  - It buys at most once a block, and at most `perBuy` each time. No single
///    predictable purchase exists to be traded against.
///  - It never pays more than a set premium over a reference price. The
///    reference is an outside source if there is one. Until the token has an
///    outside market, the reference is the Engine's own average of the pool's
///    price over a long window, and it will not buy until it has watched for a
///    full window.
///  - It does nothing before its start time.
///
/// Remaining weakness, stated: with no outside source the average is built
/// from readings anyone may trigger, each taken at the price of that moment.
/// Whoever alone triggers readings can lean on it. The premium limit, the
/// small size of each buy and the long window bound the damage; a keeper that
/// takes a reading every block removes most of it.
contract BuybackEngine {
    uint256 internal constant WAD = 1e18;
    /// How many checkpoints the average keeps per window.
    uint256 internal constant GRAIN = 8;

    address public immutable asset;
    address public immutable token;
    bytes32 public immutable tokenCodeHash;
    uint256 public immutable supplyCommitment;
    IPoolForEngine public immutable pool;
    address public immutable burnVault;
    /// The most of the asset one buy may spend.
    uint256 public immutable perBuy;
    uint256 public immutable startAt;
    /// Optional outside price, asset per token scaled by 1e18. Zero means use the Engine's own average.
    address public immutable priceSource;
    /// How long the Engine's own average looks back.
    uint256 public immutable window;
    /// The most it will pay above the reference (WAD).
    uint256 public immutable maxPremiumWad;
    bool internal immutable _assetIsToken0;

    uint256 public lastBuyBlock;
    uint256 public totalSpent;
    uint256 public totalBought;

    // The Engine's own record of the pool's price, asset per token.
    uint256 public lastPrice;
    uint256 public lastSeen;
    uint256 public cumulative;
    uint64[] internal _checkTimes;
    uint256[] internal _checkSums;

    event Bought(uint256 spent, uint256 bought, uint256 referenceWad);

    error NotStarted();
    error OncePerBlock();
    error WrongToken();
    error NothingToSpend();
    error NotEnoughHistory();
    error BadSetup();

    struct Setup {
        address asset;
        address token;
        bytes32 tokenCodeHash;
        uint256 supplyCommitment;
        address pool;
        address burnVault;
        uint256 perBuy;
        uint256 startAt;
        address priceSource;
        uint256 window;
        uint256 maxPremiumWad;
    }

    constructor(Setup memory s) {
        IPoolForEngine p = IPoolForEngine(s.pool);
        bool is0 = p.token0() == s.asset && p.token1() == s.token;
        bool is1 = p.token1() == s.asset && p.token0() == s.token;
        if ((!is0 && !is1) || s.perBuy == 0 || s.window == 0 || s.burnVault == address(0)) revert BadSetup();
        asset = s.asset;
        token = s.token;
        tokenCodeHash = s.tokenCodeHash;
        supplyCommitment = s.supplyCommitment;
        pool = p;
        burnVault = s.burnVault;
        perBuy = s.perBuy;
        startAt = s.startAt;
        priceSource = s.priceSource;
        window = s.window;
        maxPremiumWad = s.maxPremiumWad;
        _assetIsToken0 = is0;
        SafeTransferLib.safeApprove(s.asset, s.pool, type(uint256).max);
    }

    /// The pool's price right now, in asset per token scaled by 1e18.
    function spot() public view returns (uint256) {
        uint256 p = pool.price(); // token1 per token0
        return _assetIsToken0 ? WAD * WAD / p : p;
    }

    /// Take a reading of the pool's price for the Engine's average. Anyone may call.
    function observe() public {
        uint256 last = lastSeen;
        if (block.timestamp == last) return;
        if (last != 0) cumulative += lastPrice * (block.timestamp - last);
        lastSeen = block.timestamp;
        lastPrice = spot();
        uint256 n = _checkTimes.length;
        if (n == 0 || block.timestamp - _checkTimes[n - 1] >= window / GRAIN) {
            _checkTimes.push(uint64(block.timestamp));
            _checkSums.push(cumulative);
        }
    }

    /// The Engine's own average price over at least one full window.
    function average() public view returns (uint256) {
        uint256 n = _checkTimes.length;
        uint256 cutoff = block.timestamp - window;
        // The newest checkpoint that is at least a window old.
        while (n != 0 && _checkTimes[n - 1] > cutoff) --n;
        if (n == 0) revert NotEnoughHistory();
        uint256 sumNow = cumulative + lastPrice * (block.timestamp - lastSeen);
        return (sumNow - _checkSums[n - 1]) / (block.timestamp - _checkTimes[n - 1]);
    }

    /// The price the Engine measures a buy against.
    function referencePrice() public view returns (uint256) {
        return priceSource == address(0) ? average() : IPriceSource(priceSource).priceWad();
    }

    /// Make this block's buy. Anyone may call.
    function buy() external returns (uint256 spent, uint256 bought) {
        if (block.timestamp < startAt) revert NotStarted();
        if (block.number <= lastBuyBlock) revert OncePerBlock();
        if (token.codehash != tokenCodeHash || ITokenForEngine(token).totalSupply() > supplyCommitment) {
            revert WrongToken();
        }
        observe();
        spent = SafeTransferLib.balanceOf(asset, address(this));
        if (spent > perBuy) spent = perBuy;
        if (spent == 0) revert NothingToSpend();

        uint256 ref = referencePrice();
        // Never pay more than the reference plus the premium.
        uint256 minOut = spent * WAD / (ref * (WAD + maxPremiumWad) / WAD);
        lastBuyBlock = block.number;
        bought = pool.swap(asset, spent, minOut, burnVault);
        totalSpent += spent;
        totalBought += bought;
        emit Bought(spent, bought, ref);
    }
}
