// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface ILockForGauges {
    function ownerOf(uint256 id) external view returns (address);
    function votingWeight(uint256 id) external view returns (uint256);
    function lockedUntil(uint256 id) external view returns (uint256);
}

interface IPoolForGauges {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function donate(uint256 amount0, uint256 amount1) external;
}

/// @title Gauges
/// @notice Lockers vote, and their votes direct real money (spec v1.16 §6, §18.5).
///
/// Each week has a boost budget: stables paid in from the venue cut, never
/// newly made tokens. Lockers vote for pools. When the week closes, each pool
/// voted for receives its share of the budget as fees for its LPs, up to a cap
/// on any one pool's share. Whatever the cap holds back rolls into the next
/// week. A pool is only eligible once it has been listed, which is where the
/// spec's age, depth and oracle checks are applied.
///
/// Anyone may offer a bribe for votes on a pool, in any token. Once the week
/// closes, each lock that voted for that pool collects its share. A bribe
/// nobody collects in time decays to a fixed sink: the buyback path.
///
/// The same votes are the signal for placing protocol-owned liquidity. This
/// contract records them; moving that liquidity is not built.
///
/// Settings are changeable by the configurer and frozen by handing that role
/// to the zero address. First cut. Not audited.
contract Gauges {
    uint256 internal constant WAD = 1e18;
    uint256 public constant WEEK = 7 days;

    ILockForGauges public immutable lock;
    /// The boost budget is paid in and out in this token.
    address public immutable stable;
    uint256 public immutable startTime;

    /// The most of one week's budget a single pool may receive (WAD).
    uint256 public poolCapWad;
    /// Weeks after which an uncollected bribe decays.
    uint256 public bribeLife;
    /// Where decayed bribes go.
    address public decaySink;
    address public configurer;

    mapping(address => bool) public listed;

    mapping(uint256 => uint256) public budget; // week => stables to hand out
    mapping(uint256 => uint256) public totalVotes; // week => all weight cast
    mapping(uint256 => mapping(address => uint256)) public votesFor; // week => pool => weight
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public voteOf; // week => pool => lock => weight
    mapping(uint256 => mapping(uint256 => bool)) public hasVoted; // week => lock
    mapping(uint256 => mapping(uint256 => address)) public voterOf; // week => lock => who cast it
    mapping(uint256 => mapping(address => bool)) public paidOut; // week => pool
    mapping(uint256 => bool) public rolled; // week => leftover moved on

    mapping(uint256 => mapping(address => mapping(address => uint256))) public bribes; // week => pool => token => amount
    mapping(uint256 => mapping(address => mapping(address => uint256))) public bribesClaimed;
    mapping(uint256 => mapping(address => mapping(address => mapping(uint256 => bool)))) public bribeTaken;

    event Funded(uint256 indexed week, uint256 amount);
    event Voted(uint256 indexed week, uint256 indexed lockId, address[] pools, uint256[] sharesWad);
    event Boosted(uint256 indexed week, address indexed pool, uint256 amount);
    event Bribed(uint256 indexed week, address indexed pool, address indexed token, uint256 amount);
    event BribeClaimed(
        uint256 indexed week, address indexed pool, address indexed token, uint256 lockId, uint256 amount
    );

    error NotAllowed();
    error NotListed();
    error AlreadyVoted();
    error BadVote();
    error WeekNotOver();
    error AlreadyDone();
    error NotYet();

    constructor(
        ILockForGauges lock_,
        address stable_,
        uint256 poolCapWad_,
        uint256 bribeLife_,
        address decaySink_,
        address configurer_
    ) {
        lock = lock_;
        stable = stable_;
        startTime = block.timestamp;
        poolCapWad = poolCapWad_;
        bribeLife = bribeLife_;
        decaySink = decaySink_;
        configurer = configurer_;
    }

    function week() public view returns (uint256) {
        return (block.timestamp - startTime) / WEEK;
    }

    // ------------------------------------------------------------------
    // The budget
    // ------------------------------------------------------------------

    /// Add to this week's boost budget. Anyone may; the venue's splitter does.
    function fund(uint256 amount) external {
        uint256 w = week();
        budget[w] += amount;
        SafeTransferLib.safeTransferFrom(stable, msg.sender, address(this), amount);
        emit Funded(w, amount);
    }

    // ------------------------------------------------------------------
    // Votes
    // ------------------------------------------------------------------

    /// Cast a lock's vote for this week, split across pools. `sharesWad` must sum to one.
    function vote(uint256 lockId, address[] calldata pools, uint256[] calldata sharesWad) external {
        if (lock.ownerOf(lockId) != msg.sender) revert NotAllowed();
        uint256 w = week();
        if (hasVoted[w][lockId]) revert AlreadyVoted();
        uint256 weight = lock.votingWeight(lockId);
        if (weight == 0 || pools.length == 0 || pools.length != sharesWad.length) revert BadVote();
        // The lock must outlast the week it votes in. Otherwise the same tokens
        // could vote, leave free, lock again and vote a second time.
        if (lock.lockedUntil(lockId) < startTime + (w + 1) * WEEK) revert BadVote();
        hasVoted[w][lockId] = true;
        voterOf[w][lockId] = msg.sender;
        uint256 sum;
        uint256 cast;
        for (uint256 i; i < pools.length; ++i) {
            if (!listed[pools[i]]) revert NotListed();
            uint256 part = weight * sharesWad[i] / WAD;
            if (voteOf[w][pools[i]][lockId] != 0) revert BadVote(); // a pool named twice
            voteOf[w][pools[i]][lockId] = part;
            votesFor[w][pools[i]] += part;
            cast += part;
            sum += sharesWad[i];
        }
        if (sum != WAD) revert BadVote();
        totalVotes[w] += cast;
        emit Voted(w, lockId, pools, sharesWad);
    }

    /// A pool's share of a week's votes (WAD).
    function shareOf(uint256 w, address pool) public view returns (uint256) {
        uint256 total = totalVotes[w];
        return total == 0 ? 0 : votesFor[w][pool] * WAD / total;
    }

    // ------------------------------------------------------------------
    // Paying the boost
    // ------------------------------------------------------------------

    /// Pay a pool its boost for a finished week. Anyone may call, once per pool per week.
    function boost(uint256 w, address pool) external returns (uint256 amount) {
        if (w >= week()) revert WeekNotOver();
        if (paidOut[w][pool] || rolled[w]) revert AlreadyDone();
        paidOut[w][pool] = true;
        uint256 share = shareOf(w, pool);
        if (share > poolCapWad) share = poolCapWad;
        amount = budget[w] * share / WAD;
        if (amount == 0) return 0;
        _spent[w] += amount;
        SafeTransferLib.safeApprove(stable, pool, amount);
        if (IPoolForGauges(pool).token0() == stable) IPoolForGauges(pool).donate(amount, 0);
        else IPoolForGauges(pool).donate(0, amount);
        emit Boosted(w, pool, amount);
    }

    mapping(uint256 => uint256) internal _spent;

    /// Move what a finished week did not hand out into the current week's
    /// budget: what the cap held back, and everything if nobody voted. Anyone
    /// may call, a week after the week in question, so pools have had time to be paid.
    function rollOver(uint256 w) external {
        if (w + 1 >= week()) revert NotYet();
        if (rolled[w]) revert AlreadyDone();
        rolled[w] = true;
        uint256 left = budget[w] - _spent[w];
        budget[w] = _spent[w];
        budget[week()] += left;
        emit Funded(week(), left);
    }

    // ------------------------------------------------------------------
    // Bribes
    // ------------------------------------------------------------------

    /// Offer a bribe to this week's voters for `pool`.
    function bribe(address pool, address token, uint256 amount) external {
        if (!listed[pool]) revert NotListed();
        uint256 w = week();
        bribes[w][pool][token] += amount;
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        emit Bribed(w, pool, token, amount);
    }

    /// Collect a lock's share of a bribe, once the week has closed.
    function claimBribe(uint256 w, address pool, address token, uint256 lockId) external returns (uint256 amount) {
        if (w >= week()) revert WeekNotOver();
        if (w + bribeLife < week()) revert AlreadyDone(); // decayed
        if (bribeTaken[w][pool][token][lockId]) revert AlreadyDone();
        bribeTaken[w][pool][token][lockId] = true;
        uint256 votes = votesFor[w][pool];
        if (votes == 0) return 0;
        amount = bribes[w][pool][token] * voteOf[w][pool][lockId] / votes;
        bribesClaimed[w][pool][token] += amount;
        // Paid to whoever cast the vote, even if the lock has since been closed or sold.
        if (amount != 0) SafeTransferLib.safeTransfer(token, voterOf[w][lockId], amount);
        emit BribeClaimed(w, pool, token, lockId, amount);
    }

    /// Send what is left of a bribe to the decay sink once its life is over. Anyone may call.
    function sweepBribe(uint256 w, address pool, address token) external returns (uint256 amount) {
        if (w + bribeLife >= week()) revert NotYet();
        amount = bribes[w][pool][token] - bribesClaimed[w][pool][token];
        bribesClaimed[w][pool][token] += amount;
        if (amount != 0) SafeTransferLib.safeTransfer(token, decaySink, amount);
    }

    // ------------------------------------------------------------------
    // Settings
    // ------------------------------------------------------------------

    function setListed(address pool, bool on) external {
        if (msg.sender != configurer) revert NotAllowed();
        if (on && IPoolForGauges(pool).token0() != stable && IPoolForGauges(pool).token1() != stable) {
            revert NotListed();
        }
        listed[pool] = on;
    }

    function setLimits(uint256 poolCapWad_, uint256 bribeLife_, address decaySink_) external {
        if (msg.sender != configurer || poolCapWad_ > WAD) revert NotAllowed();
        poolCapWad = poolCapWad_;
        bribeLife = bribeLife_;
        decaySink = decaySink_;
    }

    function setConfigurer(address next) external {
        if (msg.sender != configurer) revert NotAllowed();
        configurer = next;
    }
}
