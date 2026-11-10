// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

interface IBurnable {
    function balanceOf(address) external view returns (uint256);
    function burn(uint256 amount) external;
}

/// @title BurnVault
/// @notice Where tokens wait to be destroyed (spec v1.16 §7, §18.2).
///
/// It holds only the token. It has no withdraw function, no admin and no way
/// to vote or lock. The only thing that can happen to what it holds is
/// `burn`, which anyone may call once a burn day has come round. The meter
/// counts tokens actually burned, never tokens merely deposited.
contract BurnVault {
    IBurnable public immutable token;
    /// Seconds between burn days.
    uint256 public immutable period;
    /// The next moment a burn may happen.
    uint256 public nextBurnAt;
    /// The meter.
    uint256 public totalBurned;
    uint256 public burnsDone;

    event Burned(uint256 amount, uint256 totalBurned);

    error NotBurnDay();
    error BadPeriod();

    constructor(IBurnable token_, uint256 period_, uint256 firstBurnAt) {
        if (period_ == 0) revert BadPeriod();
        token = token_;
        period = period_;
        nextBurnAt = firstBurnAt;
    }

    /// What is waiting to be burned.
    function waiting() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// Burn everything held. Anyone may call, on or after burn day.
    function burn() external returns (uint256 amount) {
        if (block.timestamp < nextBurnAt) revert NotBurnDay();
        // The next burn day is a whole number of periods on, however late this call is.
        nextBurnAt += ((block.timestamp - nextBurnAt) / period + 1) * period;
        amount = token.balanceOf(address(this));
        totalBurned += amount;
        ++burnsDone;
        if (amount != 0) token.burn(amount);
        emit Burned(amount, totalBurned);
    }
}
