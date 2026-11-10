// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IPriceSource} from "./TuningFork.sol";

/// @title DepegWatch
/// @notice Says when an outside price has been off its peg for long enough
/// that nobody should have to pay to leave (spec v1.16 §3, review C8).
///
/// It reads an outside source, never the pool's own price: a pool's price can
/// be pushed by anyone with enough money, and a large locker could otherwise
/// buy their own release.
///
/// It needs time, never a single reading. Anyone may call `observe`. The first
/// reading outside the tolerance starts a clock. The clock keeps running only
/// while readings keep coming in, no more than `maxGap` apart, and every one
/// of them is outside. A reading inside, or too long a silence, starts it
/// over. A depeg is reported once the clock has run for `window` and the
/// price is still outside right now.
///
/// Both sides have a reason to keep it honest: someone who wants out free has
/// to keep observing, and the LPs who would collect their toll are the ones
/// served by observing the moment the price comes back.
///
/// Settings are changeable by the configurer and frozen by handing that role
/// to the zero address. First cut. Not audited.
contract DepegWatch {
    uint256 internal constant WAD = 1e18;

    struct Settings {
        address source;
        /// The price that counts as on the peg, scaled by 1e18.
        uint256 pegWad;
        /// How far from the peg still counts as on it (WAD share of the peg).
        uint256 toleranceWad;
        /// How long the price must stay outside before a depeg is reported.
        uint256 window;
        /// The longest silence between readings before the clock starts over.
        uint256 maxGap;
    }

    Settings internal _settings;
    address public configurer;

    /// When the current unbroken run of outside readings began; zero if none.
    uint256 public outsideSince;
    uint256 public lastObserved;

    event Observed(uint256 priceWad, bool outside, uint256 outsideSince);
    event SettingsSet(Settings settings);
    event ConfigurerSet(address configurer);

    error NotAllowed();
    error BadSettings();

    constructor(Settings memory s, address configurer_) {
        configurer = configurer_;
        _set(s);
    }

    function settings() external view returns (Settings memory) {
        return _settings;
    }

    /// Whether a price is outside the tolerance.
    function isOutside(uint256 priceWad) public view returns (bool) {
        Settings storage s = _settings;
        uint256 off = priceWad > s.pegWad ? priceWad - s.pegWad : s.pegWad - priceWad;
        return off * WAD > s.toleranceWad * s.pegWad;
    }

    /// Take a reading. Anyone may call.
    function observe() external {
        uint256 reading = IPriceSource(_settings.source).priceWad();
        bool outside = isOutside(reading);
        if (!outside) {
            outsideSince = 0;
        } else if (outsideSince == 0 || block.timestamp - lastObserved > _settings.maxGap) {
            outsideSince = block.timestamp;
        }
        lastObserved = block.timestamp;
        emit Observed(reading, outside, outsideSince);
    }

    /// True when the price has been outside for the whole window, by readings
    /// close enough together, and is outside now.
    function depegged() external view returns (bool) {
        Settings storage s = _settings;
        uint256 since = outsideSince;
        if (since == 0 || block.timestamp - since < s.window) return false;
        if (block.timestamp - lastObserved > s.maxGap) return false;
        return isOutside(IPriceSource(s.source).priceWad());
    }

    function setSettings(Settings calldata s) external {
        if (msg.sender != configurer) revert NotAllowed();
        _set(s);
        outsideSince = 0;
    }

    function setConfigurer(address next) external {
        if (msg.sender != configurer) revert NotAllowed();
        configurer = next;
        emit ConfigurerSet(next);
    }

    function _set(Settings memory s) internal {
        if (s.source == address(0) || s.pegWad == 0 || s.window == 0 || s.maxGap == 0) revert BadSettings();
        _settings = s;
        emit SettingsSet(s);
    }
}
