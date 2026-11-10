// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IV5PoolForSplitter {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sweep() external;
    function donate(uint256 amount0, uint256 amount1) external;
}

/// @title VenueSplitter
/// @notice Divides one pool's venue cut between its lines (spec v1.16 §18.4, §18.8).
///
/// Set this contract as the pool's `venue`. Anyone may call `distribute`. Each
/// call pulls what the pool owes and sends it on:
///   - the build fund,
///   - protocol-owned liquidity,
///   - the prize slice,
///   - the buyback line, which before the token exists is itself split: a
///     share goes straight back to the pool's LPs as fees, and the rest is
///     banked for the launch burn.
///
/// The lines are settings, changeable by the configurer and frozen by handing
/// that role to the zero address. They always sum to the whole.
///
/// First cut. The banked share is sent on in the tokens collected; swapping it
/// to the primary stable, the holding cap and the escrow that receives it are
/// not built. Not audited.
contract VenueSplitter {
    uint256 internal constant WAD = 1e18;

    IV5PoolForSplitter public immutable pool;
    address public immutable token0;
    address public immutable token1;

    struct Lines {
        /// Shares of the venue cut (WAD). The buyback line is whatever is left.
        uint256 buildWad;
        uint256 polWad;
        uint256 prizeWad;
        /// Share of the buyback line returned to the pool's LPs (WAD). The rest is banked.
        uint256 buybackToLpsWad;
        address build;
        address pol;
        address prize;
        address bank;
    }

    Lines internal _lines;
    address public configurer;

    /// Running totals per token, for anyone reading the books.
    uint256[2] public sentToBuild;
    uint256[2] public sentToPol;
    uint256[2] public sentToPrize;
    uint256[2] public returnedToLps;
    uint256[2] public banked;

    event LinesSet(Lines lines);
    event ConfigurerSet(address configurer);
    event Distributed(uint256 amount0, uint256 amount1);

    error NotAllowed();
    error BadLines();

    constructor(IV5PoolForSplitter pool_, Lines memory l, address configurer_) {
        pool = pool_;
        token0 = pool_.token0();
        token1 = pool_.token1();
        configurer = configurer_;
        _setLines(l);
        SafeTransferLib.safeApprove(token0, address(pool_), type(uint256).max);
        SafeTransferLib.safeApprove(token1, address(pool_), type(uint256).max);
    }

    function lines() external view returns (Lines memory) {
        return _lines;
    }

    /// Collect what the pool owes the venue and send every line its share.
    function distribute() external {
        pool.sweep();
        Lines memory l = _lines;
        uint256[2] memory toLps;
        uint256[2] memory total;
        for (uint256 k; k < 2; ++k) {
            address token = k == 0 ? token0 : token1;
            uint256 amount = SafeTransferLib.balanceOf(token, address(this));
            if (amount == 0) continue;
            total[k] = amount;
            uint256 toBuild = amount * l.buildWad / WAD;
            uint256 toPol = amount * l.polWad / WAD;
            uint256 toPrize = amount * l.prizeWad / WAD;
            uint256 buyback = amount - toBuild - toPol - toPrize;
            toLps[k] = buyback * l.buybackToLpsWad / WAD;
            uint256 toBank = buyback - toLps[k];

            sentToBuild[k] += toBuild;
            sentToPol[k] += toPol;
            sentToPrize[k] += toPrize;
            returnedToLps[k] += toLps[k];
            banked[k] += toBank;
            if (toBuild != 0) SafeTransferLib.safeTransfer(token, l.build, toBuild);
            if (toPol != 0) SafeTransferLib.safeTransfer(token, l.pol, toPol);
            if (toPrize != 0) SafeTransferLib.safeTransfer(token, l.prize, toPrize);
            if (toBank != 0) SafeTransferLib.safeTransfer(token, l.bank, toBank);
        }
        if (toLps[0] != 0 || toLps[1] != 0) pool.donate(toLps[0], toLps[1]);
        emit Distributed(total[0], total[1]);
    }

    function setLines(Lines calldata l) external {
        if (msg.sender != configurer) revert NotAllowed();
        _setLines(l);
    }

    function setConfigurer(address next) external {
        if (msg.sender != configurer) revert NotAllowed();
        configurer = next;
        emit ConfigurerSet(next);
    }

    function _setLines(Lines memory l) private {
        if (
            l.buildWad + l.polWad + l.prizeWad > WAD || l.buybackToLpsWad > WAD || l.build == address(0)
                || l.pol == address(0) || l.prize == address(0) || l.bank == address(0)
        ) revert BadLines();
        _lines = l;
        emit LinesSet(l);
    }
}
