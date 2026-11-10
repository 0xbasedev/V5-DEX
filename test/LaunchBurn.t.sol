// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Token} from "./Base.sol";
import {EscrowSetup} from "./BankEscrow.t.sol";
import {PretendFeed} from "./TuningFork.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {BankEscrow} from "../src/BankEscrow.sol";
import {ExchangeToken} from "../src/ExchangeToken.sol";
import {BurnVault, IBurnable} from "../src/BurnVault.sol";
import {BuybackEngine} from "../src/BuybackEngine.sol";
import {HomeOutlet} from "../src/HomeOutlet.sol";

/// The whole road from a banked fee to a burned token, every later contract
/// arriving through the timelocked deployer.
abstract contract LaunchSetup is EscrowSetup {
    bytes32 constant TOKEN = keccak256("token");
    uint256 constant SUPPLY = 1_000_000e18;

    ExchangeToken token;
    BurnVault burnVault;
    BuybackEngine engine;
    HomeOutlet outlet;
    V5Pool market; // the token against the escrow's asset
    address treasury = address(0x72EA5);

    function _through(bytes32 salt, bytes memory code) internal returns (address at) {
        vm.prank(deployKey);
        deployer.queue(salt, keccak256(code));
        _skip(DELAY);
        at = deployer.deploy(salt, code);
    }

    function _tokenCode(string memory name, uint256 supply) internal view returns (bytes memory) {
        address[] memory holders = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (holders[0], amounts[0]) = (treasury, supply);
        return abi.encodePacked(type(ExchangeToken).creationCode, abi.encode(name, "TKN", holders, amounts));
    }

    function _launchToken() internal {
        token = ExchangeToken(_through(TOKEN, _tokenCode("The Token", SUPPLY)));
        burnVault = new BurnVault(IBurnable(address(token)), 30 days, vm.getBlockTimestamp() + 30 days);
        // A market for it: 100,000 of each, so one token costs one unit of the asset.
        market = new V5Pool(
            V5Pool.PoolConfig(address(a), address(token), 0.5e18, EPOCH, 0.003e18, 0.1e18, type(uint256).max, 0),
            _roles(),
            _hallConfig(),
            _feePolicy()
        );
        a.mint(treasury, 1e30);
        vm.startPrank(treasury);
        a.approve(address(market), type(uint256).max);
        token.approve(address(market), type(uint256).max);
        market.join(100_000e18, 100_000e18, 0, 0, treasury);
        vm.stopPrank();
    }

    function _engineSetup() internal view returns (BuybackEngine.Setup memory s) {
        s.asset = address(a);
        s.token = address(token);
        s.tokenCodeHash = address(token).codehash;
        s.supplyCommitment = SUPPLY;
        s.pool = address(market);
        s.burnVault = address(burnVault);
        s.perBuy = 100e18;
        s.startAt = vm.getBlockTimestamp() + DELAY + 1 days;
        s.window = 1 days;
        s.maxPremiumWad = 0.02e18;
    }

    function _launchEngine(BuybackEngine.Setup memory s) internal {
        bytes memory code = abi.encodePacked(type(BuybackEngine).creationCode, abi.encode(s));
        engine = BuybackEngine(_through(ENGINE, code));
    }

    function _launchOutlet() internal {
        bytes memory code =
            abi.encodePacked(type(HomeOutlet).creationCode, abi.encode(address(a), deployer.addressOf(ENGINE)));
        outlet = HomeOutlet(_through(OUTLET, code));
    }

    /// Readings every three hours for a day and a bit: enough history for the Engine's average.
    function _watchForAWindow() internal {
        for (uint256 i; i < 10; ++i) {
            engine.observe();
            _skip(3 hours);
        }
    }
}

contract LaunchBurnTest is LaunchSetup {
    function setUp() public {
        _deployAll(100_000e18);
    }

    function test_fromABankedFeeToABurnedToken() public {
        _bank(address(pool), 1000e18); // pre-token: banked in the escrow, on the pool's ledger
        _launchToken();
        _launchEngine(_engineSetup());
        _launchOutlet();
        vm.assertEq(address(outlet), escrow.outlet(), "the outlet landed where the escrow has pointed since day one");
        vm.assertEq(outlet.engine(), address(engine), "and it points at the Engine");

        // The escrow releases a tenth, the outlet passes it on.
        _skip(EPOCH);
        escrow.release();
        outlet.forward();
        vm.assertEq(a.balanceOf(address(engine)), 100e18, "the Engine holds this epoch's release");
        vm.assertEq(a.balanceOf(address(outlet)), 0, "the outlet holds nothing");

        // The Engine will not buy until it has watched the price for a full window.
        _nextBlock();
        vm.expectRevert(BuybackEngine.NotEnoughHistory.selector);
        engine.buy();
        _watchForAWindow();
        _nextBlock();
        (uint256 spent, uint256 bought) = engine.buy();
        vm.assertEq(spent, 100e18, "it spends what it has, up to its limit per buy");
        vm.assertApproxEqAbs(
            bought, 99.6e18, 0.1e18, "and gets about one token per unit, less the fee and its own price impact"
        );
        vm.assertEq(token.balanceOf(address(burnVault)), bought, "straight into the Burn Vault");

        // Burn day.
        vm.expectRevert(BurnVault.NotBurnDay.selector);
        burnVault.burn();
        _skip(30 days);
        burnVault.burn();
        vm.assertEq(burnVault.totalBurned(), bought, "the meter counts what was burned");
        vm.assertEq(token.totalSupply(), SUPPLY - bought, "and the supply is smaller for good");
    }

    function test_theTokensCodeIsTheSameWhateverItsSupplyNameOrChain() public {
        token = ExchangeToken(_through(TOKEN, _tokenCode("The Token", SUPPLY)));
        bytes32 here = address(token).codehash;
        vm.chainId(999_999);
        bytes memory other = _tokenCode("Something Else", 7e18);
        address at;
        assembly {
            at := create(0, add(other, 0x20), mload(other))
        }
        vm.assertEq(uint256(at.codehash), uint256(here), "one code hash identifies the token everywhere");
        vm.assertEq(ExchangeToken(at).totalSupply(), 7e18, "though this one has a different supply");
        vm.assertEq(token.mintedAtBirth(), SUPPLY, "the supply at birth is on record");
    }

    function test_holdersCanBurnAndNobodyCanMint() public {
        token = ExchangeToken(_through(TOKEN, _tokenCode("The Token", SUPPLY)));
        vm.prank(treasury);
        token.burn(1000e18);
        vm.assertEq(token.totalSupply(), SUPPLY - 1000e18, "burning shrinks the supply");
        // There is no mint function to call. A call to one reaches nothing.
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", treasury, 1e18));
        vm.assertTrue(!ok, "the token has no way to mint");
    }

    function test_theEngineStopsIfTheTokenIsNotTheOneItWasBuiltFor() public {
        _launchToken();
        BuybackEngine.Setup memory s = _engineSetup();
        s.tokenCodeHash = keccak256("some other code");
        _launchEngine(s);
        a.mint(address(engine), 100e18);
        _watchForAWindow();
        _nextBlock();
        vm.expectRevert(BuybackEngine.WrongToken.selector);
        engine.buy();
    }

    function test_theEngineStopsIfTheSupplyIsAboveWhatWasCommitted() public {
        _launchToken();
        BuybackEngine.Setup memory s = _engineSetup();
        s.supplyCommitment = SUPPLY - 1;
        _launchEngine(s);
        a.mint(address(engine), 100e18);
        _watchForAWindow();
        _nextBlock();
        vm.expectRevert(BuybackEngine.WrongToken.selector);
        engine.buy();
    }

    function test_theEngineBuysOnceABlockAndNeverBeforeItsStart() public {
        _launchToken();
        BuybackEngine.Setup memory s = _engineSetup();
        s.startAt = vm.getBlockTimestamp() + DELAY + 10 days;
        _launchEngine(s);
        a.mint(address(engine), 1000e18);
        _watchForAWindow();
        _nextBlock();
        vm.expectRevert(BuybackEngine.NotStarted.selector);
        engine.buy();

        _skip(10 days);
        engine.observe();
        _nextBlock();
        (uint256 spent,) = engine.buy();
        vm.assertEq(spent, 100e18, "a tenth of what it holds: the limit per buy");
        vm.expectRevert(BuybackEngine.OncePerBlock.selector);
        engine.buy();
        _nextBlock();
        engine.buy();
        vm.assertEq(engine.totalSpent(), 200e18, "one buy in each block");
    }

    function test_theEngineWillNotBuyIntoAPriceSomeonePushedUp() public {
        _launchToken();
        _launchEngine(_engineSetup());
        a.mint(address(engine), 100e18);
        _watchForAWindow();

        // Someone buys a tenth of the pool's tokens just before the Engine's buy.
        vm.prank(treasury);
        market.swap(address(a), 12_000e18, 0, treasury);
        _nextBlock();
        vm.expectRevert(V5Pool.TooLittle.selector);
        engine.buy(); // the pool would give less than the Engine's average allows
        vm.assertEq(a.balanceOf(address(engine)), 100e18, "nothing was spent");
    }

    function test_withAnOutsidePriceTheEngineMeasuresAgainstIt() public {
        _launchToken();
        PretendFeed feed = new PretendFeed();
        BuybackEngine.Setup memory s = _engineSetup();
        s.priceSource = address(feed);
        _launchEngine(s);
        a.mint(address(engine), 100e18);
        _skip(1 days);

        feed.set(0.9e18); // the outside market says a token is worth 0.90; the pool wants 1.00
        _nextBlock();
        vm.expectRevert(V5Pool.TooLittle.selector);
        engine.buy();
        feed.set(1e18);
        (uint256 spent,) = engine.buy();
        vm.assertEq(spent, 100e18, "at a fair price it buys, with no window to wait for");
    }

    function test_theBurnVaultOnlyBurnsAndOnlyOnBurnDay() public {
        _launchToken();
        vm.prank(treasury);
        token.transfer(address(burnVault), 500e18);
        vm.assertEq(burnVault.waiting(), 500e18, "tokens wait");
        vm.assertEq(burnVault.totalBurned(), 0, "and the meter does not count them yet");
        _skip(30 days);
        burnVault.burn();
        vm.assertEq(burnVault.totalBurned(), 500e18, "burned");
        vm.expectRevert(BurnVault.NotBurnDay.selector);
        burnVault.burn(); // not again until the next burn day
        _skip(75 days); // two and a half periods pass with nobody calling
        burnVault.burn();
        vm.assertEq(burnVault.nextBurnAt() - vm.getBlockTimestamp(), 15 days, "burn days stay on their calendar");
    }
}
