// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {McLovinId} from "../src/McLovinId.sol";
import {DeployMcLovinId} from "../script/DeployMcLovinId.s.sol";

/// @dev Stands in for ProjectFactory: deploys the token with CREATE2 from raw creation code, holds
/// the supply, and performs the launch flows (swarm share to the distributor, remainder onward).
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function call(address target, bytes calldata data) external returns (bool ok) {
        (ok,) = target.call(data);
    }
}

/// @title Edge cases, launch-flow exactness and algebraic properties of McLovin.id.
/// @dev Complements test/McLovinId.t.sol (which covers metadata, the basic success and revert
/// paths) with the inputs a fixed-supply launch token must get right: the exact launch flows the
/// factory performs, CREATE2 address prediction, the bytecode floor, allowance edge semantics,
/// unknown selectors, and round-trip / order-independence properties.
/// forge-config: default.fuzz.runs = 1000
contract McLovinIdEdgeTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant SWARM_BPS = 1_000;

    McLovinId token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.prank(deployer);
        token = new McLovinId();
    }

    // ------------------------------------------------------------ launch flows

    /// @dev The factory deploys with CREATE2 and empty constructor arguments; the address must be
    /// the one predicted from the creation code alone, and the factory must hold the whole supply.
    function test_create2AddressIsPredictableFromCreationCodeAlone() public {
        FactoryProbe factory = new FactoryProbe();
        bytes memory code = type(McLovinId).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        address deployed = factory.deploy(code, salt);
        assertEq(deployed, predicted, "CREATE2 address differs from the prediction");
        assertEq(McLovinId(deployed).balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(McLovinId(deployed).totalSupply(), EXPECTED_SUPPLY);
        assertEq(McLovinId(deployed).balanceOf(address(this)), 0);
    }

    /// @dev The same salt from the same deployer cannot be reused: the second creation fails and
    /// the first token is untouched.
    function test_create2SameSaltTwiceFails() public {
        FactoryProbe factory = new FactoryProbe();
        bytes memory code = type(McLovinId).creationCode;
        address first = factory.deploy(code, bytes32(0));
        vm.expectRevert(bytes("constructor failed"));
        factory.deploy(code, bytes32(0));
        assertEq(McLovinId(first).balanceOf(address(factory)), EXPECTED_SUPPLY);
    }

    /// @dev The launch as the factory performs it: ten percent to the distributor, claims out of the
    /// distributor, the rest forwarded. Every leg arrives exactly whole and the supply is unchanged.
    function test_launchFlowsArriveWhole() public {
        FactoryProbe factory = new FactoryProbe();
        McLovinId launched = McLovinId(factory.deploy(type(McLovinId).creationCode, bytes32(uint256(1))));
        address distributor = makeAddr("distributor");
        address poolSeat = makeAddr("poolSeat");
        address requester = makeAddr("requester");

        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (EXPECTED_SUPPLY * 5_000) / 10_000;
        uint256 remainder = EXPECTED_SUPPLY - swarm - pool;

        assertTrue(factory.move(launched, distributor, swarm));
        assertEq(launched.balanceOf(distributor), swarm, "swarm share arrived short");
        assertTrue(factory.move(launched, poolSeat, pool));
        assertEq(launched.balanceOf(poolSeat), pool, "pool share arrived short");
        assertTrue(factory.move(launched, requester, remainder));
        assertEq(launched.balanceOf(requester), remainder, "remainder arrived short");
        assertEq(launched.balanceOf(address(factory)), 0, "factory kept something back");

        // Claims: an uneven split so the last claimant depends on nothing having been skimmed.
        uint256 firstClaim = swarm / 3;
        vm.prank(distributor);
        assertTrue(launched.transfer(alice, firstClaim));
        vm.prank(distributor);
        assertTrue(launched.transfer(bob, swarm - firstClaim));
        assertEq(launched.balanceOf(alice), firstClaim);
        assertEq(launched.balanceOf(bob), swarm - firstClaim);
        assertEq(launched.balanceOf(distributor), 0, "distributor kept something back");

        // Holders can trade among themselves and back into a pool-like account unrestricted.
        vm.prank(alice);
        assertTrue(launched.transfer(poolSeat, firstClaim));
        assertEq(launched.balanceOf(poolSeat), pool + firstClaim);

        assertEq(launched.totalSupply(), EXPECTED_SUPPLY, "launch flows changed the supply");
    }

    /// @dev After launch the factory, the address a token would most plausibly trust, cannot grow
    /// the supply or move a holder's balance through any admin-shaped call.
    function test_factoryHasNoPrivilegedHandAfterLaunch() public {
        FactoryProbe factory = new FactoryProbe();
        McLovinId launched = McLovinId(factory.deploy(type(McLovinId).creationCode, bytes32(uint256(2))));
        factory.move(launched, alice, EXPECTED_SUPPLY / 1_000);
        uint256 held = launched.balanceOf(alice);

        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "issue(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "lock(address)",
            "disableTransfers()",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            assertFalse(factory.call(address(launched), abi.encodeWithSignature(signatures[i], alice, true)));
            assertFalse(factory.call(address(launched), abi.encodeWithSignature(signatures[i], alice, held)));
        }
        assertFalse(
            factory.call(address(launched), abi.encodeCall(IERC20.transferFrom, (alice, address(factory), 1))),
            "factory moved a holder without allowance"
        );

        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(alice), held, "a privileged call moved the holder's balance");
        vm.prank(alice);
        assertTrue(launched.transfer(bob, held / 2), "the holder can no longer transfer");
        assertEq(launched.balanceOf(bob), held / 2);
    }

    // ------------------------------------------------------------ bytecode floor

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime contains CALLCODE");
            assertTrue(op != 0xFF, "runtime contains SELFDESTRUCT");
        }
    }

    /// @dev `bytecode_hash = "none"` and no immutables: two deployments share identical runtime, so
    /// what is attested is what is deployed anywhere.
    function test_runtimeIsIdenticalAcrossDeployments() public {
        vm.prank(alice);
        McLovinId other = new McLovinId();
        assertEq(address(other).code, address(token).code);
    }

    // ----------------------------------------------------------- deploy script

    /// @dev `run()` wraps `deploy()` in a broadcast, so the creation is sent by the configured
    /// signer (the test's `tx.origin` here), not by the script contract. That signer, and only that
    /// signer, receives the whole supply in a single mint.
    function test_scriptRunMintsWholeSupplyToTheBroadcastSigner() public {
        DeployMcLovinId script = new DeployMcLovinId();
        address signer = tx.origin;
        vm.recordLogs();
        McLovinId deployed = script.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 mints;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(deployed) || logs[i].topics[0] != IERC20.Transfer.selector) continue;
            mints++;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(0), "mint not from the zero address");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), signer, "mint did not go to the signer");
            assertEq(abi.decode(logs[i].data, (uint256)), EXPECTED_SUPPLY);
        }
        assertEq(mints, 1, "expected exactly one mint");
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(signer), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), 0);
    }

    // ------------------------------------------------------- allowance semantics

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        token.approve(alice, 40);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 40);
    }

    function test_approveZeroClearsAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 0);
        token.approve(alice, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_approveAboveBalanceIsAllowedButNotSpendable() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, EXPECTED_SUPPLY);
        assertEq(token.allowance(alice, bob), EXPECTED_SUPPLY);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        token.transferFrom(alice, bob, 11);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 10));
        assertEq(token.allowance(alice, bob), EXPECTED_SUPPLY - 10);
    }

    /// @dev The holder itself needs an allowance to use transferFrom on its own balance.
    function test_transferFromBySelfRequiresSelfAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 5);
        assertTrue(token.transferFrom(deployer, alice, 5));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 5);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    function test_exactAllowanceSpendsToZero() public {
        vm.prank(deployer);
        token.approve(alice, 7);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 7);
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Only the exact sentinel is treated as infinite: one below it is decremented.
    function test_allowanceJustBelowMaxIsDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 2);
    }

    function test_revert_transferFromToZeroAddress() public {
        vm.prank(deployer);
        token.approve(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1);
        assertEq(token.allowance(deployer, alice), 1, "a failed transferFrom consumed the allowance");
    }

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    /// @dev transferFrom emits exactly one Transfer and no Approval for the allowance it consumes.
    function test_transferFromEmitsOnlyTransfer() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), deployer);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 4);
    }

    // -------------------------------------------------------------- misc edges

    function test_transferOneWei() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1);
    }

    /// @dev Tokens sent to the token contract are accepted and unrecoverable: there is no sweep.
    function test_transferToTokenContractIsAcceptedAndStuck() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 3));
        assertEq(token.balanceOf(address(token)), 3);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 3));
        token.transferFrom(address(token), deployer, 3);
    }

    function test_transferToContractWithoutHooksSucceeds() public {
        FactoryProbe plain = new FactoryProbe();
        vm.prank(deployer);
        assertTrue(token.transfer(address(plain), 9));
        assertEq(token.balanceOf(address(plain)), 9);
    }

    function test_revert_etherWithCalldataIsRejected() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transfer, (alice, 1)));
        assertFalse(ok, "a payable path exists");
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Any selector the ABI does not define reverts: there is no fallback that could hide a
    /// privileged path behind an unlisted name.
    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes calldata args) public {
        bytes4[11] memory known = [
            IERC20.totalSupply.selector,
            IERC20.balanceOf.selector,
            IERC20.transfer.selector,
            IERC20.allowance.selector,
            IERC20.approve.selector,
            IERC20.transferFrom.selector,
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.TOTAL_SUPPLY.selector,
            token.SUPPLY_WHOLE_TOKENS.selector
        ];
        for (uint256 i; i < known.length; ++i) {
            // Eleven selectors out of 2^32: the discard rate is negligible.
            vm.assume(selector != known[i]);
        }
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    // -------------------------------------------------------- fuzz properties

    /// @dev Round trip: sending an amount and sending it back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev Order independence: two transfers from the same sender land the same end state in
    /// either order.
    function testFuzz_transferOrderDoesNotMatter(uint256 a, uint256 b) public {
        a = bound(a, 0, EXPECTED_SUPPLY);
        b = bound(b, 0, EXPECTED_SUPPLY - a);

        uint256 snapshot = vm.snapshotState();
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(bob, b);
        vm.stopPrank();
        uint256 aliceFirst = token.balanceOf(alice);
        uint256 bobFirst = token.balanceOf(bob);
        uint256 deployerFirst = token.balanceOf(deployer);

        vm.revertToState(snapshot);
        vm.startPrank(deployer);
        token.transfer(bob, b);
        token.transfer(alice, a);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), aliceFirst);
        assertEq(token.balanceOf(bob), bobFirst);
        assertEq(token.balanceOf(deployer), deployerFirst);
        assertEq(deployerFirst, EXPECTED_SUPPLY - a - b);
    }

    /// @dev Splitting a transfer into two parts moves the same total as one transfer.
    function testFuzz_transferIsAdditive(uint256 total, uint256 part) public {
        total = bound(total, 0, EXPECTED_SUPPLY);
        part = bound(part, 0, total);
        vm.startPrank(deployer);
        token.transfer(alice, part);
        token.transfer(alice, total - part);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - total);
    }

    /// @dev Idempotence: approving the same amount again changes nothing.
    function testFuzz_approveIsIdempotent(uint256 amount) public {
        vm.startPrank(deployer);
        token.approve(alice, amount);
        token.approve(alice, amount);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), amount);
    }

    /// @dev Allowances are per (owner, spender): granting one spender gives nothing to another and
    /// a transfer by the owner leaves the allowance untouched.
    function testFuzz_allowanceIsIsolated(uint256 allowed, uint256 moved) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        moved = bound(moved, 0, EXPECTED_SUPPLY);
        vm.startPrank(deployer);
        token.approve(alice, allowed);
        token.transfer(carol, moved);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), allowed);
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.allowance(alice, deployer), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev No caller other than the holder can move the holder's balance without an allowance,
    /// whoever they are.
    function testFuzz_strangerCannotMoveHolder(address stranger, uint256 held, uint256 amount) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 1, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        if (stranger == alice) stranger = bob;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(alice, stranger, amount);
        assertEq(token.balanceOf(alice), held);
    }

    /// @dev A transfer that reverts leaves every balance exactly as it was.
    function testFuzz_failedTransferLeavesStateUntouched(uint256 held, uint256 amount) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (bob, amount)));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - held);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }
}
