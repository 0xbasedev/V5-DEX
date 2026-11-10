// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title TimelockedDeployer
/// @notice The only door through which later-written contracts can arrive
/// (spec v1.16 §18.8: "frozen v1 code, counted honestly").
///
/// A slot is a salt. Its address is fixed the moment this contract exists and
/// depends on nothing but this contract's address and the salt, so other
/// contracts can commit to it long before any code is written for it.
///
/// To fill a slot the key publishes the hash of the exact creation code,
/// constructor arguments included, and waits out the delay. Anyone can then
/// deploy that code and no other. A slot is filled once and never again.
///
/// A timelock cannot bind a plain key, which is why addresses are derived from
/// this contract and not from the key: the key can only ask, in public, and wait.
contract TimelockedDeployer {
    /// The longest timelock in the system.
    uint256 public immutable delay;
    /// After this moment a sunset-bound slot can no longer be filled.
    uint256 public immutable sunset;
    address public key;

    struct Slot {
        bytes32 creationHash; // what was published; zero when nothing is queued
        uint64 readyAt;
        uint64 liveSince; // zero until deployed
        bytes32 codeHash; // of the deployed code
        bool sunsetBound;
    }

    mapping(bytes32 => Slot) internal _slots;
    /// How many slots are queued and not yet deployed or cancelled.
    uint256 public queuedCount;

    event Queued(bytes32 indexed salt, bytes32 creationHash, uint256 readyAt);
    event Cancelled(bytes32 indexed salt);
    event Deployed(bytes32 indexed salt, address at, bytes32 codeHash);
    event KeySet(address key);

    error NotKey();
    error AlreadyFilled();
    error AlreadyQueued();
    error NotQueued();
    error TooEarly();
    error WrongCode();
    error PastSunset();

    /// `sunsetBound` lists the slots that must be filled before the sunset or not at all.
    constructor(uint256 delay_, uint256 sunset_, address key_, bytes32[] memory sunsetBound) {
        delay = delay_;
        sunset = sunset_;
        key = key_;
        for (uint256 i; i < sunsetBound.length; ++i) {
            _slots[sunsetBound[i]].sunsetBound = true;
        }
    }

    modifier onlyKey() {
        if (msg.sender != key) revert NotKey();
        _;
    }

    /// Where a slot's contract lives, or will live.
    function addressOf(bytes32 salt) public view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }

    function slot(bytes32 salt) external view returns (Slot memory) {
        return _slots[salt];
    }

    /// The hash of the code deployed in a slot; zero if it is empty.
    function codeHashOf(bytes32 salt) external view returns (bytes32) {
        return _slots[salt].codeHash;
    }

    function liveSinceOf(bytes32 salt) external view returns (uint256) {
        return _slots[salt].liveSince;
    }

    /// True while any deploy is waiting out its delay.
    function anyQueued() external view returns (bool) {
        return queuedCount != 0;
    }

    /// Publish the hash of the creation code for a slot and start its delay.
    function queue(bytes32 salt, bytes32 creationHash) external onlyKey {
        Slot storage s = _slots[salt];
        if (s.liveSince != 0) revert AlreadyFilled();
        if (s.creationHash != 0) revert AlreadyQueued();
        if (creationHash == 0) revert WrongCode();
        if (s.sunsetBound && block.timestamp + delay >= sunset) revert PastSunset();
        s.creationHash = creationHash;
        s.readyAt = uint64(block.timestamp + delay);
        ++queuedCount;
        emit Queued(salt, creationHash, s.readyAt);
    }

    function cancel(bytes32 salt) external onlyKey {
        Slot storage s = _slots[salt];
        if (s.creationHash == 0 || s.liveSince != 0) revert NotQueued();
        s.creationHash = 0;
        s.readyAt = 0;
        --queuedCount;
        emit Cancelled(salt);
    }

    /// Deploy the published code. Anyone may call once the delay has passed.
    function deploy(bytes32 salt, bytes calldata creationCode) external returns (address at) {
        Slot storage s = _slots[salt];
        if (s.creationHash == 0 || s.liveSince != 0) revert NotQueued();
        if (block.timestamp < s.readyAt) revert TooEarly();
        if (s.sunsetBound && block.timestamp >= sunset) revert PastSunset();
        if (keccak256(creationCode) != s.creationHash) revert WrongCode();
        at = CREATE3.deployDeterministic(creationCode, salt);
        s.liveSince = uint64(block.timestamp);
        s.codeHash = at.codehash;
        --queuedCount;
        emit Deployed(salt, at, s.codeHash);
    }

    function setKey(address next) external onlyKey {
        key = next;
        emit KeySet(next);
    }
}
