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
/// First cut. Not here yet: compounding, deferred claims on the banked half,
/// tolls paid to lockers, an ERC-721 surface. Not audited.
abstract contract EpochHall {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOKENS = 2;
    /// Horizon and lock term are capped so that epoch arithmetic fits its storage with room to spare.
    uint256 internal constant MAX_EPOCHS = 1 << 20;

    uint8 public constant SOFT = 0;
    uint8 public constant HARD = 1;

    /// Seconds per epoch, and the time epoch 0 began.
    uint256 public immutable epochLength;
    uint256 public immutable startTime;
    /// Weight of a brand-new position as a share of full weight (WAD).
    uint256 public immutable floorWad;
    /// Epochs to full weight.
    uint256 public immutable horizon;
    /// Share of earned fees unlocked at age zero (WAD).
    uint256 public immutable unlockedAtZeroWad;
    /// Share of forfeits and tolls that goes to protocol-owned liquidity (WAD).
    uint256 public immutable polShareWad;
    /// Hard tier: epochs locked (0 switches the tier off), cost of leaving on
    /// the first day as a share of principal (WAD), and whether a locked
    /// position starts fully seasoned.
    uint256 public immutable lockTerm;
    uint256 public immutable lockExitWad;
    bool public immutable lockSkipsRamp;

    struct Position {
        address owner;
        uint8 tier;
        int64 start; // epoch the position's age is counted from
        uint64 settledTo; // earnings are settled for every epoch before this one
        uint64 lockEnd; // hard tier: first epoch it may leave free
        uint64 tollWad; // hard tier: exit cost written in when the position opened
        uint128 shares;
        uint128 baseWeight; // weight at age zero
        uint128 weightPerEpoch; // added each epoch until the horizon
        uint256[2] earned; // fees earned over the position's life
        uint256[2] paid; // fees already paid out
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

    uint256[2] internal _a;
    uint256[2] internal _b;
    /// Epochs at which the running sums changed, and their values from then on.
    uint64[] internal _checkpointEpochs;
    mapping(uint256 => Checkpoint) internal _checkpoints;

    event Opened(uint256 indexed id, address indexed owner, uint256 shares, uint8 tier);
    event Closed(uint256 indexed id, address indexed owner, uint256 shares, uint256 tollShares);
    event Paid(uint256 indexed id, address indexed to, uint256 amount0, uint256 amount1);
    event Forfeited(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Moved(uint256 indexed id, address indexed from, address indexed to);
    event Merged(uint256 indexed a, uint256 indexed b, uint256 indexed into);

    error NotOwner();
    error NoSuchPosition();
    error NotMature();
    error TierUnavailable();
    error BadConfig();

    struct HallConfig {
        uint256 epochLength;
        uint256 floorWad;
        uint256 horizon;
        uint256 unlockedAtZeroWad;
        uint256 polShareWad;
        uint256 lockTerm;
        uint256 lockExitWad;
        bool lockSkipsRamp;
    }

    constructor(HallConfig memory c) {
        if (
            c.epochLength == 0 || c.horizon == 0 || c.floorWad > WAD || c.unlockedAtZeroWad > WAD || c.polShareWad > WAD
                || c.lockExitWad > WAD || c.horizon > MAX_EPOCHS || c.lockTerm > MAX_EPOCHS
        ) revert BadConfig();
        epochLength = c.epochLength;
        startTime = block.timestamp;
        floorWad = c.floorWad;
        horizon = c.horizon;
        unlockedAtZeroWad = c.unlockedAtZeroWad;
        polShareWad = c.polShareWad;
        lockTerm = c.lockTerm;
        lockExitWad = c.lockExitWad;
        lockSkipsRamp = c.lockSkipsRamp;
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

    /// Fees a position could collect now, as of the hall's current epoch.
    function unlockedOf(uint256 id) external view returns (uint256[2] memory out) {
        Position storage p = _positions[id];
        if (p.owner == address(0)) return out;
        uint256 fraction = _unlockedFraction(p);
        for (uint256 k; k < TOKENS; ++k) {
            uint256 earned = p.earned[k] + _span(p, p.settledTo, epoch, k);
            out[k] = earned * fraction / WAD - p.paid[k];
        }
    }

    /// Exit cost for a hard-locked position, in shares, in the current epoch.
    function tollOf(uint256 id) public view returns (uint256) {
        return _toll(_positions[id]);
    }

    function _age(Position storage p, uint64 at) internal view returns (uint256) {
        uint256 age = uint256(int256(uint256(at)) - int256(p.start));
        return age < horizon ? age : horizon;
    }

    function _weight(Position storage p, uint64 at) internal view returns (uint256) {
        return uint256(p.baseWeight) + uint256(p.weightPerEpoch) * _age(p, at);
    }

    function _unlockedFraction(Position storage p) internal view returns (uint256) {
        return unlockedAtZeroWad + (WAD - unlockedAtZeroWad) * _age(p, epoch) / horizon;
    }

    function _toll(Position storage p) internal view returns (uint256) {
        if (p.tier != HARD || epoch >= p.lockEnd) return 0;
        // Melts in a straight line to zero at the end of the term (spec §18.3).
        return uint256(p.shares) * p.tollWad / WAD * (p.lockEnd - epoch) / lockTerm;
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
        int256 matures = int256(p.start) + int256(horizon);
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
            scaled += (uint256(p.baseWeight) + uint256(p.weightPerEpoch) * horizon) * (a1 - a0);
        }
        return scaled / WAD;
    }

    // ------------------------------------------------------------------
    // Positions
    // ------------------------------------------------------------------

    function _settle(Position storage p) internal {
        uint64 e = epoch;
        if (p.settledTo == e) return;
        for (uint256 k; k < TOKENS; ++k) {
            p.earned[k] += _span(p, p.settledTo, e, k);
        }
        p.settledTo = e;
    }

    function _addWeight(Position storage p) internal {
        uint64 e = epoch;
        totalWeight += _weight(p, e);
        int256 matures = int256(p.start) + int256(horizon);
        if (matures > int256(uint256(e)) && p.weightPerEpoch != 0) {
            slope += p.weightPerEpoch;
            slopeEnding[uint256(matures)] += p.weightPerEpoch;
        }
    }

    function _removeWeight(Position storage p) internal {
        uint64 e = epoch;
        totalWeight -= _weight(p, e);
        int256 matures = int256(p.start) + int256(horizon);
        if (matures > int256(uint256(e)) && p.weightPerEpoch != 0) {
            slope -= p.weightPerEpoch;
            slopeEnding[uint256(matures)] -= p.weightPerEpoch;
        }
    }

    /// Open a position. The books must be current.
    function _open(address owner, uint256 shares, uint8 tier) internal returns (uint256 id) {
        if (tier > HARD || (tier == HARD && lockTerm == 0)) revert TierUnavailable();
        if (shares > type(uint128).max) revert BadConfig();
        id = nextPositionId++;
        Position storage p = _positions[id];
        uint64 e = epoch;
        p.owner = owner;
        p.tier = tier;
        p.shares = uint128(shares);
        p.settledTo = e;
        // The weight a position reaches is base + perEpoch * horizon, which can
        // fall a few wei short of its shares. Rounding is always against the position.
        uint256 base = shares * floorWad / WAD;
        p.baseWeight = uint128(base);
        p.weightPerEpoch = uint128((shares - base) / horizon);
        p.start = int64(uint64(e));
        if (tier == HARD) {
            p.lockEnd = e + uint64(lockTerm);
            p.tollWad = uint64(lockExitWad);
            if (lockSkipsRamp) p.start = int64(uint64(e)) - int64(uint64(horizon));
        }
        _addWeight(p);
        emit Opened(id, owner, shares, tier);
    }

    /// Pay a position's unlocked fees to its owner.
    function _collect(uint256 id) internal returns (uint256[2] memory out) {
        Position storage p = _positions[id];
        if (p.owner == address(0)) revert NoSuchPosition();
        _settle(p);
        uint256 fraction = _unlockedFraction(p);
        for (uint256 k; k < TOKENS; ++k) {
            out[k] = p.earned[k] * fraction / WAD - p.paid[k];
            if (out[k] != 0) {
                p.paid[k] += out[k];
                _payFee(k, p.owner, out[k]);
            }
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

        uint256[2] memory lost;
        for (uint256 k; k < TOKENS; ++k) {
            uint256 held = p.earned[k] - p.paid[k];
            if (held == 0) continue;
            if (waived) {
                _payFee(k, owner, held);
            } else {
                lost[k] = held;
                uint256 toPol = held * polShareWad / WAD;
                if (toPol != 0) _creditPol(k, toPol);
                pending[k] += held - toPol;
            }
        }
        if (lost[0] != 0 || lost[1] != 0) emit Forfeited(id, lost[0], lost[1]);
        emit Closed(id, owner, shares, tollShares);
        delete _positions[id];
    }

    /// Hand a position to someone else. Its age, its lock and the fees it
    /// holds travel with it (spec §18.9).
    function transferPosition(uint256 id, address to) external {
        Position storage p = _positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (to == address(0)) revert BadConfig();
        _current();
        _settle(p);
        p.owner = to;
        emit Moved(id, msg.sender, to);
    }

    /// Merge two mature, unlocked-for-exit positions of the same owner (spec §18.9).
    function merge(uint256 a, uint256 b) external returns (uint256 id) {
        _current();
        Position storage pa = _positions[a];
        Position storage pb = _positions[b];
        if (pa.owner != msg.sender || pb.owner != msg.sender || a == b) revert NotOwner();
        uint64 e = epoch;
        if (_age(pa, e) < horizon || _age(pb, e) < horizon || e < pa.lockEnd || e < pb.lockEnd) revert NotMature();
        _settle(pa);
        _settle(pb);

        id = nextPositionId++;
        Position storage m = _positions[id];
        m.owner = msg.sender;
        m.tier = SOFT;
        m.settledTo = e;
        m.start = int64(uint64(e)) - int64(uint64(horizon));
        m.shares = pa.shares + pb.shares;
        // Both are mature, so total weight does not change and neither does the slope.
        m.baseWeight = pa.baseWeight + pb.baseWeight;
        m.weightPerEpoch = pa.weightPerEpoch + pb.weightPerEpoch;
        for (uint256 k; k < TOKENS; ++k) {
            m.earned[k] = pa.earned[k] + pb.earned[k];
            m.paid[k] = pa.paid[k] + pb.paid[k];
        }
        delete _positions[a];
        delete _positions[b];
        emit Merged(a, b, id);
    }
}
