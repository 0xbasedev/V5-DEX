// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IDeployerForEscrow {
    function addressOf(bytes32 salt) external view returns (address);
    function codeHashOf(bytes32 salt) external view returns (bytes32);
    function liveSinceOf(bytes32 salt) external view returns (uint256);
    function anyQueued() external view returns (bool);
    function delay() external view returns (uint256);
    function sunset() external view returns (uint256);
}

interface IBankedPool {
    function recordBanked(uint256 amount) external;
    function settleClaims(uint256[] calldata ids) external;
    function claimWeight(address wallet) external view returns (uint256);
    function bankTotal() external view returns (uint256);
}

/// @title BankEscrow
/// @notice Holds the half of the pre-token buyback line that is banked for the
/// launch burn, one escrow per chain (spec v1.16 §18.8).
///
/// It does five things and nothing else:
///
///  1. Holds. Each pool's banked money is on a ledger, up to a cap per pool.
///  2. Releases, slowly, to one address: the outlet. That address is derived
///     from the timelocked deployer and is never a stored value. Nothing is
///     released until code exists there whose hash matches what the deployer
///     published, has been live for an epoch, and no other deploy is waiting.
///     Each epoch at most a fixed share of the ledger may go.
///  3. Pauses. Any one member of the pause set can stop releases. Unpausing
///     takes a threshold of members and a delay. A threshold can remove a
///     member at once, but not while a deploy is waiting.
///  4. Refunds. If no outlet exists by the sunset, or if releases stay paused
///     without a break for too long, what is left goes back to the pools it
///     came from. Each wallet's share is its deferred claim: its seasoned
///     weight over every epoch the money was banked, as the pool's hall records
///     it. A refund cannot be paused and, once open, closes the escrow for good.
///  5. Sits behind the freeze above.
///
/// There is no function that sends money anywhere else, and no way to change
/// the outlet, the asset or the deployer. The numeric limits can be changed by
/// the configurer for now; hand that role to the zero address to freeze them.
///
/// First cut. Not audited.
contract BankEscrow {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_MEMBERS = 16;

    address public immutable asset;
    IDeployerForEscrow public immutable deployer;
    bytes32 public immutable outletSalt;
    /// Where releases go. Fixed by the deployer's address and the salt.
    address public immutable outlet;
    uint256 public immutable epochLength;
    uint256 public immutable startTime;
    /// The deployer's sunset, copied so it can be read here.
    uint256 public immutable sunset;

    struct Limits {
        /// The most one pool may have on the ledger.
        uint256 poolCap;
        /// Share of the ledger that may be released per epoch (WAD). At most a half.
        uint256 releaseRateWad;
        /// A pause that lasts this long without a break opens the refund.
        uint256 stuckPeriod;
        /// How long an agreed unpause waits.
        uint256 unpauseDelay;
        /// Members needed to unpause or to remove a member.
        uint256 threshold;
        /// The pause set can never be smaller than this.
        uint256 memberFloor;
    }

    Limits internal _limits;
    address public configurer;

    // --- the ledger, kept as shares so a release touches every pool at once ---
    mapping(address => uint256) public unitsOf;
    uint256 public totalUnits;
    /// The asset on the ledger. The contract may hold more: stray transfers
    /// are counted in, in proportion, only if a refund opens.
    uint256 public ledger;
    uint256 public lastReleaseEpoch;
    uint256 public released;

    // --- the pause set ---
    address[] internal _members;
    mapping(address => bool) public isMember;
    /// When the current pause began; zero when not paused.
    uint256 public pausedSince;
    /// When an agreed unpause may be carried out; zero when none is agreed.
    uint256 public unpauseReadyAt;
    uint256 internal _unpauseRound;
    mapping(address => uint256) internal _removalRound;
    mapping(bytes32 => mapping(address => bool)) internal _voted;

    // --- the refund ---
    bool public refundOpen;
    /// What was on the ledger when the refund opened.
    uint256 public refundPot;
    mapping(address => uint256) public refundedToPool;
    mapping(address => mapping(address => uint256)) public refundedTo;

    event Banked(address indexed pool, uint256 amount);
    event Released(uint256 amount, uint256 epoch);
    event PausedBy(address indexed member);
    event UnpauseAgreed(uint256 readyAt);
    event Unpaused();
    event MemberRemoved(address indexed member);
    event RefundOpened(uint256 pot, bool bySunset);
    event Refunded(address indexed pool, address indexed wallet, uint256 amount);
    event LimitsSet(Limits limits);
    event ConfigurerSet(address configurer);

    error NotAllowed();
    error BadLimits();
    error Closed();
    error OverCap();
    error NotReady();
    error IsPaused();
    error NotPaused();
    error TooEarly();
    error DeployWaiting();
    error BelowFloor();
    error NoRefund();

    constructor(
        address asset_,
        IDeployerForEscrow deployer_,
        bytes32 outletSalt_,
        uint256 epochLength_,
        Limits memory l,
        address[] memory members_,
        address configurer_
    ) {
        if (asset_ == address(0) || epochLength_ == 0 || members_.length > MAX_MEMBERS) {
            revert BadLimits();
        }
        asset = asset_;
        deployer = deployer_;
        outletSalt = outletSalt_;
        outlet = deployer_.addressOf(outletSalt_);
        sunset = deployer_.sunset();
        epochLength = epochLength_;
        startTime = block.timestamp;
        configurer = configurer_;
        for (uint256 i; i < members_.length; ++i) {
            if (members_[i] == address(0) || isMember[members_[i]]) revert BadLimits();
            isMember[members_[i]] = true;
            _members.push(members_[i]);
        }
        _setLimits(l);
    }

    // ------------------------------------------------------------------
    // Reading
    // ------------------------------------------------------------------

    function limits() external view returns (Limits memory) {
        return _limits;
    }

    function members() external view returns (address[] memory) {
        return _members;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - startTime) / epochLength;
    }

    /// What a pool has on the ledger now.
    function ledgerOf(address pool) public view returns (uint256) {
        uint256 total = totalUnits;
        return total == 0 ? 0 : unitsOf[pool] * ledger / total;
    }

    /// How much more a pool may bank.
    function room(address pool) public view returns (uint256) {
        if (refundOpen) return 0;
        uint256 held = ledgerOf(pool);
        uint256 cap = _limits.poolCap;
        return held >= cap ? 0 : cap - held;
    }

    /// True when the outlet may be paid: the published code is at its address,
    /// has been live for a full epoch, and no other deploy is waiting.
    function outletReady() public view returns (bool) {
        bytes32 published = deployer.codeHashOf(outletSalt);
        if (published == bytes32(0) || outlet.codehash != published) return false;
        if (block.timestamp < deployer.liveSinceOf(outletSalt) + epochLength) return false;
        return !deployer.anyQueued();
    }

    /// True when a pause has lasted long enough, without a break, to open the refund.
    function stuck() public view returns (bool) {
        return pausedSince != 0 && block.timestamp - pausedSince >= _limits.stuckPeriod;
    }

    // ------------------------------------------------------------------
    // 1. Hold
    // ------------------------------------------------------------------

    /// Bank `amount` of the asset for `pool`. The pool's hall records it, so
    /// that the LPs seasoned in this epoch earn the claim on it.
    function bank(address pool, uint256 amount) external {
        if (refundOpen) revert Closed();
        if (amount == 0 || amount > room(pool)) revert OverCap();
        uint256 total = totalUnits;
        uint256 units = total == 0 ? amount : amount * total / ledger;
        if (units == 0) revert OverCap();
        unitsOf[pool] += units;
        totalUnits = total + units;
        ledger += amount;
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), amount);
        IBankedPool(pool).recordBanked(amount);
        emit Banked(pool, amount);
    }

    /// Anything sent here outside `bank` joins the ledger in proportion. This
    /// is done only when the refund opens, never while money can still be
    /// banked: counting a stray transfer mid-life would let a first depositor
    /// dilute everyone who banks after it.
    function _absorbStray() internal {
        if (totalUnits == 0) return;
        uint256 held = SafeTransferLib.balanceOf(asset, address(this));
        if (held > ledger) ledger = held;
    }

    // ------------------------------------------------------------------
    // 2. Release
    // ------------------------------------------------------------------

    /// Send this epoch's share of the ledger to the outlet. Anyone may call.
    function release() external returns (uint256 amount) {
        if (refundOpen) revert Closed();
        if (pausedSince != 0) revert IsPaused();
        if (!outletReady()) revert NotReady();
        uint256 e = currentEpoch();
        if (e <= lastReleaseEpoch) revert TooEarly();
        amount = ledger * _limits.releaseRateWad / WAD;
        lastReleaseEpoch = e;
        ledger -= amount;
        released += amount;
        if (amount != 0) SafeTransferLib.safeTransfer(asset, outlet, amount);
        emit Released(amount, e);
    }

    // ------------------------------------------------------------------
    // 3. Pause
    // ------------------------------------------------------------------

    /// Stop releases. Any single member may do this.
    function pause() external {
        if (!isMember[msg.sender]) revert NotAllowed();
        if (pausedSince != 0) return;
        pausedSince = block.timestamp;
        emit PausedBy(msg.sender);
    }

    /// Agree to lift the current pause. Once enough members agree, the delay starts.
    function voteUnpause() external {
        if (!isMember[msg.sender]) revert NotAllowed();
        if (pausedSince == 0) revert NotPaused();
        bytes32 matter = keccak256(abi.encode("unpause", _unpauseRound));
        _voted[matter][msg.sender] = true;
        if (unpauseReadyAt == 0 && _count(matter) >= _limits.threshold) {
            unpauseReadyAt = block.timestamp + _limits.unpauseDelay;
            emit UnpauseAgreed(unpauseReadyAt);
        }
    }

    /// Carry out an agreed unpause once its delay has passed. Anyone may call.
    function unpause() external {
        if (pausedSince == 0) revert NotPaused();
        if (unpauseReadyAt == 0 || block.timestamp < unpauseReadyAt) revert TooEarly();
        pausedSince = 0;
        unpauseReadyAt = 0;
        ++_unpauseRound;
        emit Unpaused();
    }

    /// Agree to remove a member. With enough votes it happens at once. Not
    /// while a deploy is waiting: a captured majority must not be able to strip
    /// the honest pausers just before a bad contract lands.
    function voteRemove(address member) external {
        if (!isMember[msg.sender] || !isMember[member]) revert NotAllowed();
        if (deployer.anyQueued()) revert DeployWaiting();
        bytes32 matter = keccak256(abi.encode("remove", member, _removalRound[member]));
        _voted[matter][msg.sender] = true;
        if (_count(matter) < _limits.threshold) return;
        if (_members.length - 1 < _limits.memberFloor) revert BelowFloor();
        isMember[member] = false;
        ++_removalRound[member];
        uint256 n = _members.length;
        for (uint256 i; i < n; ++i) {
            if (_members[i] == member) {
                _members[i] = _members[n - 1];
                _members.pop();
                break;
            }
        }
        emit MemberRemoved(member);
    }

    /// Votes on a matter from those who are members now.
    function _count(bytes32 matter) internal view returns (uint256 n) {
        uint256 len = _members.length;
        for (uint256 i; i < len; ++i) {
            if (_voted[matter][_members[i]]) ++n;
        }
    }

    // ------------------------------------------------------------------
    // 4. Refund
    // ------------------------------------------------------------------

    /// Open the refund. Anyone may call, paused or not, once either trigger holds:
    /// the sunset has passed with no outlet deployed, or the pause is stuck.
    function openRefund() external {
        if (refundOpen) revert Closed();
        bool bySunset = block.timestamp >= sunset && deployer.codeHashOf(outletSalt) == bytes32(0);
        if (!bySunset && !stuck()) revert NoRefund();
        _absorbStray();
        refundOpen = true;
        refundPot = ledger;
        emit RefundOpened(refundPot, bySunset);
    }

    /// A pool's share of the refund.
    function refundOf(address pool) public view returns (uint256) {
        uint256 total = totalUnits;
        return total == 0 ? 0 : unitsOf[pool] * refundPot / total;
    }

    /// Collect the caller's share of a pool's refund. `ids` are the caller's
    /// open positions in that pool, so that their claims are brought up to date
    /// first. It can be called again as later epochs settle.
    function claimRefund(address pool, uint256[] calldata ids) external returns (uint256 amount) {
        if (!refundOpen) revert NoRefund();
        IBankedPool p = IBankedPool(pool);
        p.settleClaims(ids);
        uint256 banked = p.bankTotal();
        if (banked == 0) return 0;
        uint256 pot = refundOf(pool);
        uint256 due = pot * p.claimWeight(msg.sender) / banked;
        uint256 already = refundedTo[pool][msg.sender];
        if (due <= already) return 0;
        amount = due - already;
        // A pool can only ever hand out its own share, whatever it reports.
        if (refundedToPool[pool] + amount > pot) amount = pot - refundedToPool[pool];
        refundedTo[pool][msg.sender] = already + amount;
        refundedToPool[pool] += amount;
        if (amount != 0) SafeTransferLib.safeTransfer(asset, msg.sender, amount);
        emit Refunded(pool, msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Settings
    // ------------------------------------------------------------------

    function setLimits(Limits calldata l) external {
        if (msg.sender != configurer) revert NotAllowed();
        _setLimits(l);
    }

    function setConfigurer(address next) external {
        if (msg.sender != configurer) revert NotAllowed();
        configurer = next;
        emit ConfigurerSet(next);
    }

    function _setLimits(Limits memory l) internal {
        if (
            l.releaseRateWad > WAD / 2 || l.threshold == 0 || l.memberFloor < l.threshold
                || _members.length < l.memberFloor
                // A rogue member can hold a pause for a whole deploy delay, so the
                // stuck-pause refund has to take longer than that plus an unpause.
                || l.stuckPeriod <= deployer.delay() + l.unpauseDelay
        ) revert BadLimits();
        _limits = l;
        emit LimitsSet(l);
    }
}
