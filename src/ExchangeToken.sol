// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title ExchangeToken
/// @notice The venue's token: fixed supply, minted once, deflationary only
/// (spec v1.16 §5, §18.2).
///
/// A plain contract. No proxy, no delegatecall, no upgrade path, no owner and
/// no privileged role. Nothing can mint after the constructor. Anyone can
/// burn their own.
///
/// The code carries no numbers and no chain. The name, the supply and who
/// receives it are constructor arguments held in storage, and the permit
/// domain is worked out at call time. So the deployed code is byte-for-byte
/// the same whatever the supply and whichever chain it is on, and one code
/// hash, checked by the Buyback Engine on every buy, identifies it.
contract ExchangeToken is ERC20 {
    string internal _name;
    string internal _symbol;
    /// What was minted at birth. The live supply can only be at or below this.
    uint256 public mintedAtBirth;

    error LengthMismatch();

    constructor(string memory name_, string memory symbol_, address[] memory holders, uint256[] memory amounts) {
        if (holders.length != amounts.length) revert LengthMismatch();
        _name = name_;
        _symbol = symbol_;
        uint256 total;
        for (uint256 i; i < holders.length; ++i) {
            _mint(holders[i], amounts[i]);
            total += amounts[i];
        }
        mintedAtBirth = total;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// Destroy some of the caller's own tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
