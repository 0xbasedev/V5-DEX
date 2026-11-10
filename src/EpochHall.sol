// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title EpochHall
/// @notice Seasoned-position bookkeeping for a V5 pool (spec v1.16 §3, §18.3, §18.9).
///
/// A position's fee weight rises on a straight line from a floor to full weight
/// over a horizon counted in whole epochs. Fees arriving in an epoch are shared
/// by weight when the epoch closes. Fees earned while a position seasons are
/// held and unlock on the same line; leaving early forfeits what is still held.
///
/// Settlement is constant-time. The hall keeps two running sums per fee token,
///   A = sum over epochs of (fees / total weight)
///   B = sum over epochs of (epoch * fees / total weight)
/// and a position's earnings over any span follow from differences of A and B.
/// Total weight moves by a per-epoch slope with scheduled reductions as
/// positions mature. `sim/hall.py` is the reference; `test/EpochHall.t.sol`
/// checks this contract against a brute-force calculation.
///
/// Every setting can be changed, and a change only ever applies to positions
/// opened after it: each position carries the terms it was opened under. So
/// no change can raise the cost of leaving for someone already in.
///
/// First cut. Not here yet: deferred claims on the banked half, an ERC-721
/// surface. Not audited.
abstract contract EpochHall {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOKENS = 2;
    /// Horizon and lock term are capped so that epoch arithmetic fits its storage with room to spare.
    uint256 internal constant MAX_EPOCHS = 1 << 20;

    uint8 public constant SOFT = 0;
    uint8 public constant HARD = 1;

    /// Seconds per epoch, and the time epoch 0 began. These two cannot change.
    uint256 public immutable epochLength;
    uint256 public immutable startTime;

    struct HallConfig {
        /// Weight of a brand-new position as a share of full weight (WAD).
        uint256 floorWad;
        /// Epochs to full weight.
        uint256 horizon;
        /// Share of earned fees unlocked at age zero (WAD). 1e18 switches the fee hold off.
        uint256 unlockedAtZeroWad;
        /// Share of forfeited fees that goes to protocol-owned liquidity (WAD); the rest goes to the LPs who stay.
        uint256 polShareWad;
        /// Hard tier: epochs locked. 0 switches the tier off.
        uint256 lockTerm;
        /// Hard tier: cost of leaving on the first day, as a share of principal (WAD).
        uint256 lockExitWad;
        /// Hard tier: how far that cost melts within the term. 0 melts to nothing, 1e18 never melts.
        uint256 lockMeltFloorWad;
        /// Hard tier: a locked position starts with full weight and no fee hold.
        bool lockSkipsRamp;
        /// Share of a lock's exit toll that goes to protocol-owned liquidity (WAD); the rest goes to locked LPs.
        uint256 tollPolShareWad;
    }

    HallConfig internal _hallConfig;

    struct Position {
        address owner;
        uint8 tier;
        int64 start; // epoch the position's age is counted from
        uint64 settledTo; // earnings are settled for every epoch before this one
        uint64 lockEnd; // hard tier: first epoch it may leave free
        uint64 tollWad; // hard tier: exit cost written in when the position opened
        uint64 unlockedAtZeroWad; // the terms it opened under, from here down
        uint32 horizon;
        uint32 lockTerm;
        uint64 meltFloorWad;
        uint128 shares;
        uint128 baseWeight; // weight at age zero
        uint128 weightPerEpoch; // added each epoch until the horizon
        uint256[2] earned; // fees earned over the position's life
        uint256[2] paid; // fees already paid out
        uint256[2] tollMark; // where the lockers' toll sums stood when last settled
        uint256[2] tollOwed; // its share of tolls paid to lockers, not yet collected
    }

    struct Checkpoint {
        uint256[2] a;
        uint256[2] b;
    }

    mapping(uint256 => Position) internal _positions;
    uint256 public nextPositionId = 1;

    /// The epoch the hall's books are current to.
    uint64 public epoch;
    uint256 public totalWeight;
    /// How much total weight grows at each epoch boundary.
    uint256 public slope;
    /// Slope that stops at a given epoch, because positions mature there.
    mapping(uint256 => uint256) public slopeEnding;

    /// Fees that arrived during the current epoch, per token.
    uint256[2] public pending;

    /// Shares held in the hard tier, and what has been paid to them per share (WAD-scaled).
    uint256 public lockedShares;
    uint256[2] internal _tollPerLockedShare;

    uint256[2] internal _a;
    uint256[2] internal _b;
    /// Epochs at which the running sums changed, and their values from then on.
    uint64[] internal _checkpointEpochs;
    mapping(uint256 => Checkpoint) internal _checkpoints;

    event HallConfigSet(HallConfig config);
    event Opened(uint256 indexed id, address indexed owner, uint256 shares, uint8 tier);
    event Closed(uint256 indexed id, address indexed owner, uint256 shares, uint256 tollShares);
    event Paid(uint256 indexed id, address indexed to, uint256 amount0, uint256 amount1);
    event Forfeited(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Moved(uint256 indexed id, address indexed from, address indexed to);
    event Merged(uint256 indexed a, uint256 indexed b, uint256 indexed into);
    event Compounded(uint256 indexed id, uint256 used0, uint256 used1, uint256 shares);

    error NotOwner();
    error NoSuchPosition();
    error NotMature();
    error TierUnavailable();
    error BadConfig();

    constructor(uint256 epochLength_, HallConfig memory c) {
        if (epochLength_ == 0) revert BadConfig();
        epochLength = epochLength_;
        startTime = block.timestamp;
        _setHallConfig(c);
    }

    function hallConfig() external view returns (HallConfig memory) {
        return _hallConfig;
    }

    function _setHallConfig(HallConfig memory c) internal {
        if (
            c.horizon == 0 || c.horizon > MAX_EPOCHS || c.lockTerm > MAX_EPOCHS || c.floorWad > WAD
                || c.unlockedAtZeroWad > WAD || c.polShareWad > WAD || c.lockExitWad > WAD || c.lockMeltFloorWad > WAD
                || c.tollPolShareWad > WAD
        ) revert BadConfig();
        _hallConfig = c;
        emit HallConfigSet(c);
    }

    // ------------------------------------------------------------------
    // Hooks the pool supplies
    // ------------------------------------------------------------------

    /// Pay `amount` of fee token `token` to `to`.
    function _payFee(uint256 token, address to, uint256 amount) internal virtual;

    /// Credit `amount` of fee token `token` to protocol-owned liquidity.
    function _creditPol(uint256 token, uint256 amount) internal virtual;

    // ------------------------------------------------------------------
    // Time
    // ------------------------------------------------------------------

    function currentEpoch() public view returns (uint64) {
        return uint64((block.timestamp - startTime) / epochLength);
    }

    /// Bring the books up to the present. Anyone may call it. `maxEpochs`
    /// bounds the work, so a pool left idle for a long time can be caught up
    /// over several calls.
    function poke(uint256 maxEpochs) public {
        uint64 target = currentEpoch();
        uint64 e = epoch;
        if (e >= target) return;

        uint256 weight = totalWeight;
        // Fees that arrived in epoch `e` are shared by the weights of epoch `e`.
        if (weight != 0) {
            bool changed;
            for (uint256 k; k < TOKENS; ++k) {
                uint256 amount = pending[k];
                if (amount == 0) continue;
                uint256 perWeight = amount * WAD / weight;
                if (perWeight == 0) continue;
                _a[k] += perWeight;
                _b[k] += perWeight * e;
                // Take what was shared out of `pending`, rounded up. Positions are paid the
                // exact figure rounded down, so the hall can never owe more than it holds.
                // What rounding leaves behind waits for the next epoch.
                pending[k] = amount - (perWeight * weight + WAD - 1) / WAD;
                changed = true;
            }
            if (changed) {
                Checkpoint storage c = _checkpoints[uint256(e) + 1];
                c.a = _a;
                c.b = _b;
                _checkpointEpochs.push(e + 1);
            }
        }

        uint256 s = slope;
        while (e < target && maxEpochs != 0) {
            weight += s;
            ++e;
            --maxEpochs;
            uint256 ending = slopeEnding[e];
            if (ending != 0) {
                s -= ending;
                delete slopeEnding[e];
            }
        }
        totalWeight = weight;
        slope = s;
        epoch = e;
    }

    function _current() internal {
        poke(type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Reading
    // ------------------------------------------------------------------

    function positionOf(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function ownerOf(uint256 id) public view returns (address) {
        return _positions[id].owner;
    }

    /// A position's weight in the hall's current epoch.
    function weightOf(uint256 id) public view returns (uint256) {
        return _weight(_positions[id], epoch);
    }

    /// What a position could collect now, as of the hall's current epoch.
    function unlockedOf(uint256 id) external view returns (uint256[2] memory out) {
        Position storage p = _positions[id];
        if (p.owner == address(0)) return out;
        uint256 fraction = _unlockedFraction(p);
        for (uint256 k; k < TOKENS; ++k) {
            uint256 earned = p.earned[k] + _span(p, p.settledTo, epoch, k);
            out[k] = earned * fraction / WAD - p.paid[k] + p.tollOwed[k] + _tollSince(p, k);
        }
    }

    /// Exit cost for a hard-locked position, in shares, in the current epoch.
    function tollOf(uint256 id) public view returns (uint256) {
        return _toll(_positions[id]);
    }

    function _age(Position storage p, uint64 at) internal view returns (uint256) {
        uint256 age = uint256(int256(uint256(at)) - int256(p.start));
        return age < p.horizon ? age : p.horizon;
    }

    function _weight(Position storage p, uint64 at) internal view returns (uint256) {
        return uint256(p.baseWeight) + uint256(p.weightPerEpoch) * _age(p, at);
    }

    function _unlockedFraction(Position storage p) internal view returns (uint256) {
        return uint256(p.unlockedAtZeroWad) + (WAD - p.unlockedAtZeroWad) * _age(p, epoch) / p.horizon;
    }

    function _toll(Position storage p) internal view returns (uint256) {
        if (p.tier != HARD || epoch >= p.lockEnd) return 0;
        // Melts in a straight line over the term, down to the floor the position opened with.
        uint256 left = uint256(p.lockEnd - epoch) * WAD / p.lockTerm;
        if (left < p.meltFloorWad) left = p.meltFloorWad;
        return uint256(p.shares) * p.tollWad / WAD * left / WAD;
    }

    function _tollSince(Position storage p, uint256 k) internal view returns (uint256) {
        if (p.tier != HARD) return 0;
        return uint256(p.shares) * (_tollPerLockedShare[k] - p.tollMark[k]) / WAD;
    }

    /// The running sums as they stood before epoch `e`.
    function _sumsBefore(uint256 e, uint256 token) internal view returns (uint256 a, uint256 b) {
        uint256 lo;
        uint256 hi = _checkpointEpochs.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_checkpointEpochs[mid] <= e) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return (0, 0);
        Checkpoint storage c = _checkpoints[_checkpointEpochs[lo - 1]];
        return (c.a[token], c.b[token]);
    }

    /// What a position earned over epochs [from, to).
    function _span(Position storage p, uint64 from, uint64 to, uint256 token) internal view returns (uint256) {
        if (to <= from) return 0;
        int256 matures = int256(p.start) + int256(uint256(p.horizon));
        uint256 scaled;

        // Still ramping: weight = base + perEpoch * (epoch - start).
        uint256 rampEnd = matures < int256(uint256(to)) ? (matures > 0 ? uint256(matures) : 0) : to;
        if (rampEnd > from) {
            (uint256 a0, uint256 b0) = _sumsBefore(from, token);
            (uint256 a1, uint256 b1) = _sumsBefore(rampEnd, token);
            uint256 da = a1 - a0;
            // Here start >= 0, because only positions opened unseasoned ever ramp.
            scaled += uint256(p.baseWeight) * da + uint256(p.weightPerEpoch)
            * ((b1 - b0) - uint256(int256(p.start)) * da);
        }

        // Mature: full weight.
        uint256 flatStart = matures > int256(uint256(from)) ? uint256(matures) : from;
        if (to > flatStart) {
            (uint256 a0,) = _sumsBefore(flatStart, token);
            (uint256 a1,) = _sumsBefore(to, token);
            scaled += (uint256(p.baseWeight) + uint256(p.weightPerEpoch) * p.horizon) * (a1 - a0);
        }
        return scaled / WAD;
    }

    // ------------------------------------------------------------------
    // Positions
    // ------------------------------------------------------------------

    function _settle(Position storage p) internal {
        uint64 e = epoch;
        bool hard = p.tier == HARD;
        for (uint256 k; k < TOKENS; ++k) {
            if (p.settledTo != e) p.earned[k] += _span(p, p.settledTo, e, k);
            if (hard) {
                p.tollOwed[k] += _tollSince(p, k);
                p.tollMark[k] = _tollPerLockedShare[k];
            }
        }
        p.settledTo = e;
    }

    function _addWeight(Position storage p) internal {
        uint64 e = epoch;
        totalWeight += _weight(p, e);
        int256 matures = int256(p.start) + int256(uint256(p.horizon));
        if (matures > int256(uint256(e)) && p.weightPerEpoch != 0) {
            slope += p.weightPerEpoch;
            slopeEnding[uint256(matures)] += p.weightPerEpoch;
        }
    }

    function _removeWeight(Position storage p) internal {
        uint64 e = epoch;
        totalWeight -= _weight(p, e);
        int256 matures = int256(p.start) + int256(uint256(p.horizon));
        if (matures > int256(uint256(e)) && p.weightPerEpoch != 0) {
            slope -= p.weightPerEpoch;
            slopeEnding[uint256(matures)] -= p.weightPerEpoch;
        }
    }

    /// Open a position under today's settings. The books must be current.
    function _open(address owner, uint256 shares, uint8 tier) internal returns (uint256 id) {
        HallConfig memory c = _hallConfig;
        if (tier > HARD || (tier == HARD && c.lockTerm == 0)) revert TierUnavailable();
        if (shares > type(uint128).max) revert BadConfig();
        id = nextPositionId++;
        Position storage p = _positions[id];
        uint64 e = epoch;
        p.owner = owner;
        p.tier = tier;
        p.shares = uint128(shares);
        p.settledTo = e;
        p.horizon = uint32(c.horizon);
        p.unlockedAtZeroWad = uint64(c.unlockedAtZeroWad);
        // The weight a position reaches is base + perEpoch * horizon, which can
        // fall a few wei short of its shares. Rounding is always against the position.
        uint256 base = shares * c.floorWad / WAD;
        p.baseWeight = uint128(base);
        p.weightPerEpoch = uint128((shares - base) / c.horizon);
        p.start = int64(uint64(e));
        if (tier == HARD) {
            p.lockEnd = e + uint64(c.lockTerm);
            p.lockTerm = uint32(c.lockTerm);
            p.tollWad = uint64(c.lockExitWad);
            p.meltFloorWad = uint64(c.lockMeltFloorWad);
            if (c.lockSkipsRamp) p.start = int64(uint64(e)) - int64(uint64(c.horizon));
            p.tollMark = _tollPerLockedShare;
            lockedShares += shares;
        }
        _addWeight(p);
        emit Opened(id, owner, shares, tier);
    }

    /// Pay a position's unlocked fees, and its share of lockers' tolls, to its owner.
    function _collect(uint256 id) internal returns (uint256[2] memory out) {
        Position storage p = _positions[id];
        if (p.owner == address(0)) revert NoSuchPosition();
        _settle(p);
        uint256 fraction = _unlockedFraction(p);
        for (uint256 k; k < TOKENS; ++k) {
            uint256 fees = p.earned[k] * fraction / WAD - p.paid[k];
            p.paid[k] += fees;
            out[k] = fees + p.tollOwed[k];
            p.tollOwed[k] = 0;
            if (out[k] != 0) _payFee(k, p.owner, out[k]);
        }
        emit Paid(id, p.owner, out[0], out[1]);
    }

    /// Close a position. Unlocked fees are paid; fees still held are forfeited,
    /// a share to protocol-owned liquidity and the rest to the positions that
    /// stay. When `waived` is set (a pause, a depeg window) nothing is forfeited
    /// and no toll is due. Returns the shares and the toll, both for the pool to settle.
    function _close(uint256 id, bool waived) internal returns (address owner, uint256 shares, uint256 tollShares) {
        Position storage p = _positions[id];
        owner = p.owner;
        if (owner == address(0)) revert NoSuchPosition();
        _collect(id);
        shares = p.shares;
        tollShares = waived ? 0 : _toll(p);
        _removeWeight(p); // before forfeits are added, so the leaver gets none of them
        if (p.tier == HARD) lockedShares -= shares; // and none of its own toll

        uint256[2] memory lost;
        uint256 polShare = _hallConfig.polShareWad;
        for (uint256 k; k < TOKENS; ++k) {
            uint256 held = p.earned[k] - p.paid[k];
            if (held == 0) continue;
            if (waived) {
                _payFee(k, owner, held);
            } else {
                lost[k] = held;
                uint256 toPol = held * polShare / WAD;
                if (toPol != 0) _creditPol(k, toPol);
                pending[k] += held - toPol;
            }
        }
        if (lost[0] != 0 || lost[1] != 0) emit Forfeited(id, lost[0], lost[1]);
        emit Closed(id, owner, shares, tollShares);
        delete _positions[id];
    }

    /// What a position could take out now, token by token. Settles it first.
    function _available(Position storage p) internal returns (uint256[2] memory out) {
        _settle(p);
        uint256 fraction = _unlockedFraction(p);
        for (uint256 k; k < TOKENS; ++k) {
            out[k] = p.earned[k] * fraction / WAD - p.paid[k] + p.tollOwed[k];
        }
    }

    /// Mark `amount` of a position's available fees as used, without paying it out.
    function _spend(Position storage p, uint256 k, uint256 amount) internal {
        uint256 fromTolls = amount < p.tollOwed[k] ? amount : p.tollOwed[k];
        p.tollOwed[k] -= fromTolls;
        p.paid[k] += amount - fromTolls;
    }

    /// Add shares to a position at its current age: its weight grows in
    /// proportion and its seasoning, its lock and its terms are untouched
    /// (spec §18.9). Only for fees the hall itself has just released.
    function _grow(Position storage p, uint256 added) internal {
        _removeWeight(p);
        uint256 shares = p.shares;
        if (shares + added > type(uint128).max) revert BadConfig();
        p.baseWeight += uint128(uint256(p.baseWeight) * added / shares);
        p.weightPerEpoch += uint128(uint256(p.weightPerEpoch) * added / shares);
        p.shares = uint128(shares + added);
        if (p.tier == HARD) lockedShares += added;
        _addWeight(p);
    }

    /// Share `amount` of fee token `k` among locked positions, by size. Returns
    /// false, and does nothing, when nobody is locked.
    function _payLockers(uint256 k, uint256 amount) internal returns (bool) {
        uint256 locked = lockedShares;
        if (locked == 0 || amount == 0) return false;
        _tollPerLockedShare[k] += amount * WAD / locked;
        return true;
    }

    /// Hand a position to someone else. Its age, its lock and what it holds
    /// travel with it (spec §18.9).
    function transferPosition(uint256 id, address to) external {
        Position storage p = _positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (to == address(0)) revert BadConfig();
        _current();
        _settle(p);
        p.owner = to;
        emit Moved(id, msg.sender, to);
    }

    /// Merge two of the caller's positions that are both fully seasoned and
    /// past any lock (spec §18.9). The result is an unlocked, mature position.
    function merge(uint256 a, uint256 b) external returns (uint256 id) {
        _current();
        Position storage pa = _positions[a];
        Position storage pb = _positions[b];
        if (pa.owner != msg.sender || pb.owner != msg.sender || a == b) revert NotOwner();
        uint64 e = epoch;
        if (_age(pa, e) < pa.horizon || _age(pb, e) < pb.horizon || e < pa.lockEnd || e < pb.lockEnd) {
            revert NotMature();
        }
        _settle(pa);
        _settle(pb);
        if (pa.tier == HARD) lockedShares -= pa.shares;
        if (pb.tier == HARD) lockedShares -= pb.shares;

        id = nextPositionId++;
        Position storage m = _positions[id];
        m.owner = msg.sender;
        m.tier = SOFT;
        m.settledTo = e;
        // Both are mature, so the merged position simply carries their combined
        // full weight. Total weight and the slope do not change.
        m.horizon = 1;
        m.start = int64(uint64(e)) - 1;
        m.unlockedAtZeroWad = uint64(WAD);
        m.shares = pa.shares + pb.shares;
        m.baseWeight = uint128(_weight(pa, e) + _weight(pb, e));
        for (uint256 k; k < TOKENS; ++k) {
            m.earned[k] = pa.earned[k] + pb.earned[k];
            m.paid[k] = pa.paid[k] + pb.paid[k];
            m.tollOwed[k] = pa.tollOwed[k] + pb.tollOwed[k];
        }
        delete _positions[a];
        delete _positions[b];
        emit Merged(a, b, id);
    }
}
