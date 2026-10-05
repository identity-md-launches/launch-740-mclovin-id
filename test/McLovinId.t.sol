// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {McLovinId} from "../src/McLovinId.sol";

/// @dev A deployer that is a contract, mirroring the factory which creates the token through
/// CREATE2 and must end up holding the whole supply.
contract DeployerProbe {
    function deploy(bytes32 salt) external returns (McLovinId) {
        return new McLovinId{salt: salt}();
    }
}

contract McLovinIdTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    McLovinId token;
    address deployer = address(0xDE91);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.prank(deployer);
        token = new McLovinId();
    }

    // ---------------------------------------------------------------- metadata

    function test_name() public view {
        assertEq(token.name(), "McLovin.id");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "MCLOVIN");
    }

    function test_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    // ------------------------------------------------------------------ supply

    function test_totalSupplyIsOneBillionTokens() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.SUPPLY_WHOLE_TOKENS() * 10 ** token.decimals(), token.totalSupply());
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        McLovinId fresh = new McLovinId();
        assertEq(fresh.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_contractDeployerViaCreate2ReceivesWholeSupply() public {
        DeployerProbe factory = new DeployerProbe();
        McLovinId fresh = factory.deploy(bytes32(uint256(7)));
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
    }

    function test_noMintFunctionExists() public {
        string[4] memory signatures = ["mint(address,uint256)", "mint(uint256)", "mint()", "setMinter(address)"];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(alice);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_noOwnerOrPrivilegedControls() public {
        string[8] memory signatures = [
            "owner()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "burnFrom(address,uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1));
            assertFalse(ok, signatures[i]);
        }
    }

    function test_rejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // --------------------------------------------------------------- transfers

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 1_000e18);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_revert_transferInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_revert_transferMoreThanSupply() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        token.transfer(alice, EXPECTED_SUPPLY + 1);
    }

    function test_revert_transferToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // -------------------------------------------------------------- allowances

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 300e18);
        assertTrue(token.approve(alice, 300e18));
        assertEq(token.allowance(deployer, alice), 300e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 200e18));
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 200e18);
        assertEq(token.allowance(deployer, alice), 100e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_revert_transferFromWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_revert_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 10, 11));
        token.transferFrom(deployer, bob, 11);
    }

    function test_revert_transferFromExceedsBalance() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 100));
        token.transferFrom(alice, bob, 100);
    }

    function test_revert_approveZeroSpender() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_holderCannotBeMovedByDeployer() public {
        vm.prank(deployer);
        token.transfer(alice, 50e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 50e18);
    }

    // -------------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, alice), allowed - amount);
        }
    }

    function testFuzz_cannotSpendMoreThanHeld(uint256 held, uint256 amount) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
    }
}
