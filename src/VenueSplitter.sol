// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IV5PoolForSplitter {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sweep() external;
    function donate(uint256 amount0, uint256 amount1) external;
    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address to) external returns (uint256);
}

interface IBankEscrowForSplitter {
    function asset() external view returns (address);
    function room(address pool) external view returns (uint256);
    function bank(address pool, uint256 amount) external;
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
///     banked in the escrow for the launch burn.
///
/// The escrow takes one asset. Banked money that arrives in that asset goes
/// in at once, as far as the pool's cap allows; anything over the cap goes to
/// the LPs instead. Banked money in the pool's other token waits here until
/// the `converter` swaps it, with a minimum it chooses. That swap is not open
/// to everyone, because whoever picks the moment could arrange a bad price.
///
/// With no escrow set, the whole buyback line goes to the LPs.
///
/// The lines are settings, changeable by the configurer and frozen by handing
/// that role to the zero address. They always sum to the whole.
///
/// First cut. Not audited.
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
        /// The escrow. Zero sends the whole buyback line to the LPs.
        address bank;
        /// May swap banked money that is waiting in the wrong token.
        address converter;
    }

    Lines internal _lines;
    address public configurer;

    /// Running totals per token, for anyone reading the books.
    uint256[2] public sentToBuild;
    uint256[2] public sentToPol;
    uint256[2] public sentToPrize;
    uint256[2] public returnedToLps;
    uint256[2] public banked;
    /// Set aside for the bank and not yet in it.
    uint256[2] public waiting;

    event LinesSet(Lines lines);
    event ConfigurerSet(address configurer);
    event Distributed(uint256 amount0, uint256 amount1);
    event Converted(uint256 indexed fromToken, uint256 amountIn, uint256 amountOut);

    error NotAllowed();
    error BadLines();
    error NothingToConvert();

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
            // Money waiting for the bank is not new income.
            uint256 amount = SafeTransferLib.balanceOf(token, address(this)) - waiting[k];
            if (amount == 0) continue;
            total[k] = amount;
            uint256 toBuild = amount * l.buildWad / WAD;
            uint256 toPol = amount * l.polWad / WAD;
            uint256 toPrize = amount * l.prizeWad / WAD;
            uint256 buyback = amount - toBuild - toPol - toPrize;
            toLps[k] = l.bank == address(0) ? buyback : buyback * l.buybackToLpsWad / WAD;
            waiting[k] += buyback - toLps[k];

            sentToBuild[k] += toBuild;
            sentToPol[k] += toPol;
            sentToPrize[k] += toPrize;
            if (toBuild != 0) SafeTransferLib.safeTransfer(token, l.build, toBuild);
            if (toPol != 0) SafeTransferLib.safeTransfer(token, l.pol, toPol);
            if (toPrize != 0) SafeTransferLib.safeTransfer(token, l.prize, toPrize);
        }
        _bankWhatFits(l.bank, toLps);
        _returnToLps(toLps);
        emit Distributed(total[0], total[1]);
    }

    /// Swap banked money waiting in the pool's other token into the escrow's
    /// asset, then bank it. `minOut` is the least the converter will accept.
    function convert(uint256 minOut) external returns (uint256 out) {
        Lines memory l = _lines;
        if (msg.sender != l.converter || l.bank == address(0)) revert NotAllowed();
        address asset = IBankEscrowForSplitter(l.bank).asset();
        uint256 from = asset == token0 ? 1 : 0;
        if (asset != token0 && asset != token1) revert NothingToConvert();
        uint256 amount = waiting[from];
        if (amount == 0) revert NothingToConvert();
        waiting[from] = 0;
        out = pool.swap(from == 0 ? token0 : token1, amount, minOut, address(this));
        waiting[1 - from] += out;
        emit Converted(from, amount, out);

        uint256[2] memory toLps;
        _bankWhatFits(l.bank, toLps);
        _returnToLps(toLps);
    }

    /// Put waiting money that is already in the escrow's asset into the escrow,
    /// as far as the pool's cap allows. What does not fit goes to the LPs.
    function _bankWhatFits(address escrow, uint256[2] memory toLps) private {
        if (escrow == address(0)) return;
        address asset = IBankEscrowForSplitter(escrow).asset();
        if (asset != token0 && asset != token1) return;
        uint256 k = asset == token0 ? 0 : 1;
        uint256 amount = waiting[k];
        if (amount == 0) return;
        uint256 room = IBankEscrowForSplitter(escrow).room(address(pool));
        uint256 put = amount < room ? amount : room;
        waiting[k] = 0;
        toLps[k] += amount - put;
        if (put != 0) {
            banked[k] += put;
            SafeTransferLib.safeApprove(asset, escrow, put);
            IBankEscrowForSplitter(escrow).bank(address(pool), put);
        }
    }

    function _returnToLps(uint256[2] memory toLps) private {
        if (toLps[0] == 0 && toLps[1] == 0) return;
        returnedToLps[0] += toLps[0];
        returnedToLps[1] += toLps[1];
        pool.donate(toLps[0], toLps[1]);
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
                || l.pol == address(0) || l.prize == address(0)
        ) revert BadLines();
        _lines = l;
        emit LinesSet(l);
    }
}
