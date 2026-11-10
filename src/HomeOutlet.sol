// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title HomeOutlet
/// @notice The outlet on the home chain: whatever the escrow releases to it
/// goes on to the Buyback Engine and nowhere else (spec v1.16 §18.8).
///
/// It holds nothing between calls, has no admin and no settings. On any other
/// chain the outlet would send the same money home across chains; that
/// version is not written.
contract HomeOutlet {
    address public immutable asset;
    address public immutable engine;

    event Forwarded(uint256 amount);

    constructor(address asset_, address engine_) {
        asset = asset_;
        engine = engine_;
    }

    /// Pass on everything held. Anyone may call.
    function forward() external returns (uint256 amount) {
        amount = SafeTransferLib.balanceOf(asset, address(this));
        if (amount != 0) SafeTransferLib.safeTransfer(asset, engine, amount);
        emit Forwarded(amount);
    }
}
