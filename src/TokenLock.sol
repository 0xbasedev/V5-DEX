// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EpochHall} from "./EpochHall.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title TokenLock
/// @notice Locking the venue's token for a share of fees and a vote
/// (spec v1.16 §4, §5: "the ve room").
///
/// It is an Epoch Hall whose stake is the token itself. A lock is a hard-tier
/// position:
///
///  - The holder picks a length. Weight is the amount locked times the length
///    chosen over the longest allowed: a longer lock earns and votes more.
///  - Fees paid in are shared by weight each epoch, in the venue's stable and
///    in the token.
///  - Leaving early is allowed, at a cost that melts to zero over the lock.
///    Part of that cost is burned; the rest goes to the lockers who stayed.
///  - A lock that has run its term keeps its weight until it is closed, so
///    anyone may close an expired lock for its owner. It cannot vote meanwhile.
///
/// Nothing here mints. Every payment is a fee that was paid in or a toll that
/// someone else paid.
///
/// Settings are changeable by the configurer and frozen by handing that role
/// to the zero address; a lock keeps the terms it was opened under. First cut.
/// Not audited.
contract TokenLock is EpochHall {
    /// Fee stream 0 is the stable, stream 1 is the token.
    address public immutable stable;
    address public immutable token;
    /// Where the burned share of exit costs goes: the Burn Vault.
    address public immutable burnSink;

    /// The shortest and longest lock, in epochs.
    uint256 public minLock;
    uint256 public maxLock;
    address public configurer;

    /// Tokens locked in each position. The hall's `shares` are these scaled by lock length.
    mapping(uint256 => uint256) public lockedOf;
    uint256 public totalLocked;
    /// Fees and tolls held for lockers, per stream.
    uint256[2] public held;

    uint256 private _guard = 1;

    event Locked(uint256 indexed id, address indexed owner, uint256 amount, uint256 epochs);
    event Unlocked(uint256 indexed id, address indexed owner, uint256 returned, uint256 burned, uint256 toStayers);
    event FeesAdded(uint256 stableAmount, uint256 tokenAmount);

    error NotAllowed();
    error BadLength();
    error StillLocked();
    error Reentered();

    constructor(
        address stable_,
        address token_,
        address burnSink_,
        uint256 epochLength_,
        HallConfig memory c,
        uint256 minLock_,
        uint256 maxLock_,
        address configurer_
    ) EpochHall(epochLength_, c) {
        if (minLock_ == 0 || maxLock_ < minLock_ || maxLock_ > MAX_EPOCHS || !c.lockSkipsRamp) {
            revert BadConfig();
        }
        stable = stable_;
        token = token_;
        burnSink = burnSink_;
        minLock = minLock_;
        maxLock = maxLock_;
        configurer = configurer_;
    }

    modifier guarded() {
        if (_guard != 1) revert Reentered();
        _guard = 2;
        _;
        _guard = 1;
    }

    /// Lock `amount` of the token for `epochs`.
    function lock(uint256 amount, uint256 epochs, address to) external guarded returns (uint256 id) {
        if (epochs < minLock || epochs > maxLock || amount == 0) revert BadLength();
        _current();
        id = _openForTerm(to, amount * epochs / maxLock, HARD, epochs);
        lockedOf[id] = amount;
        totalLocked += amount;
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        emit Locked(id, to, amount, epochs);
    }

    /// Leave. Free once the lock has run; before that, at the cost shown by `exitCostOf`.
    function unlock(uint256 id) external guarded returns (uint256 returned) {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _current();
        returned = _release(id);
    }

    /// Close a lock that has run its term, for its owner. Anyone may call.
    function kick(uint256 id) external guarded {
        _current();
        if (epoch < _positions[id].lockEnd) revert StillLocked();
        _release(id);
    }

    function _release(uint256 id) internal returns (uint256 returned) {
        uint256 amount = lockedOf[id];
        (address owner, uint256 shares, uint256 tollShares) = _close(id, false);
        delete lockedOf[id];
        totalLocked -= amount;
        uint256 cost = amount * tollShares / shares;
        returned = amount - cost;
        uint256 burned = cost * _hallConfig.tollPolShareWad / WAD;
        uint256 toStayers = cost - burned;
        // The rest goes to the lockers who stayed. If nobody did, it is burned too.
        if (toStayers != 0) {
            if (_payLockers(1, toStayers)) held[1] += toStayers;
            else (burned, toStayers) = (cost, 0);
        }
        SafeTransferLib.safeTransfer(token, owner, returned);
        if (burned != 0) SafeTransferLib.safeTransfer(token, burnSink, burned);
        emit Unlocked(id, owner, returned, burned, toStayers);
    }

    /// What leaving now would cost a lock, in tokens.
    function exitCostOf(uint256 id) external view returns (uint256) {
        uint256 shares = _positions[id].shares;
        return shares == 0 ? 0 : lockedOf[id] * _toll(_positions[id]) / shares;
    }

    /// A lock's vote: its weight while the lock runs, nothing once it has ended.
    function votingWeight(uint256 id) external view returns (uint256) {
        return currentEpoch() < _positions[id].lockEnd ? _weight(_positions[id], epoch) : 0;
    }

    /// When a lock ends, as a time.
    function lockedUntil(uint256 id) external view returns (uint256) {
        return startTime + uint256(_positions[id].lockEnd) * epochLength;
    }

    /// Locks cannot be merged: each has its own amount, length and end.
    function merge(uint256, uint256) external pure override returns (uint256) {
        revert NotAllowed();
    }

    /// Collect a lock's share of fees and tolls.
    function collect(uint256 id) external guarded returns (uint256[2] memory) {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _current();
        return _collect(id);
    }

    /// Pay fees in for the lockers: the venue's share, or anything else.
    function addFees(uint256 stableAmount, uint256 tokenAmount) external guarded {
        _current();
        pending[0] += stableAmount;
        pending[1] += tokenAmount;
        held[0] += stableAmount;
        held[1] += tokenAmount;
        if (stableAmount != 0) SafeTransferLib.safeTransferFrom(stable, msg.sender, address(this), stableAmount);
        if (tokenAmount != 0) SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), tokenAmount);
        emit FeesAdded(stableAmount, tokenAmount);
    }

    function _payFee(uint256 k, address to, uint256 amount) internal override {
        held[k] -= amount;
        SafeTransferLib.safeTransfer(k == 0 ? stable : token, to, amount);
    }

    /// A lock starts fully seasoned, so nothing is ever held back to forfeit.
    function _creditPol(uint256 k, uint256 amount) internal override {
        held[k] -= amount;
        SafeTransferLib.safeTransfer(k == 0 ? stable : token, burnSink, amount);
    }

    function setLockLengths(uint256 minLock_, uint256 maxLock_) external {
        if (msg.sender != configurer) revert NotAllowed();
        // The longest lock cannot change: open locks' weights are measured against it.
        if (minLock_ == 0 || maxLock_ != maxLock || minLock_ > maxLock_) revert BadConfig();
        minLock = minLock_;
    }

    function setHallConfig(HallConfig calldata c) external {
        if (msg.sender != configurer || !c.lockSkipsRamp) revert NotAllowed();
        _setHallConfig(c);
    }

    function setConfigurer(address next) external {
        if (msg.sender != configurer) revert NotAllowed();
        configurer = next;
    }
}
