// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Token} from "./Base.sol";
import {PoolSetup} from "./V5Pool.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {Roles} from "../src/PoolTypes.sol";
import {VenueSplitter, IV5PoolForSplitter} from "../src/VenueSplitter.sol";
import {BankEscrow, IDeployerForEscrow} from "../src/BankEscrow.sol";
import {TimelockedDeployer} from "../src/TimelockedDeployer.sol";
import {Defaults} from "../src/Defaults.sol";

/// What will one day move money home. Here it only has to exist and hold tokens.
contract Outlet {
    uint256 public immutable marker;

    constructor(uint256 marker_) {
        marker = marker_;
    }
}

/// A pool that reports whatever it is told to, for testing the escrow alone.
contract PretendPool {
    uint256 public bankTotal;
    mapping(address => uint256) public claimWeight;

    function recordBanked(uint256 amount) external {
        bankTotal += amount;
    }

    function settleClaims(uint256[] calldata) external {}

    function setClaim(address wallet, uint256 weight) external {
        claimWeight[wallet] = weight;
    }
}

abstract contract EscrowSetup is PoolSetup {
    bytes32 constant OUTLET = keccak256("outlet");
    bytes32 constant ENGINE = keccak256("engine");
    uint256 constant DELAY = 14 days;

    TimelockedDeployer deployer;
    BankEscrow escrow;
    VenueSplitter splitter;
    V5Pool pool;
    uint256 sunsetAt;

    address build = address(0xB111D);
    address prize = address(0x9121E);
    address converter = address(0xC0471);
    address deployKey = address(0xDE9107);
    address feeder = address(0xFEED);
    address m1 = address(0x111);
    address m2 = address(0x222);
    address m3 = address(0x333);

    /// The escrow takes token `a`. Release 10% an epoch; a pause is stuck after 30 days;
    /// two of three members to unpause or remove, after three days.
    function _limits(uint256 poolCap) internal pure returns (BankEscrow.Limits memory) {
        return BankEscrow.Limits(poolCap, 0.1e18, 30 days, 3 days, 2, 2);
    }

    function _deployAll(uint256 poolCap) internal {
        a = new Token("A");
        b = new Token("B");
        sunsetAt = vm.getBlockTimestamp() + 365 days;
        bytes32[] memory bound = new bytes32[](1);
        bound[0] = OUTLET;
        deployer = new TimelockedDeployer(DELAY, sunsetAt, deployKey, bound);
        address[] memory set = new address[](3);
        (set[0], set[1], set[2]) = (m1, m2, m3);
        escrow = new BankEscrow(
            address(a), IDeployerForEscrow(address(deployer)), OUTLET, EPOCH, _limits(poolCap), set, configurer
        );
        bankRole = address(escrow);
        pool = _pool(0.5e18, type(uint256).max);
        splitter = new VenueSplitter(
            IV5PoolForSplitter(address(pool)), Defaults.lines(build, pol, prize, address(escrow), converter), configurer
        );
        Roles memory r = _roles();
        r.venue = address(splitter);
        vm.prank(configurer);
        pool.setRoles(r);

        a.mint(feeder, 1e30);
        vm.prank(feeder);
        a.approve(address(escrow), type(uint256).max);
    }

    function _bank(address forPool, uint256 amount) internal {
        vm.prank(feeder);
        escrow.bank(forPool, amount);
    }

    function _deployOutlet() internal returns (address at) {
        bytes memory code = abi.encodePacked(type(Outlet).creationCode, abi.encode(uint256(7)));
        vm.prank(deployKey);
        deployer.queue(OUTLET, keccak256(code));
        _skip(DELAY);
        at = deployer.deploy(OUTLET, code);
    }
}

contract TimelockedDeployerTest is EscrowSetup {
    bytes code;

    function setUp() public {
        _deployAll(1000e18);
        code = abi.encodePacked(type(Outlet).creationCode, abi.encode(uint256(7)));
    }

    function test_aSlotsAddressIsKnownBeforeAnythingIsDeployedThere() public {
        address promised = deployer.addressOf(OUTLET);
        vm.assertEq(escrow.outlet(), promised, "the escrow committed to it at birth");
        vm.assertEq(promised.code.length, 0, "and nothing is there yet");
        vm.assertEq(_deployOutlet(), promised, "the code arrives at exactly that address");
        vm.assertEq(Outlet(promised).marker(), 7, "with the constructor arguments that were published");
    }

    function test_onlyThePublishedCodeCanBeDeployedAndOnlyAfterTheDelay() public {
        vm.prank(alice);
        vm.expectRevert(TimelockedDeployer.NotKey.selector);
        deployer.queue(OUTLET, keccak256(code));
        vm.prank(deployKey);
        deployer.queue(OUTLET, keccak256(code));
        vm.assertTrue(deployer.anyQueued(), "a deploy is waiting, for all to see");

        _skip(DELAY - 1);
        vm.expectRevert(TimelockedDeployer.TooEarly.selector);
        deployer.deploy(OUTLET, code);
        _skip(1);
        bytes memory other = abi.encodePacked(type(Outlet).creationCode, abi.encode(uint256(8)));
        vm.expectRevert(TimelockedDeployer.WrongCode.selector);
        deployer.deploy(OUTLET, other); // same contract, different argument: not what was published

        vm.prank(alice); // anyone may carry out a deploy that has waited
        deployer.deploy(OUTLET, code);
        vm.assertTrue(!deployer.anyQueued(), "nothing is waiting now");
        vm.prank(deployKey);
        vm.expectRevert(TimelockedDeployer.AlreadyFilled.selector);
        deployer.queue(OUTLET, keccak256(other)); // a slot is filled once
    }

    function test_aQueuedDeployCanBeCancelled() public {
        vm.startPrank(deployKey);
        deployer.queue(OUTLET, keccak256(code));
        deployer.cancel(OUTLET);
        vm.stopPrank();
        vm.assertTrue(!deployer.anyQueued(), "it no longer counts as waiting");
        _skip(DELAY);
        vm.expectRevert(TimelockedDeployer.NotQueued.selector);
        deployer.deploy(OUTLET, code);
    }

    function test_theOutletCannotArriveAfterTheSunsetButOtherSlotsCan() public {
        vm.warp(sunsetAt - DELAY); // too late for the delay to finish in time
        vm.startPrank(deployKey);
        vm.expectRevert(TimelockedDeployer.PastSunset.selector);
        deployer.queue(OUTLET, keccak256(code));
        deployer.queue(ENGINE, keccak256(code)); // not bound by the sunset
        vm.stopPrank();
        _skip(DELAY);
        deployer.deploy(ENGINE, code);
    }
}

contract BankEscrowTest is EscrowSetup {
    PretendPool one;
    PretendPool two;

    function setUp() public {
        _deployAll(1000e18);
        one = new PretendPool();
        two = new PretendPool();
    }

    // ------------------------------------------------------------------
    // Hold
    // ------------------------------------------------------------------

    function test_eachPoolHasItsOwnLedgerAndCap() public {
        _bank(address(one), 600e18);
        _bank(address(two), 200e18);
        vm.assertEq(escrow.ledgerOf(address(one)), 600e18, "one");
        vm.assertEq(escrow.ledgerOf(address(two)), 200e18, "two");
        vm.assertEq(one.bankTotal(), 600e18, "the pool was told what was banked for it");
        vm.assertEq(escrow.room(address(one)), 400e18, "room under the cap");
        vm.prank(feeder);
        vm.expectRevert(BankEscrow.OverCap.selector);
        escrow.bank(address(one), 401e18);
    }

    // ------------------------------------------------------------------
    // Release
    // ------------------------------------------------------------------

    function test_nothingIsReleasedUntilThePublishedOutletHasBeenLiveForAnEpoch() public {
        _bank(address(one), 1000e18);
        vm.expectRevert(BankEscrow.NotReady.selector);
        escrow.release(); // no outlet at all

        bytes memory code = abi.encodePacked(type(Outlet).creationCode, abi.encode(uint256(7)));
        vm.prank(deployKey);
        deployer.queue(OUTLET, keccak256(code));
        _skip(DELAY);
        vm.expectRevert(BankEscrow.NotReady.selector);
        escrow.release(); // queued and ripe, but not deployed

        address outlet = deployer.deploy(OUTLET, code);
        vm.expectRevert(BankEscrow.NotReady.selector);
        escrow.release(); // deployed this very moment: its first epoch is a freeze

        _skip(EPOCH);
        vm.assertEq(escrow.release(), 100e18, "then a tenth of the ledger");
        vm.assertEq(a.balanceOf(outlet), 100e18, "to the outlet and nowhere else");
        vm.expectRevert(BankEscrow.TooEarly.selector);
        escrow.release(); // once per epoch
        _skip(EPOCH);
        vm.assertEq(escrow.release(), 90e18, "a tenth of what is left");
    }

    function test_aReleaseComesFromEveryPoolInProportion() public {
        _bank(address(one), 600e18);
        _bank(address(two), 200e18);
        _deployOutlet();
        _skip(EPOCH);
        escrow.release();
        vm.assertEq(escrow.ledgerOf(address(one)), 540e18, "one gives a tenth");
        vm.assertEq(escrow.ledgerOf(address(two)), 180e18, "two gives a tenth");
        // Banking after a release still credits exactly what was put in.
        _bank(address(two), 50e18);
        vm.assertApproxEqAbs(escrow.ledgerOf(address(two)), 230e18, 10, "two, after banking again");
        vm.assertApproxEqAbs(escrow.ledgerOf(address(one)), 540e18, 10, "one is not diluted by it");
    }

    function test_releasesFreezeWhileAnyOtherDeployIsWaiting() public {
        _bank(address(one), 1000e18);
        _deployOutlet();
        _skip(EPOCH);
        bytes memory engine = abi.encodePacked(type(Outlet).creationCode, abi.encode(uint256(1)));
        vm.prank(deployKey);
        deployer.queue(ENGINE, keccak256(engine));
        vm.expectRevert(BankEscrow.NotReady.selector);
        escrow.release();
        _skip(DELAY);
        deployer.deploy(ENGINE, engine);
        vm.assertGt(escrow.release(), 0, "and resume once it has landed");
    }

    function test_strayTransfersCannotDiluteThoseWhoBankLater() public {
        _bank(address(one), 1); // a first depositor banks one wei
        vm.prank(feeder);
        a.transfer(address(escrow), 500e18); // and sends a fortune in directly
        _deployOutlet();
        _skip(EPOCH);
        escrow.release();
        _bank(address(two), 100e18);
        vm.assertApproxEqAbs(escrow.ledgerOf(address(two)), 100e18, 10, "the later pool is credited in full");
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    function test_anyOneMemberCanPauseAndItTakesAThresholdAndADelayToUnpause() public {
        _bank(address(one), 1000e18);
        _deployOutlet();
        _skip(EPOCH);

        vm.prank(alice);
        vm.expectRevert(BankEscrow.NotAllowed.selector);
        escrow.pause();
        vm.prank(m1);
        escrow.pause();
        vm.expectRevert(BankEscrow.IsPaused.selector);
        escrow.release();

        vm.prank(m2);
        escrow.voteUnpause();
        vm.expectRevert(BankEscrow.TooEarly.selector);
        escrow.unpause(); // one vote is not agreement
        vm.prank(m3);
        escrow.voteUnpause();
        vm.expectRevert(BankEscrow.TooEarly.selector);
        escrow.unpause(); // agreed, but the delay has not passed
        _skip(3 days);
        escrow.unpause();
        vm.assertGt(escrow.release(), 0, "releases resume");
    }

    function test_aMemberWhoKeepsPausingCanBeRemovedAtOnce() public {
        _bank(address(one), 1000e18);
        _deployOutlet();
        _skip(EPOCH);
        vm.prank(m1);
        escrow.pause();

        vm.prank(m2);
        escrow.voteRemove(m1);
        vm.assertTrue(escrow.isMember(m1), "one vote is not enough");
        vm.prank(m3);
        escrow.voteRemove(m1);
        vm.assertTrue(!escrow.isMember(m1), "two is, and it takes effect at once");
        vm.assertEq(escrow.members().length, 2, "the set is smaller");

        vm.prank(m2);
        escrow.voteUnpause();
        vm.prank(m3);
        escrow.voteUnpause();
        _skip(3 days);
        escrow.unpause();
        vm.prank(m1);
        vm.expectRevert(BankEscrow.NotAllowed.selector);
        escrow.pause(); // and can no longer pause

        // The set cannot shrink below its floor of two.
        vm.prank(m2);
        escrow.voteRemove(m3);
        vm.prank(m3);
        vm.expectRevert(BankEscrow.BelowFloor.selector);
        escrow.voteRemove(m3);
    }

    function test_noMemberCanBeRemovedWhileADeployIsWaiting() public {
        bytes memory code = abi.encodePacked(type(Outlet).creationCode, abi.encode(uint256(7)));
        vm.prank(deployKey);
        deployer.queue(OUTLET, keccak256(code));
        vm.prank(m2);
        vm.expectRevert(BankEscrow.DeployWaiting.selector);
        escrow.voteRemove(m1);
    }

    // ------------------------------------------------------------------
    // Refund
    // ------------------------------------------------------------------

    function test_noRefundWithoutATrigger() public {
        _bank(address(one), 1000e18);
        vm.expectRevert(BankEscrow.NoRefund.selector);
        escrow.openRefund();
        vm.warp(sunsetAt - 1);
        vm.expectRevert(BankEscrow.NoRefund.selector);
        escrow.openRefund();
    }

    function test_theSunsetDoesNotOpenARefundIfTheOutletArrived() public {
        _bank(address(one), 1000e18);
        _deployOutlet();
        vm.warp(sunsetAt + 1);
        vm.expectRevert(BankEscrow.NoRefund.selector);
        escrow.openRefund();
    }

    function test_atTheSunsetWithNoOutletTheMoneyGoesBackEvenWhilePaused() public {
        _bank(address(one), 600e18);
        _bank(address(two), 200e18);
        one.setClaim(alice, 450e18); // alice earned three quarters of what pool one banked
        one.setClaim(bob, 150e18);
        vm.prank(m1);
        escrow.pause(); // a pause does not stand in the way
        vm.warp(sunsetAt);
        escrow.openRefund();

        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.assertEq(escrow.claimRefund(address(one), none), 450e18, "alice's share of pool one");
        vm.prank(bob);
        vm.assertEq(escrow.claimRefund(address(one), none), 150e18, "bob's");
        vm.prank(alice);
        vm.assertEq(escrow.claimRefund(address(one), none), 0, "nobody is paid twice");
        vm.assertEq(a.balanceOf(address(escrow)), 200e18, "pool two's money is untouched");

        // The escrow is closed for good.
        vm.prank(feeder);
        vm.expectRevert(BankEscrow.Closed.selector);
        escrow.bank(address(one), 1e18);
        vm.expectRevert(BankEscrow.Closed.selector);
        escrow.release();
    }

    function test_aPauseThatLastsTooLongRefundsWhatTheOutletDidNotDraw() public {
        _bank(address(one), 1000e18);
        one.setClaim(alice, 1000e18);
        _deployOutlet();
        _skip(EPOCH);
        escrow.release(); // the outlet draws 100
        vm.prank(m1);
        escrow.pause();

        _skip(30 days - 1);
        vm.assertTrue(!escrow.stuck(), "not yet");
        _skip(1);
        escrow.openRefund();
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.assertEq(escrow.claimRefund(address(one), none), 900e18, "everything that was not drawn");
    }

    function test_anHonestUnpauseResetsTheClock() public {
        _bank(address(one), 1000e18);
        _deployOutlet();
        vm.prank(m1);
        escrow.pause();
        _skip(20 days);
        vm.prank(m2);
        escrow.voteUnpause();
        vm.prank(m3);
        escrow.voteUnpause();
        _skip(3 days);
        escrow.unpause();
        vm.prank(m1);
        escrow.pause(); // paused again, but the thirty days start over
        _skip(20 days);
        vm.expectRevert(BankEscrow.NoRefund.selector);
        escrow.openRefund();
    }

    function test_aPoolCannotHandOutMoreThanItsOwnShare() public {
        _bank(address(one), 100e18);
        _bank(address(two), 900e18);
        one.setClaim(alice, 100_000e18); // pool one lies about what alice is owed
        vm.warp(sunsetAt);
        escrow.openRefund();
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.assertEq(escrow.claimRefund(address(one), none), 100e18, "it can only empty its own ledger");
        vm.assertEq(a.balanceOf(address(escrow)), 900e18, "pool two's money is safe");
    }

    function test_theLimitsKeepAStuckPauseLongerThanADeployAndAnUnpause() public {
        BankEscrow.Limits memory l = _limits(1000e18);
        l.stuckPeriod = DELAY + 3 days; // exactly a deploy delay plus an unpause: not long enough
        vm.prank(configurer);
        vm.expectRevert(BankEscrow.BadLimits.selector);
        escrow.setLimits(l);
        l.stuckPeriod += 1;
        vm.prank(alice);
        vm.expectRevert(BankEscrow.NotAllowed.selector);
        escrow.setLimits(l);
        vm.prank(configurer);
        escrow.setLimits(l);
    }
}

/// The escrow and a real pool together: who gets what when the money comes back.
contract DeferredClaimsTest is EscrowSetup {
    function setUp() public {
        _deployAll(100_000e18);
        _fund(alice, pool);
        _fund(bob, pool);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function test_aLateDepositGetsOnlyItsShareOfTheEpochsItWasIn() public {
        vm.prank(alice);
        (uint256 hers,) = pool.join(1000e18, 1000e18, 0, 0, alice);
        // 100 banked in each of six epochs. Alice is alone for the first four.
        uint256 his;
        for (uint256 e; e < 6; ++e) {
            if (e == 4) {
                vm.prank(bob);
                (his,) = pool.join(1000e18, 1000e18, 0, 0, bob); // he arrives at the floor: half weight
            }
            _bank(address(pool), 100e18);
            _nextEpoch();
        }
        vm.warp(sunsetAt);
        escrow.openRefund();

        vm.prank(alice);
        uint256 toAlice = escrow.claimRefund(address(pool), _ids(hers));
        vm.prank(bob);
        uint256 toBob = escrow.claimRefund(address(pool), _ids(his));
        // Epoch 4: weights 1000 and 500. Epoch 5: 1000 and 625.
        uint256 bobShare = uint256(100e18) * 500 / 1500 + uint256(100e18) * 625 / 1625;
        vm.assertApproxEqAbs(toBob, bobShare, 1e9, "bob: two epochs at a newcomer's weight");
        vm.assertApproxEqAbs(toAlice, 600e18 - bobShare, 1e9, "alice: everything else");
        vm.assertLe(toAlice + toBob, 600e18, "never more than was banked");
    }

    function test_aClaimStaysWithTheWalletThatEarnedItWhenThePositionIsSold() public {
        vm.prank(alice);
        (uint256 id,) = pool.join(1000e18, 1000e18, 0, 0, alice);
        for (uint256 e; e < 4; ++e) {
            if (e == 2) {
                vm.prank(alice);
                pool.transferPosition(id, bob);
            }
            _bank(address(pool), 100e18);
            _nextEpoch();
        }
        vm.warp(sunsetAt);
        escrow.openRefund();

        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.assertApproxEqAbs(
            escrow.claimRefund(address(pool), none), 200e18, 1e9, "the seller keeps the first two epochs"
        );
        vm.prank(bob);
        vm.assertApproxEqAbs(escrow.claimRefund(address(pool), _ids(id)), 200e18, 1e9, "the buyer earns the rest");
    }

    function test_aClaimSurvivesClosingThePosition() public {
        vm.prank(alice);
        (uint256 id,) = pool.join(1000e18, 1000e18, 0, 0, alice);
        vm.prank(bob);
        pool.join(1000e18, 1000e18, 0, 0, bob);
        _bank(address(pool), 100e18);
        _nextEpoch();
        vm.prank(alice);
        pool.exit(id, 0, 0, alice);
        vm.warp(sunsetAt);
        escrow.openRefund();
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.assertApproxEqAbs(
            escrow.claimRefund(address(pool), none), 50e18, 1e9, "she left, and is still owed her half"
        );
    }

    function test_afterAPartialDrawTheRestIsSplitByTheSameClaims() public {
        vm.prank(alice);
        (uint256 hers,) = pool.join(3000e18, 3000e18, 0, 0, alice);
        vm.prank(bob);
        (uint256 his,) = pool.join(1000e18, 1000e18, 0, 0, bob);
        _bank(address(pool), 1000e18);
        _deployOutlet();
        _skip(EPOCH);
        escrow.release();
        _skip(EPOCH);
        escrow.release(); // 100, then 90: 810 is left
        vm.prank(m1);
        escrow.pause();
        _skip(30 days);
        escrow.openRefund();

        vm.prank(alice);
        uint256 toAlice = escrow.claimRefund(address(pool), _ids(hers));
        vm.prank(bob);
        uint256 toBob = escrow.claimRefund(address(pool), _ids(his));
        vm.assertApproxEqAbs(toAlice, 810e18 * 3 / 4, 1e9, "three quarters of what is left");
        vm.assertApproxEqAbs(toBob, 810e18 / 4, 1e9, "one quarter");
    }

    function test_onlyTheEscrowCanRecordBankedMoney() public {
        vm.prank(alice);
        vm.expectRevert(V5Pool.NotAllowed.selector);
        pool.recordBanked(1e18);
    }
}

/// Random banking, releasing, pausing, voting, refunding and passing time.
contract EscrowHandler is EscrowSetup {
    PretendPool[3] public pools;
    address[3] wallets;
    bool public outletQueued;
    bytes code;

    constructor() {
        _deployAll(1_000_000e18);
        for (uint256 i; i < 3; ++i) {
            pools[i] = new PretendPool();
        }
        wallets = [alice, bob, trader];
        code = abi.encodePacked(type(Outlet).creationCode, abi.encode(uint256(7)));
    }

    function theEscrow() external view returns (BankEscrow) {
        return escrow;
    }

    function theAsset() external view returns (Token) {
        return a;
    }

    function bank(uint256 which, uint256 amount) external {
        PretendPool p = pools[which % 3];
        amount = bound(amount, 1, 50_000e18);
        _bank(address(p), amount);
        // Claims move around between wallets but never exceed what was banked.
        p.setClaim(wallets[amount % 3], p.bankTotal() / 3);
    }

    function stray(uint256 amount) external {
        vm.prank(feeder);
        a.transfer(address(escrow), bound(amount, 1, 1000e18));
    }

    function queueOutlet() external {
        vm.prank(deployKey);
        deployer.queue(OUTLET, keccak256(code));
        outletQueued = true;
    }

    function deployOutlet() external {
        deployer.deploy(OUTLET, code);
    }

    function release() external {
        escrow.release();
    }

    function pause(uint256 who) external {
        vm.prank([m1, m2, m3][who % 3]);
        escrow.pause();
    }

    function voteUnpause(uint256 who) external {
        vm.prank([m1, m2, m3][who % 3]);
        escrow.voteUnpause();
    }

    function unpause() external {
        escrow.unpause();
    }

    function voteRemove(uint256 who, uint256 target) external {
        vm.prank([m1, m2, m3][who % 3]);
        escrow.voteRemove([m1, m2, m3][target % 3]);
    }

    function openRefund() external {
        escrow.openRefund();
    }

    function claimRefund(uint256 which, uint256 who) external {
        uint256[] memory none = new uint256[](0);
        vm.prank(wallets[who % 3]);
        escrow.claimRefund(address(pools[which % 3]), none);
    }

    function pass(uint256 dt) external {
        _skip(bound(dt, 1 hours, 40 days));
    }
}

contract BankEscrowInvariants {
    EscrowHandler handler;
    BankEscrow escrow;
    Token asset;

    function setUp() public {
        handler = new EscrowHandler();
        escrow = handler.theEscrow();
        asset = handler.theAsset();
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    /// The escrow always holds at least what its ledger says, and the pools'
    /// ledgers never add up to more than the whole.
    function invariant_theLedgerIsAlwaysCovered() public view {
        uint256 held = asset.balanceOf(address(escrow));
        uint256 sum;
        uint256 refunded;
        for (uint256 i; i < 3; ++i) {
            address p = address(handler.pools(i));
            sum += escrow.refundOpen() ? escrow.refundOf(p) : escrow.ledgerOf(p);
            refunded += escrow.refundedToPool(p);
            require(
                escrow.refundedToPool(p) <= escrow.refundOf(p) || !escrow.refundOpen(),
                "a pool paid out more than its share"
            );
        }
        if (escrow.refundOpen()) {
            require(sum <= escrow.refundPot(), "refund shares exceed the pot");
            require(held + refunded >= escrow.refundPot(), "the pot is not covered");
        } else {
            require(sum <= escrow.ledger(), "pool ledgers exceed the ledger");
            require(held >= escrow.ledger(), "the ledger is not covered");
        }
    }

    /// Money leaves only two ways: to the outlet, or back as a refund.
    function invariant_moneyOnlyLeavesToTheOutletOrAsARefund() public view {
        uint256 refunded;
        for (uint256 i; i < 3; ++i) {
            refunded += escrow.refundedToPool(address(handler.pools(i)));
        }
        address[3] memory wallets = [address(0xA11CE), address(0xB0B), address(0x7DE)];
        uint256 atWallets;
        for (uint256 i; i < 3; ++i) {
            atWallets += asset.balanceOf(wallets[i]);
        }
        require(asset.balanceOf(escrow.outlet()) == escrow.released(), "the outlet holds exactly what was released");
        require(atWallets == refunded, "wallets hold exactly what was refunded");
    }
}
